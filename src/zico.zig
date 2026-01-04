const std = @import("std");
const hal = @import("hal");
const svd = @import("svd");
const PFIC = svd.peripherals.PFIC;
const task = @import("./task.zig");
const message = @import("./message.zig");

pub const Channel = message.Channel;
pub const TaskDef = task.TaskDef;

var zico_instance: ?*anyopaque = null;
var schedule_fn: ?*const fn () void = null;

const ClobbersYield = .{
    .memory = true,
    .x1 = true,
    .x2 = true,
    .x3 = true,
    .x4 = true,
    .x5 = true,
    .x6 = true,
    .x7 = true,
    .x8 = true,
    .x9 = true,
    .x10 = true,
    .x11 = true,
    .x12 = true,
    .x13 = true,
    .x14 = true,
    .x15 = true,
};
const ClobbersArgs = .{
    .memory = true,
    .x2 = true,
    .x3 = true,
    .x4 = true,
    .x5 = true,
    .x6 = true,
    .x7 = true,
    .x8 = true,
    .x9 = true,
    .x10 = true,
    .x11 = true,
    .x12 = true,
    .x13 = true,
    .x14 = true,
    .x15 = true,
};

fn idleTask() void {
    while (true) {
        asm volatile ("li a0, %[yield_type]\necall"
            :
            : [yield_type] "i" (@intFromEnum(EcallType.yield)),
            : ClobbersYield);
    }
}

pub const EcallType = enum(u8) {
    yield = 0,
    delay = 1,
    suspend_self = 2,
    sem_wait = 3,
    sem_signal = 4,
    channel_send = 5,
    channel_receive = 6,
};

pub const TaskState = enum(u4) {
    idle = 0,
    ready = 2,
    suspended = 3,
    waiting_on_timer = 4,
    waiting_on_semaphore = 5,
    waiting_on_channel_send = 7,
    waiting_on_channel_receive = 8,
};

pub const TaskFlags = struct {
    state: TaskState,
    has_message: bool,
    priority: u3,
};

pub const TSS = struct {
    next_addr: u32,
    flags: TaskFlags,
    wait_obj: ?*anyopaque,
    delay_timer: u16,

    pub fn init(entry_point: u32) TSS {
        return .{
            .next_addr = entry_point,
            .flags = .{ .state = .idle, .has_message = false, .priority = 0 },
            .wait_obj = null,
            .delay_timer = 0,
        };
    }

    pub inline fn getState(self: *const TSS) TaskState {
        return self.flags.state;
    }
    pub inline fn setState(self: *TSS, new_state: TaskState) void {
        self.flags.state = new_state;
    }
    pub inline fn getDelayTimer(self: *const TSS) u16 {
        return self.delay_timer;
    }
    pub inline fn setDelayTimer(self: *TSS, timer: u16) void {
        self.delay_timer = timer;
    }
};

/// Wakes a task by its ID, setting its state to ready.
/// This is intended for use by synchronization primitives.
pub fn wakeTask(task_id: u8) void {
    const zico: *anyopaque = zico_instance orelse return;
    // This is a bit of a hack. We need the concrete scheduler type to access its `tasks` field.
    // Since this is a generic function, we can't know the type directly.
    // However, we know all instantiations of `Zico` have a `tasks: []TSS` field at the same offset.
    // This is unsafe and relies on implementation details.
    const ZicoStruct = @TypeOf(zico).?.Pointer.child;
    const scheduler: *ZicoStruct = @ptrCast(@alignCast(zico));
    if (task_id < scheduler.tasks.len) {
        scheduler.tasks[task_id].setState(.ready);
    }
}

pub fn Zico(comptime task_defs: []const task.TaskDef) type {
    return struct {
        const Self = @This();

        tasks: []TSS,
        tasks_count: u8 = 0,
        current_task: u8 = 0,
        last_timer_update_ms: u32 = 0,

        pub const TaskUnion = task.CreateTaskUnion(task_defs);
        pub const TaskID = @typeInfo(TaskUnion).@"union".tag_type.?;

        const TASK_COUNT = 1 + task_defs.len;
        var tasks_storage: [TASK_COUNT]TSS = undefined;

        pub const SoftwareInterruptHandler = @as(hal.interrupts.Handler, @ptrCast(&switchTaskISR));

        pub fn init() Self {
            var self = Self{
                .tasks = &tasks_storage,
                .tasks_count = 0,
                .current_task = 0,
                .last_timer_update_ms = 0,
            };
            zico_instance = &self;
            schedule_fn = &scheduleNextTask_trampoline;
            self.last_timer_update_ms = hal.time.millis();
            _ = self.addTask(&idleTask) catch @panic("Failed to add idle task");
            self.tasks[0].setState(.ready);
            inline for (task_defs) |task_def| {
                const task_id = self.addTask(task_def.func) catch @panic("Failed to add user task");
                self.tasks[task_id].setState(.ready);
            }
            return self;
        }

        pub inline fn yield(_: *Self) void {
            asm volatile ("li a0, %[yield_type]\necall"
                :
                : [yield_type] "i" (@intFromEnum(EcallType.yield)),
                : ClobbersYield);
        }

        pub inline fn suspendSelf(_: *Self) void {
            asm volatile ("li a0, %[suspend_type]\necall"
                :
                : [suspend_type] "i" (@intFromEnum(EcallType.suspend_self)),
                : ClobbersYield);
        }

        pub inline fn delay(_: *Self, N: u16) void {
            asm volatile ("li a0, %[delay_type]\nmv a1, %[delay_val]\necall"
                :
                : [delay_type] "i" (@intFromEnum(EcallType.delay)),
                  [delay_val] "r" (N),
                : ClobbersArgs);
        }

        pub fn suspendTask(self: *Self, task_id: Self.TaskID) void {
            const idx = @intFromEnum(task_id) + 1;
            if (idx < self.tasks_count) {
                self.tasks[idx].setState(.suspended);
            }
        }

        pub fn resumeTask(self: *Self, task_id: Self.TaskID) void {
            const idx = @intFromEnum(task_id) + 1;
            if (idx < self.tasks_count) {
                self.tasks[idx].setState(.ready);
            }
        }

        pub fn runLoop(self: *Self) noreturn {
            if (self.tasks_count == 0) @panic("Cannot run scheduler with no tasks");
            self.current_task = 0;
            const current_task_ref = &self.tasks[self.current_task];
            hal.cpu.csr.mepc.write(current_task_ref.next_addr);
            asm volatile ("mret");
            unreachable;
        }

        fn addTask(self: *Self, task_fn_ptr: *const fn () void) !u8 {
            const task_id = self.tasks_count;
            if (task_id >= self.tasks.len) return error.NoMoreTaskSlots;
            const entry_addr = @intFromPtr(task_fn_ptr);
            self.tasks[task_id] = TSS.init(@as(u32, @truncate(entry_addr)));
            self.tasks_count += 1;
            return task_id;
        }

        fn scheduleNextTask_internal(self: *Self) void {
            var ecall_type_raw: u32 = undefined;
            var ecall_arg: u32 = undefined;
            asm volatile (""
                : [t] "= {a0}" (ecall_type_raw),
                  [a] "= {a1}" (ecall_arg),
            );
            const ecall_type: EcallType = @enumFromInt(@as(u8, @truncate(ecall_type_raw)));

            const current_mepc = hal.cpu.csr.mepc.read();
            self.tasks[self.current_task].next_addr = current_mepc;

            var should_switch: bool = true;

            switch (ecall_type) {
                .yield => self.tasks[self.current_task].setState(.ready),
                .delay => {
                    const current_task_ref = &self.tasks[self.current_task];
                    current_task_ref.setState(.waiting_on_timer);
                    current_task_ref.setDelayTimer(@truncate(ecall_arg));
                },
                .suspend_self => self.tasks[self.current_task].setState(.suspended),
                .sem_wait => {
                    const current_task_ref = &self.tasks[self.current_task];
                    current_task_ref.setState(.waiting_on_semaphore);
                    current_task_ref.wait_obj = @ptrFromInt(ecall_arg);
                },
                .sem_signal => {
                    const sem_ptr: *anyopaque = @ptrFromInt(ecall_arg);
                    for (self.tasks) |*t| {
                        if (t.getState() == .waiting_on_semaphore and t.wait_obj == sem_ptr) {
                            t.setState(.ready);
                            t.wait_obj = null;
                            break;
                        }
                    }
                    should_switch = false;
                },
                .channel_send => {
                    const current_task_ref = &self.tasks[self.current_task];
                    current_task_ref.setState(.waiting_on_channel_send);
                    current_task_ref.wait_obj = @ptrFromInt(ecall_arg);
                },
                .channel_receive => {
                    const current_task_ref = &self.tasks[self.current_task];
                    current_task_ref.setState(.waiting_on_channel_receive);
                    current_task_ref.wait_obj = @ptrFromInt(ecall_arg);
                },
            }

            if (!should_switch) {
                hal.cpu.csr.mepc.write(current_mepc);
                PFIC.STK_CTLR.modify(.{ .SWIE = 0 });
                return;
            }

            const current_ms = hal.time.millis();
            if (current_ms > self.last_timer_update_ms) {
                const elapsed_ms = @as(u16, @intCast(current_ms - self.last_timer_update_ms));
                for (self.tasks) |*task_item| {
                    if (task_item.getState() == .waiting_on_timer) {
                        if (task_item.getDelayTimer() > elapsed_ms) {
                            task_item.setDelayTimer(task_item.getDelayTimer() - elapsed_ms);
                        } else {
                            task_item.setState(.ready);
                            task_item.setDelayTimer(0);
                        }
                    }
                }
                self.last_timer_update_ms = current_ms;
            }

            var next_task_idx: usize = self.current_task;
            var i: usize = 0;
            const tasks_len = self.tasks_count;
            while (i < tasks_len) : (i += 1) {
                next_task_idx = (next_task_idx + 1) % tasks_len;
                if (self.tasks[next_task_idx].getState() == .ready) break;
            }

            if (self.tasks[next_task_idx].getState() != .ready) {
                next_task_idx = 0;
            }
            self.current_task = @as(u8, @intCast(next_task_idx));

            const next_mepc_addr = self.tasks[self.current_task].next_addr;
            hal.cpu.csr.mepc.write(next_mepc_addr);
            PFIC.STK_CTLR.modify(.{ .SWIE = 0 });
        }

        fn scheduleNextTask_trampoline() void {
            const zico_unwrapped: *anyopaque = zico_instance orelse return;
            const zico: *Self = @ptrCast(@alignCast(zico_unwrapped));
            zico.scheduleNextTask_internal();
        }
    };
}

pub const Semaphore = struct {
    count: u8,

    pub fn init(initial_count: u8) Semaphore {
        return .{ .count = initial_count };
    }

    pub fn wait(self: *Semaphore) void {
        if (self.count > 0) {
            self.count -= 1;
        } else {
            asm volatile ("li a0, %[sem_wait_type]\nmv a1, %[sem_ptr]\necall"
                :
                : [sem_wait_type] "i" (@intFromEnum(EcallType.sem_wait)),
                  [sem_ptr] "r" (self),
                : ClobbersArgs);
        }
    }

    pub fn signal(self: *Semaphore) void {
        self.count += 1;
        asm volatile ("li a0, %[sem_signal_type]\nmv a1, %[sem_ptr]\necall"
            :
            : [sem_signal_type] "i" (@intFromEnum(EcallType.sem_signal)),
              [sem_ptr] "r" (self),
            : ClobbersArgs);
    }
};

pub fn switchTaskISR() callconv(.naked) void {
    asm volatile ("jal ra, %[scheduler]\n" ++ "mret"
        :
        : [scheduler] "i" (scheduleNextTask),
        : .{ .memory = true });
}

export fn scheduleNextTask() void {
    if (schedule_fn) |f| {
        f();
    }
}
