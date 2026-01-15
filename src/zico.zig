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

pub export var g_zico_instance: ?*anyopaque = null;

var schedule_fn: ?*const fn () callconv(.naked) void = null;

pub inline fn getZicoInstance() *anyopaque {
    return g_zico_instance.?;
}

// This is the idle task. It runs when no other tasks are ready to run.
// It simply yields control back to the scheduler immediately, preventing the CPU from
// wasting cycles and ensuring the scheduler always has something to execute.
fn idleTask() void {
    while (true) {
        syscall.ecall_args_ptr.a0 = @intFromEnum(syscall.EcallType.yield); // set yield() operation code
        syscall.triggerSoftwareInterrupt();
        //asm volatile ("ecall" ::: syscall.ClobbersForEcall);
    }
}

const ZicoHeader = struct {
    tasks: []task.TSS,
    current_task: u8,
    last_timer_update_ms: u32,
};

pub fn wakeTask(task_id: u8) void {
    const zico_ptr = getZicoInstance();
    const scheduler: *ZicoHeader = @ptrCast(@alignCast(zico_ptr));
    if (task_id < scheduler.tasks.len) {
        scheduler.tasks[task_id].setState(.ready);
    }
}

export fn zico_scheduler_logic(self_ptr: *anyopaque, current_sp: u32) *const task.TSS {
    const self: *ZicoHeader = @ptrCast(@alignCast(self_ptr));

    const outgoing_task_tss = &self.tasks[self.current_task];
    outgoing_task_tss.sp = current_sp;

    outgoing_task_tss.next_addr = hal.cpu.csr.mepc.read();

    const ecall_type_raw = syscall.ecall_args_ptr.a0;
    const ecall_type: syscall.EcallType = @enumFromInt(@as(u8, @truncate(ecall_type_raw)));

    switch (ecall_type) {
        .yield => {
            self.tasks[self.current_task].setState(.ready);
        },
        .delay => {
            const ecall_arg = syscall.ecall_args_ptr.a1;
            self.tasks[self.current_task].setState(.waiting_on_timer);
            self.tasks[self.current_task].setDelayTimer(@truncate(ecall_arg));
        },
        .suspend_self => {
            self.tasks[self.current_task].setState(.suspended);
        },
        .sem_wait => {
            const sem: *sync.Semaphore = @ptrFromInt(syscall.ecall_args_ptr.a1);
            sem.wait_queue.enqueue(self.current_task) catch @panic("Semaphore wait queue full!");
            self.tasks[self.current_task].setState(.waiting_on_semaphore);
        },
        .channel_send => {
            const queue: *sync.WaitQueue = @ptrFromInt(syscall.ecall_args_ptr.a1);
            queue.enqueue(self.current_task) catch @panic("Channel send wait queue full!");
            self.tasks[self.current_task].setState(.waiting_on_channel_send);
        },
        .channel_receive => {
            const queue: *sync.WaitQueue = @ptrFromInt(syscall.ecall_args_ptr.a1);
            queue.enqueue(self.current_task) catch @panic("Channel receive wait queue full!");
            self.tasks[self.current_task].setState(.waiting_on_channel_receive);
        },
    }

    const current_ms = hal.time.millis();
    // Use wrapping subtraction to correctly handle timer overflow.
    const elapsed_ms_u32 = current_ms -% self.last_timer_update_ms;

    // Only update timers if time has actually passed.
    if (elapsed_ms_u32 > 0) {
        // The elapsed time should not be enormously large. We can safely truncate to u16
        // as we don't expect the scheduler to be blocked for more than 65 seconds.
        const elapsed_ms = @as(u16, @truncate(elapsed_ms_u32));

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
        // IMPORTANT: Update last_timer_update_ms using the current time, NOT by adding elapsed time.
        // This prevents drift.
        self.last_timer_update_ms = current_ms;
    }

    var next_task_idx: usize = self.current_task;
    var i: usize = 0;
    const tasks_len = self.tasks.len;
    while (i < tasks_len) : (i += 1) {
        next_task_idx = (next_task_idx +% 1);
        if (next_task_idx >= tasks_len) next_task_idx = 0;
        if (self.tasks[next_task_idx].getState() == .ready) break;
    }

    if (self.tasks[next_task_idx].getState() != .ready) {
        next_task_idx = 0;
    }
    self.current_task = @as(u8, @intCast(next_task_idx)); // 4th round

    hal.interrupts.clearPending(.SW);
    return &self.tasks[self.current_task];
}

pub fn Zico(comptime task_defs: []const task.TaskDef) type {
    return struct {
        const Self = @This();

        tasks: []task.TSS,
        current_task: u8 = 0,
        last_timer_update_ms: u32 = 0,

        pub const TaskUnion = task.CreateTaskUnion(task_defs);
        pub const TaskID = @typeInfo(TaskUnion).@"union".tag_type.?;

        const MINIMAL_CONTEXT_STACK_SIZE: usize = 64;
        const SCHEDULER_STACK_SIZE: usize = 64;
        const IDLE_TASK_STACK_SIZE: usize = 24;

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

        const TASKS_COUNT = 1 + task_defs.len;
        var tasks_storage: [TASKS_COUNT]task.TSS = blk: {
            var storage: [TASKS_COUNT]task.TSS = undefined;

            // Initialize all tasks with placeholder values
            for (0..TASKS_COUNT) |i| {
                storage[i] = task.TSS.init(0, 0); // Both SP and NextAddr are placeholders
                storage[i].setState(.ready);
            }
            break :blk storage;
        };
        var stacks_storage: [TOTAL_STACK_SIZE]u8 align(8) = undefined;
        var scheduler_stack: [SCHEDULER_STACK_SIZE]u8 align(8) = undefined;

        pub const SoftwareInterruptHandler = @as(hal.interrupts.Handler, @ptrCast(&switchTaskISR));

        pub fn init() Self {
            var self = Self{
                .tasks = &tasks_storage,
                .current_task = 0,
                .last_timer_update_ms = 0,
            };
            g_zico_instance = (&self)[0..0].ptr;
            const scheduler_stack_top = @intFromPtr(&scheduler_stack) + SCHEDULER_STACK_SIZE;
            asm volatile (
                \\ csrw mscratch, %[stack_top]
                :
                : [stack_top] "r" (scheduler_stack_top),
            );

            schedule_fn = &scheduleNextTask;

            // Runtime: Patch stack pointers and entry points
            var next_stack_addr: usize = @intFromPtr(&stacks_storage);

            // Idle Task (Index 0)
            const idle_stack_total_size = IDLE_TASK_STACK_SIZE + MINIMAL_CONTEXT_STACK_SIZE;
            self.tasks[0].sp = @intCast(next_stack_addr + idle_stack_total_size);
            self.tasks[0].next_addr = @intFromPtr(&idleTask);
            next_stack_addr += idle_stack_total_size;

            // User Tasks
            inline for (task_defs, 1..) |def, i| {
                const total_task_stack_size = def.stack_size + MINIMAL_CONTEXT_STACK_SIZE;
                self.tasks[i].sp = @intCast(next_stack_addr + total_task_stack_size);
                self.tasks[i].next_addr = @intFromPtr(def.func);
                next_stack_addr += total_task_stack_size;
            }

            self.last_timer_update_ms = hal.time.millis();

            syscall.enableSoftwareInterrupt();
            hal.interrupts.enable(.SW);
            return self;
        }

        pub inline fn yield(_: *Self) void {
            syscall.ecall_args_ptr.a0 = @intFromEnum(syscall.EcallType.yield);
            syscall.triggerSoftwareInterrupt();
            //asm volatile ("ecall" ::: syscall.ClobbersForEcall);
        }

        pub inline fn suspendSelf(_: *Self) void {
            syscall.ecall_args_ptr.a0 = @intFromEnum(syscall.EcallType.suspend_self);
            syscall.triggerSoftwareInterrupt();
            //asm volatile ("ecall" ::: syscall.ClobbersForEcall);
        }

        pub inline fn delay(_: *Self, N: u16) void {
            syscall.ecall_args_ptr.a0 = @intFromEnum(syscall.EcallType.delay);
            syscall.ecall_args_ptr.a1 = N;
            syscall.triggerSoftwareInterrupt();
            //asm volatile ("ecall" ::: syscall.ClobbersForEcall);
        }

        pub fn suspendTask(self: *Self, comptime task_id: Self.TaskID) void {
            const idx = @intFromEnum(task_id) + 1;
            // The comptime task_id guarantees that the index is valid,
            // so a runtime bounds check is not necessary.
            self.tasks[idx].setState(.suspended);
        }

        pub fn resumeTask(self: *Self, comptime task_id: Self.TaskID) void {
            const idx = @intFromEnum(task_id) + 1;
            // The comptime task_id guarantees that the index is valid,
            // so a runtime bounds check is not necessary.
            self.tasks[idx].setState(.ready);
        }

        pub fn getTaskState(self: *const Self, comptime task_id: Self.TaskID) task.TaskState {
            const idx = @intFromEnum(task_id) + 1;
            // The comptime task_id guarantees that the index is valid,
            // so a runtime bounds check is not necessary.
            return self.tasks[idx].getState();
        }

        pub fn runLoop(self: *Self) noreturn {
            if (self.tasks.len == 0) @panic("Cannot run scheduler with no tasks");

            // The scheduler always starts with the first task, which is the idle task.
            self.current_task = 0;
            const current_task_ref = &self.tasks[self.current_task];
            const next_pc = current_task_ref.next_addr;
            const next_sp = current_task_ref.sp;

            hal.cpu.csr.mepc.write(next_pc);
            asm volatile (
                \\ mv sp, %[sp]
                \\ mret
                :
                : [sp] "r" (next_sp),
                : .{});
            unreachable;
        }
    };
}

pub fn switchTaskISR() callconv(.naked) void {
    asm volatile ("j scheduleNextTask" ::: .{});
}

export fn scheduleNextTask() callconv(.naked) void {
    asm volatile (
    // The hardware has already pushed 16 caller-saved registers onto the current task's stack.
    // 1. Manually save the callee-saved registers (s0, s1) on the same stack.
        \\ addi sp, sp, -8
        \\ sw s0, 4(sp)
        \\ sw s1, 0(sp)

        // The full context is now on the task's stack.
        // 2. Atomically swap to the scheduler stack.
        //    The SP for the task's full context frame is saved into mscratch.
        \\ csrrw sp, mscratch, sp

        // We are now on the scheduler's private stack.
        // 3. Save `ra` before making a function call.
        \\ addi sp, sp, -4
        \\ sw ra, 0(sp)

        // 4. Prepare arguments and call the scheduler logic.
        //    a0 = self_ptr, a1 = current_sp
        \\ .option push
        \\ .option norelax
        \\ la a0, g_zico_instance
        \\ .option pop
        \\ lw a0, (a0)
        \\ csrr a1, mscratch  // Pass the saved task SP
        \\ jal ra, %[logic]

        // After return, a0 holds the pointer to the next task's TSS.
        // 5. Restore `ra` and the scheduler's stack frame.
        \\ lw ra, 0(sp)
        \\ addi sp, sp, 4

        // 6. Get the next task's stack pointer (which points to its saved context frame) from its TSS.
        \\ lw sp, 0(a0)

        // 7. Restore the callee-saved registers for the new task from its stack.
        \\ lw s1, 0(sp)
        \\ lw s0, 4(sp)
        \\ addi sp, sp, 8

        // 8. Restore mepc for the new task from its TSS.
        \\ lw a1, 4(a0)
        \\ csrw mepc, a1
        :
        : [logic] "i" (zico_scheduler_logic),
        : .{ .memory = true, .x1 = true, .x5 = true, .x6 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true });

    asm volatile (
    // 9. Return from exception. The hardware will now pop the 16 caller-saved registers
    //    from the task's stack, completing the context restore.
        \\ mret
    );
}
