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

export var g_zico_instance: ?*anyopaque = null;

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
    syscall.cleanSoftwareInterrupt();

    const outgoing_task_tss = &self.tasks[self.current_task];
    outgoing_task_tss.sp = current_sp;

    outgoing_task_tss.next_addr = blk: {
        const mepc = hal.cpu.csr.mepc.read();
        // Read the instruction at mepc to determine its size.
        // RISC-V instructions are 2 bytes if the two LSBs are not '11', and 4 bytes otherwise.
        const instruction = @as(*const u16, @ptrFromInt(mepc)).*;
        const instruction_size: u32 = if ((instruction & 0b11) == 0b11) 4 else 2;
        break :blk mepc + instruction_size;
    };

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

        var tasks_storage: [1 + task_defs.len]task.TSS = undefined;
        var stacks_storage: [TOTAL_STACK_SIZE]u8 align(8) = undefined;
        var scheduler_stack: [SCHEDULER_STACK_SIZE]u8 align(8) = undefined;

        pub const SoftwareInterruptHandler = @as(hal.interrupts.Handler, @ptrCast(&switchTaskISR));

        pub fn init() Self {
            var self = Self{
                .tasks = &tasks_storage,
                .tasks_count = 0,
                .current_task = 0,
                .last_timer_update_ms = 0,
                .next_stack_addr = @intFromPtr(&stacks_storage),
            };

            g_zico_instance = (&self)[0..0].ptr;

            const scheduler_stack_top = @intFromPtr(&scheduler_stack) + SCHEDULER_STACK_SIZE;
            asm volatile (
                \\ csrw mscratch, %[stack_top]
                :
                : [stack_top] "r" (scheduler_stack_top),
            );

            schedule_fn = &scheduleNextTask;
            self.last_timer_update_ms = hal.time.millis();
            _ = self.addTask(&idleTask, IDLE_TASK_STACK_SIZE) catch @panic("Failed to add idle task");
            inline for (task_defs) |task_def| {
                _ = self.addTask(task_def.func, task_def.stack_size) catch @panic("Failed to add user task");
            }

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
            if (self.tasks_count == 0) @panic("Cannot run scheduler with no tasks");

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

        fn addTask(self: *Self, task_fn_ptr: *const fn () void, stack_size: usize) !u8 {
            const task_id = self.tasks_count;
            if (task_id >= self.tasks.len) return error.NoMoreTaskSlots;

            const current_task = &self.tasks[task_id];

            const total_task_stack_size = stack_size + MINIMAL_CONTEXT_STACK_SIZE;

            // The stack pointer should point to the top of the allocated block,
            // as the stack grows downwards.
            const initial_sp: u32 = @intCast(self.next_stack_addr + total_task_stack_size);

            // Set the SP and PC for the new task.
            current_task.sp = initial_sp;
            current_task.next_addr = @intFromPtr(task_fn_ptr);
            current_task.setState(.ready);

            // Shift the pointer to allocate memory for the next task's stack.
            self.next_stack_addr += total_task_stack_size;

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
    // 1. Atomically swap to the scheduler stack.
    //    The task's SP is saved into mscratch, and sp is loaded with the scheduler's stack pointer.
        \\ csrrw sp, mscratch, sp
        \\ 
        // We are now on the scheduler's private stack.
        // 2. Save ra since we are about to make a call.
        \\ addi sp, sp, -4
        \\ sw ra, 0(sp)
        \\ 
        // 3. Prepare arguments for zico_scheduler_logic(self_ptr: *anyopaque, current_sp: u32)
        //    - arg0 (a0): self_ptr, loaded from the global g_zico_instance.
        //    - arg1 (a1): The interrupted task's SP, which is now in 'mscratch'.
        \\ .option push
        \\ .option norelax
        \\ la a0, g_zico_instance
        \\ .option pop
        \\ lw a0, (a0)
        \\ csrr a1, mscratch
        \\ 
        // 4. Call the C ABI scheduler logic function.
        \\ jal ra, %[logic]
        \\ 
        // After return, a0 holds the pointer to the next TSS.
        // 5. Restore our stack frame.
        \\ lw ra, 0(sp)
        \\ addi sp, sp, 4
        \\ 
        // 6. Perform the final context switch for the new task.
        //    Restore sp and mepc from the new TSS.
        \\ lw sp, 0(a0)      // tss.sp
        \\ lw a1, 4(a0)      // tss.next_addr
        \\ csrw mepc, a1
        \\ 
        // 7. Return from exception. This will restore the new task's context
        //    and correctly handle the interrupt-enable state.
        \\ mret
        :
        : [logic] "i" (zico_scheduler_logic),
        : .{ .memory = true, .x1 = true, .x2 = true, .x5 = true, .x6 = true, .x10 = true, .x11 = true });
}
