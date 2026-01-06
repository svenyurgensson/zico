const std = @import("std");
const hal = @import("hal");
const svd = @import("svd");
const PFIC = svd.peripherals.PFIC;
const task = @import("./task.zig");
const sync = @import("./sync.zig");
const syscall = @import("./syscall.zig");

pub const Channel = sync.Channel;
pub const Semaphore = sync.Semaphore;
pub const TaskDef = task.TaskDef;

var schedule_fn: ?*const fn () callconv(.naked) void = null;

pub inline fn getZicoInstance() *anyopaque {
    var zico_ptr: *anyopaque = undefined;
    asm ("mv %[ptr], tp"
        : [ptr] "=r" (zico_ptr),
        :
        : .{});
    return zico_ptr;
}

fn idleTask() void {
    while (true) {
        syscall.ecall_args_ptr.a0 = @intFromEnum(syscall.EcallType.yield);
        asm volatile ("ecall" ::: syscall.ClobbersForEcall);
    }
}

const ZicoHeader = struct {
    tasks: []task.TSS,
    tasks_count: u8,
    current_task: u8,
    last_timer_update_ms: u32,
    next_stack_addr: usize,
};

pub fn wakeTask(task_id: u8) void {
    const zico_ptr = getZicoInstance();
    const scheduler: *ZicoHeader = @ptrCast(@alignCast(zico_ptr));
    if (task_id < scheduler.tasks_count) {
        scheduler.tasks[task_id].setState(.ready);
    }
}

export fn zico_scheduler_logic(self_ptr: *anyopaque, current_sp: u32) *const task.TSS {
    const self: *ZicoHeader = @ptrCast(@alignCast(self_ptr));

    const outgoing_task_tss = &self.tasks[self.current_task];
    outgoing_task_tss.sp = current_sp;

    outgoing_task_tss.next_addr = hal.cpu.csr.mepc.read() + 4;

    const ecall_type_raw = syscall.ecall_args_ptr.a0;
    const ecall_type: syscall.EcallType = @enumFromInt(@as(u8, @truncate(ecall_type_raw)));

    switch (ecall_type) {
        .yield => self.tasks[self.current_task].setState(.ready),
        .delay => {
            const ecall_arg = syscall.ecall_args_ptr.a1;
            self.tasks[self.current_task].setState(.waiting_on_timer);
            self.tasks[self.current_task].setDelayTimer(@truncate(ecall_arg));
        },
        .suspend_self => self.tasks[self.current_task].setState(.suspended),
        else => {
            self.tasks[self.current_task].setState(.ready);
        },
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

    return &self.tasks[self.current_task];
}

pub fn Zico(comptime task_defs: []const task.TaskDef) type {
    return struct {
        const Self = @This();

        tasks: []task.TSS,
        tasks_count: u8 = 0,
        current_task: u8 = 0,
        last_timer_update_ms: u32 = 0,
        next_stack_addr: usize = 0,

        pub const TaskUnion = task.CreateTaskUnion(task_defs);
        pub const TaskID = @typeInfo(TaskUnion).@"union".tag_type.?;

        const MINIMAL_CONTEXT_STACK_SIZE: usize = 64;

        const TOTAL_STACK_SIZE = blk: {
            var total: usize = 0;
            total += MINIMAL_CONTEXT_STACK_SIZE + 128; // idle task
            for (task_defs) |def| {
                if (def.stack_size % 4 != 0) {
                    @compileError("Task '" ++ def.name ++ "' stack_size must be a multiple of 4.");
                }
                total += MINIMAL_CONTEXT_STACK_SIZE + def.stack_size;
            }
            break :blk total;
        };

        var tasks_storage: [1 + task_defs.len]task.TSS = undefined;
        var stacks_storage: [TOTAL_STACK_SIZE]u8 align(8) = undefined;

        pub const SoftwareInterruptHandler = @as(hal.interrupts.Handler, @ptrCast(&switchTaskISR));

        pub fn init() Self {
            var self = Self{
                .tasks = &tasks_storage,
                .tasks_count = 0,
                .current_task = 0,
                .last_timer_update_ms = 0,
                .next_stack_addr = @intFromPtr(&stacks_storage),
            };
            schedule_fn = &scheduleNextTask;
            self.last_timer_update_ms = hal.time.millis();
            _ = self.addTask(&idleTask, 128) catch @panic("Failed to add idle task");
            self.tasks[0].setState(.ready);
            inline for (task_defs) |task_def| {
                const task_id = self.addTask(task_def.func, task_def.stack_size) catch @panic("Failed to add user task");
                self.tasks[task_id].setState(.ready);
            }
            return self;
        }

        pub inline fn yield(_: *Self) void {
            syscall.ecall_args_ptr.a0 = @intFromEnum(syscall.EcallType.yield);
            asm volatile ("ecall");
        }

        pub inline fn suspendSelf(_: *Self) void {
            syscall.ecall_args_ptr.a0 = @intFromEnum(syscall.EcallType.suspend_self);
            asm volatile ("ecall");
        }

        pub inline fn delay(_: *Self, N: u16) void {
            syscall.ecall_args_ptr.a0 = @intFromEnum(syscall.EcallType.delay);
            syscall.ecall_args_ptr.a1 = N;
            asm volatile ("ecall");
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
            asm volatile (
                \\ mv tp, %[zico_ptr]
                \\ mv sp, %[sp]
                \\ mret
                :
                : [zico_ptr] "r" (self),
                  [sp] "r" (current_task_ref.sp),
                : .{ .x4 = true });
            unreachable;
        }

        fn addTask(self: *Self, task_fn_ptr: *const fn () void, stack_size: usize) !u8 {
            const task_id = self.tasks_count;
            if (task_id >= self.tasks.len) return error.NoMoreTaskSlots;

            const stack_total_size = MINIMAL_CONTEXT_STACK_SIZE + stack_size;
            const stack_bottom_addr: usize = self.next_stack_addr;
            const stack_top_addr: usize = stack_bottom_addr + stack_total_size;
            self.next_stack_addr += stack_total_size;

            const initial_sp: u32 = @intCast(stack_top_addr - 48);

            const hpe_frame_ptr: [*]u8 = @ptrFromInt(initial_sp);
            @memset(hpe_frame_ptr[0..48], 0);

            const x1_addr = initial_sp + 44;
            const x1_ptr: *volatile u32 = @ptrFromInt(x1_addr);
            x1_ptr.* = @intFromPtr(task_fn_ptr);

            const entry_addr = @intFromPtr(task_fn_ptr);
            self.tasks[task_id] = task.TSS.init(@as(u32, @truncate(entry_addr)), initial_sp);
            self.tasks_count += 1;
            return task_id;
        }
    };
}

pub fn switchTaskISR() callconv(.naked) void {
    asm volatile ("j scheduleNextTask" ::: .{});
}

export fn scheduleNextTask() callconv(.naked) void {
    asm volatile (
    // We are on the interrupted task's stack.
    // Save the original/interrupted SP in a callee-saved register (s1) so it survives.
        \\ mv s1, sp
        // Now, allocate our own small frame on the current stack to save ra.
        \\ addi sp, sp, -4
        \\ sw ra, 0(sp)
        // Load zico_instance pointer from tp into a0
        \\ mv a0, tp 
        // Pass current_sp in a1 (second argument)
        \\ mv a1, s1
        // Call the global scheduler logic function. It will return a pointer to the next TSS in `a0`.
        \\ jal ra, %[logic]
        // After return, a0 holds the pointer to the next TSS.
        // Restore this function's temporary frame before switching stacks.
        \\ lw ra, 0(sp)
        \\ addi sp, sp, 4
        // Now, perform the final context switch.
        // Restore sp and mepc from the new TSS.
        \\ lw sp, 0(a0)      // tss.sp
        \\ lw a1, 4(a0)      // tss.next_addr
        \\ csrw mepc, a1
        // Return from exception. This will trigger HPE to restore registers and jump to mepc.
        \\ mret
        :
        : [logic] "i" (zico_scheduler_logic),
        : .{ .memory = true, .x1 = true, .x2 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true });
}
