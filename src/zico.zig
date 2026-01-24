const std = @import("std");
const hal = @import("hal");
const task = @import("./task.zig");
const sync = @import("./sync.zig");
const syscall = @import("./syscall.zig");

pub const Channel = sync.Channel;
pub const Semaphore = sync.Semaphore;
pub const TaskDef = task.TaskDef;

// This is the idle task. It runs when no other tasks are ready to run.
// It simply yields control back to the scheduler immediately, preventing the CPU from
// wasting cycles and ensuring the scheduler always has something to execute.
fn idleTask() void {
    const zico_ptr = asm volatile (
        \\ mv %[zico_ptr], tp
        : [zico_ptr] "=r" (-> *u32),
    );
    const scheduler: *ZicoHeader = @ptrCast(@alignCast(zico_ptr));
    while (true) {
        scheduler.setEcallCmd(.yield);
        syscall.trigger();
    }
}

pub const ZicoHeader = struct {
    tasks: []task.TSS,
    current_task: u8,
    last_timer_update_ms: u32,
    ecall_args: syscall.EcallArgs,

    pub inline fn setEcallCmd(self: *ZicoHeader, cmd: syscall.EcallType) void {
        self.ecall_args.a0 = @intFromEnum(cmd);
    }
    pub inline fn setEcallCmdWithArg(self: *ZicoHeader, cmd: syscall.EcallType, arg: u32) void {
        self.ecall_args.a0 = @intFromEnum(cmd);
        self.ecall_args.a1 = arg;
    }
};

pub fn wakeTask(task_id: u8) void {
    const zico_ptr = asm volatile (
        \\ mv %[zico_ptr], tp
        : [zico_ptr] "=r" (-> *u32),
    );
    const scheduler: *ZicoHeader = @ptrCast(@alignCast(zico_ptr));
    if (task_id < scheduler.tasks.len) {
        scheduler.tasks[task_id].setState(.ready);
    }
}
// expected sp to be in a0
export fn zico_scheduler_logic(current_sp: u32) *const task.TSS {
    const zico_ptr = asm volatile (
        \\ mv %[zico_ptr], tp
        : [zico_ptr] "=r" (-> *u32),
    );
    const self: *ZicoHeader = @ptrCast(@alignCast(zico_ptr));

    const outgoing_task = &self.tasks[self.current_task];
    outgoing_task.sp = current_sp;
    const mepc_value = syscall.readMepc();

    // correcting return address, depends of ecall: compressed or not
    const instr: u16 = @as(*volatile u16, @ptrFromInt(mepc_value)).*;
    if ((instr & 0x3) == 0x3) {
        outgoing_task.next_addr = mepc_value + 4; // 32-bit
    } else {
        outgoing_task.next_addr = mepc_value + 2; // 16-bit
    }

    const ecall_type_raw = self.ecall_args.a0;
    const ecall_type: syscall.EcallType = @enumFromInt(@as(u8, @truncate(ecall_type_raw)));

    switch (ecall_type) {
        .yield => {
            outgoing_task.setState(.ready);
        },
        .delay => {
            const ecall_arg = self.ecall_args.a1;
            outgoing_task.setState(.waiting_on_timer);
            outgoing_task.setDelayTimer(@truncate(ecall_arg));
        },
        .suspend_self => {
            outgoing_task.setState(.suspended);
        },
        .sem_wait => {
            const sem: *sync.Semaphore = @ptrFromInt(self.ecall_args.a1);
            sem.wait_queue.enqueue(self.current_task) catch @panic("Semaphore wait queue full!");
            outgoing_task.setState(.waiting_on_semaphore);
        },
        .channel_send => {
            const queue: *sync.WaitQueue = @ptrFromInt(self.ecall_args.a1);
            queue.enqueue(self.current_task) catch @panic("Channel send wait queue full!");
            outgoing_task.setState(.waiting_on_channel_send);
        },
        .channel_receive => {
            const queue: *sync.WaitQueue = @ptrFromInt(self.ecall_args.a1);
            queue.enqueue(self.current_task) catch @panic("Channel receive wait queue full!");
            outgoing_task.setState(.waiting_on_channel_receive);
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
    self.current_task = @as(u8, @intCast(next_task_idx));

    return &self.tasks[self.current_task]; // return ptr to current task in a0
}

pub fn Zico(comptime task_defs: []const task.TaskDef) type {
    return struct {
        const Self = @This();

        tasks: []task.TSS,
        current_task: u8 = 0,
        last_timer_update_ms: u32 = 0,
        ecall_args: syscall.EcallArgs = .{ .a0 = 0, .a1 = 0 },

        pub const TaskUnion = task.CreateTaskUnion(task_defs);
        pub const TaskID = @typeInfo(TaskUnion).@"union".tag_type.?;

        const MINIMAL_CONTEXT_STACK_SIZE: usize = 48;
        const SCHEDULER_STACK_SIZE: usize = 64;
        const IDLE_TASK_STACK_SIZE: usize = 32; //

        const TOTAL_STACK_SIZE = blk: {
            var total: usize = 0;
            total += MINIMAL_CONTEXT_STACK_SIZE + IDLE_TASK_STACK_SIZE; // Use actual idle task stack size
            for (task_defs) |def| {
                if (def.stack_size % 16 != 0) { // Enforce 16-byte alignment
                    @compileError("Task '" ++ def.name ++ "' stack_size must be a multiple of 16 for proper ABI alignment.");
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
        var stacks_storage: [TOTAL_STACK_SIZE]u8 align(16) = undefined; // Changed align(8) to align(16)
        var scheduler_stack: [SCHEDULER_STACK_SIZE]u8 align(8) = undefined;

        pub fn init() Self {
            var self = Self{
                .tasks = &tasks_storage,
                .current_task = 0,
                .last_timer_update_ms = 0,
            };

            const scheduler_stack_top = @intFromPtr(&scheduler_stack) + SCHEDULER_STACK_SIZE;
            // saving scheduler stack ptr to mscratch
            asm volatile (
                \\ csrw mscratch, %[stack_top]
                :
                : [stack_top] "r" (scheduler_stack_top),
            );

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

            return self;
        }

        pub inline fn yield(self: *Self) void {
            self.setEcallCmd(.yield);
            syscall.trigger();
        }

        pub inline fn suspendSelf(self: *Self) void {
            self.setEcallCmd(.suspend_self);
            syscall.trigger();
        }

        pub inline fn delay(self: *Self, N: u16) void {
            self.setEcallCmdWithArg(.delay, N);
            syscall.trigger();
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
            // save ptr to scheduler into tp register, so that the ISR can access it
            asm volatile (
                \\ mv tp, %[s]
                :
                : [s] "r" (self),
                : .{});

            if (self.tasks.len < 2) @panic("Cannot run scheduler with no tasks");

            // The scheduler always starts with the first task, which is the idle task.
            self.current_task = 0;
            const current_task_ref = &self.tasks[self.current_task];
            const next_pc = current_task_ref.next_addr;
            const next_sp = current_task_ref.sp;

            // Setup and return to the first task from list
            asm volatile (
                \\ csrw mepc, %[my_mepc] 
                \\ mv sp, %[sp]
                // INTSYSCR = .hwstken = 1, .inesten = 1, .eabien = 0 <---this 0 is important !!!
                \\ li a2, 3
                \\ csrw 0x804, a2
                \\ mret
                :
                : [sp] "r" (next_sp),
                  [my_mepc] "r" (next_pc),
                : .{});
            unreachable;
        }

        pub inline fn setEcallCmd(self: *Self, cmd: syscall.EcallType) void {
            self.ecall_args.a0 = @intFromEnum(cmd);
        }

        pub inline fn setEcallCmdWithArg(self: *Self, cmd: syscall.EcallType, arg: u32) void {
            self.ecall_args.a0 = @intFromEnum(cmd);
            self.ecall_args.a1 = arg;
        }
    };
}

pub const InterruptHandler = @as(hal.interrupts.Handler, @ptrCast(&switchTaskISR));

pub export fn switchTaskISR() align(4) callconv(.naked) void {
    asm volatile (
    // The hardware has already pushed 16 caller-saved registers onto the current task's stack.
    // Manually save the callee-saved registers (s0, s1) on the same stack.
        \\ addi sp, sp, -16
        \\ sw s0, 12(sp)
        \\ sw s1, 8(sp)

        // The full context is now on the task's stack.
        // Prepare argument for scheduler: move current SP (the task's SP) into a0.
        \\ mv a0, sp

        // Switch to the scheduler's stack. The scheduler's stack pointer is stored
        //    in `mscratch` and is only read, not modified.
        \\ csrr sp, mscratch

        // We are now on the scheduler's private stack.
        // Save `ra` before making a function call.
        \\ addi sp, sp, -4
        \\ sw ra, 0(sp)

        // Call the scheduler logic. `a0` (current_sp) is already set.
        \\ jal ra, %[logic]

        // After the scheduler returns, a0 holds the pointer to the next task's TSS.
        // Disable global interrupts to ensure atomic context restoration.
        \\ csrr t0, mstatus
        \\ li t1, 8 # MIE bit
        \\ not t1, t1
        \\ and t0, t0, t1
        \\ csrw mstatus, t0

        // Restore `ra` and the scheduler's stack frame.
        \\ lw ra, 0(sp)
        \\ addi sp, sp, 4

        // Get the next task's stack pointer (which points to its saved context frame) from its TSS.
        \\ lw sp, 0(a0)

        // Restore the callee-saved registers for the new task from its stack.
        \\ lw s1, 8(sp)
        \\ lw s0, 12(sp)
        \\ addi sp, sp, 16

        // Restore mepc for the new task from its TSS.
        \\ lw a1, 4(a0)
        \\ csrw mepc, a1
        :
        : [logic] "i" (zico_scheduler_logic),
        : .{ .memory = true, .x1 = true, .x5 = true, .x6 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true });

    // separate instruction to easy debugging
    asm volatile (
    // Return from exception. The hardware will now pop the 16 caller-saved registers
    //    from the task's stack, completing the context restore.
        \\ mret
    );
}
