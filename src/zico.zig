const std = @import("std");
const hal = @import("hal");
const svd = @import("svd");
const PFIC = svd.peripherals.PFIC;
const task = @import("./task.zig");
pub const TaskDef = task.TaskDef;

/// Global variable to store a type-erased pointer to the active Zico scheduler instance.
/// This allows access to the scheduler from interrupt service routines (ISRs).
var zico_instance: ?*anyopaque = null;

/// Global function pointer to the scheduler's internal `scheduleNextTask_trampoline`.
/// Used by the `switchTaskISR` to delegate scheduling logic.
var schedule_fn: ?*const fn () void = null;

/// The default idle task that runs when no other tasks are ready.
/// It continuously yields control to the scheduler.
fn idleTask() void {
    while (true) {
        asm volatile ("li a0, %[yield_type]\necall"
            : // output
            : [yield_type] "i" (@intFromEnum(EcallType.yield)),
            : .{ // clobbering
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
            });
    }
}

/// Defines the types of system calls (ecall) available to tasks
/// to interact with the scheduler.
pub const EcallType = enum(u8) {
    /// Task voluntarily yields control to the scheduler.
    yield = 0,
    /// Task requests a delay for a specified duration.
    delay = 1,
    /// Task suspends itself indefinitely.
    suspend_self = 2,
    /// Task waits for a semaphore to become available.
    sem_wait = 3,
    /// Task signals a semaphore, potentially unblocking other tasks.
    sem_signal = 4,
};

/// Represents the current state of a task in the scheduler.
pub const TaskState = enum(u4) {
    /// Task is not active (initial state, or unused slot).
    idle = 0,
    /// Task is ready to run.
    ready = 2,
    /// Task is manually suspended.
    suspended = 3,
    /// Task is waiting for a timer to expire (e.g., after `delay`).
    waiting_on_timer = 4,
    /// Task is waiting for a semaphore.
    waiting_on_semaphore = 5,
    // Future states could include:
    // waiting_on_mutex,
    // waiting_on_channel_send,
    // waiting_on_channel_receive,
};

/// Packed flags and state for a Task State Segment (TSS).
/// This structure is designed to be memory-efficient.
pub const TaskFlags = struct {
    /// The current state of the task.
    state: TaskState,
    /// Flag indicating if the task has a pending message in its private queue (future use).
    has_message: bool,
    /// Priority of the task (0-7), for future scheduler enhancements.
    priority: u3,
};

/// Task State Segment (TSS) structure.
/// Stores the essential context for a task to be restored or suspended.
pub const TSS = struct {
    /// The address of the next instruction to execute when the task resumes.
    next_addr: u32,
    /// Packed flags and state of the task.
    flags: TaskFlags,
    /// Pointer to the synchronization object the task is waiting on, if any.
    wait_obj: ?*anyopaque,
    /// Timer value for delay operations.
    delay_timer: u16,

    /// Initializes a new TSS for a given task entry point.
    pub fn init(entry_point: u32) TSS {
        return .{
            .next_addr = entry_point,
            .flags = .{ .state = .idle, .has_message = false, .priority = 0 },
            .wait_obj = null,
            .delay_timer = 0,
        };
    }

    /// Returns the current state of the task.
    pub inline fn getState(self: *const TSS) TaskState {
        return self.flags.state;
    }
    /// Sets the state of the task.
    pub inline fn setState(self: *TSS, new_state: TaskState) void {
        self.flags.state = new_state;
    }
    /// Returns the current delay timer value.
    pub inline fn getDelayTimer(self: *const TSS) u16 {
        return self.delay_timer;
    }
    /// Sets the delay timer value.
    pub inline fn setDelayTimer(self: *TSS, timer: u16) void {
        self.delay_timer = timer;
    }
};

/// Zico scheduler generic function.
/// It generates a concrete scheduler type based on the provided compile-time array of `TaskDef`s.
///
/// This function returns a struct type that represents the scheduler instance,
/// containing its state and methods.
pub fn Zico(comptime task_defs: []const task.TaskDef) type {
    return struct {
        const Self = @This();

        // --- Scheduler Internal Fields ---
        tasks: []TSS,
        tasks_count: u8 = 0,
        current_task: u8 = 0,
        last_timer_update_ms: u32 = 0,

        // --- Compile-time Generated Types ---
        /// A tagged union of all task function pointers, generated from `task_defs`.
        pub const TaskUnion = task.CreateTaskUnion(task_defs);
        /// An enum representing the IDs of all defined tasks.
        /// This is used for functions like `suspendTask` or `resumeTask`.
        pub const TaskID = @typeInfo(TaskUnion).@"union".tag_type.?;

        /// Maximum number of tasks the scheduler can manage (Idle task + user-defined tasks).
        const TASK_COUNT = 1 + task_defs.len;
        /// Static storage for all Task State Segments (TSS).
        var tasks_storage: [TASK_COUNT]TSS = undefined;

        /// The interrupt handler for the Software Interrupt (SWI).
        /// This handler is responsible for switching tasks.
        pub const SoftwareInterruptHandler = @as(hal.interrupts.Handler, @ptrCast(&switchTaskISR));

        // --- Public API for the Scheduler Instance ---
        /// Initializes the scheduler, adding the idle task and all user-defined tasks.
        /// This function must be called once before `runLoop`.
        pub fn init() Self {
            var self = Self{
                .tasks = &tasks_storage,
                .tasks_count = 0,
                .current_task = 0,
                .last_timer_update_ms = 0,
            };

            // Store a type-erased pointer to this scheduler instance globally for ISR access.
            zico_instance = &self;
            // Store the trampoline function globally for the ISR.
            schedule_fn = &scheduleNextTask_trampoline;
            // Initialize the internal timer.
            self.last_timer_update_ms = hal.time.millis();

            // Add the mandatory idle task.
            _ = self.addTask(&idleTask) catch @panic("Failed to add idle task");
            self.tasks[0].setState(.ready);

            // Add all user-defined tasks from the `task_defs` array.
            inline for (task_defs) |task_def| {
                const task_id = self.addTask(task_def.func) catch @panic("Failed to add user task");
                self.tasks[task_id].setState(.ready);
            }

            return self;
        }

        /// Causes the current task to voluntarily yield control to the scheduler.
        /// The task will be marked as ready and scheduled again in the future.
        pub inline fn yield(_: *Self) void {
            asm volatile ("li a0, %[yield_type]\necall"
                : // output registers
                : [yield_type] "i" (@intFromEnum(EcallType.yield)),
                : .{ // clobbered registers
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
                });
        }

        /// Causes the current task to suspend itself indefinitely until resumed externally.
        pub inline fn suspendSelf(_: *Self) void {
            asm volatile ("li a0, %[suspend_type]\necall"
                : // output registers
                : [suspend_type] "i" (@intFromEnum(EcallType.suspend_self)),
                : .{ // clobbered registers
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
                });
        }

        /// Causes the current task to delay its execution for `N` milliseconds.
        /// The task will transition to `waiting_on_timer` state.
        pub inline fn delay(_: *Self, N: u16) void {
            asm volatile ("li a0, %[delay_type]\nmv a1, %[delay_val]\necall"
                : // output registers
                : [delay_type] "i" (@intFromEnum(EcallType.delay)),
                  [delay_val] "r" (N),
                : .{ // clobbered registers
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
                });
        }

        /// Suspends a specific task identified by `task_id`.
        /// The task will transition to `suspended` state.
        pub fn suspendTask(self: *Self, task_id: Self.TaskID) void {
            // TaskID enum values correspond to indices in `task_defs` + 1 (because index 0 is for idleTask).
            const idx = @intFromEnum(task_id) + 1;

            if (idx < self.tasks_count) {
                self.tasks[idx].setState(.suspended);
            }
        }

        /// Resumes a previously suspended task identified by `task_id`.
        /// The task will transition to `ready` state.
        pub fn resumeTask(self: *Self, task_id: Self.TaskID) void {
            // TaskID enum values correspond to indices in `task_defs` + 1.
            const idx = @intFromEnum(task_id) + 1;

            if (idx < self.tasks_count) {
                self.tasks[idx].setState(.ready);
            }
        }

        /// Starts the scheduler's main loop. This function never returns.
        /// It will run the first task (usually the idle task) and then switch
        /// between tasks based on calls to `yield`, `delay`, etc.
        pub fn runLoop(self: *Self) noreturn {
            if (self.tasks_count == 0) @panic("Cannot run scheduler with no tasks");
            // Start with the idle task (index 0).
            self.current_task = 0;
            const current_task_ref = &self.tasks[self.current_task];
            // Load the entry address of the first task into MEPC (Machine Exception Program Counter).
            hal.cpu.csr.mepc.write(current_task_ref.next_addr);
            // Execute `mret` to return from machine mode into the context of the first task.
            asm volatile ("mret");
            unreachable; // Should never be reached.
        }

        // --- Internal Methods ---
        /// Adds a new task to the scheduler's task list.
        /// Returns the assigned task index.
        fn addTask(self: *Self, task_fn_ptr: *const fn () void) !u8 {
            const task_id = self.tasks_count;
            if (task_id >= self.tasks.len) return error.NoMoreTaskSlots;

            const entry_addr = @intFromPtr(task_fn_ptr);
            self.tasks[task_id] = TSS.init(@as(u32, @truncate(entry_addr)));
            self.tasks_count += 1;
            return task_id;
        }

        /// Internal scheduler logic invoked by the Software Interrupt handler.
        /// This function saves the context of the current task, updates its state
        /// based on the ecall type, selects the next ready task, and restores its context.
        fn scheduleNextTask_internal(self: *Self) void {
            var ecall_type_raw: u32 = undefined;
            var ecall_arg: u32 = undefined;
            // Read ecall type (a0) and argument (a1) from registers.
            asm volatile (""
                : [t] "= {a0}" (ecall_type_raw),
                  [a] "= {a1}" (ecall_arg),
            );
            const ecall_type: EcallType = @enumFromInt(@as(u8, @truncate(ecall_type_raw)));

            // Save the current program counter (MEPC) as the next_addr for the current task.
            const current_mepc = hal.cpu.csr.mepc.read();
            self.tasks[self.current_task].next_addr = current_mepc;

            var should_switch: bool = true;

            // Process the ecall type to update the current task's state.
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
                    // Find and unblock one task waiting on this semaphore.
                    for (self.tasks) |*t| {
                        if (t.getState() == .waiting_on_semaphore and t.wait_obj == sem_ptr) {
                            t.setState(.ready);
                            t.wait_obj = null;
                            break; // Unblock only one task.
                        }
                    }
                    should_switch = false; // Signaling a semaphore doesn't necessarily mean switching context.
                },
            }

            // If a context switch is not needed (e.g., during sem_signal),
            // restore MEPC and clear SWI.
            if (!should_switch) {
                hal.cpu.csr.mepc.write(current_mepc);
                PFIC.STK_CTLR.modify(.{ .SWIE = 0 }); // Clear the Software Interrupt pending bit.
                return;
            }

            // Update timers for tasks in delay.
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

            // Select the next ready task using a round-robin approach.
            var next_task_idx: usize = self.current_task;
            var i: usize = 0;
            const tasks_len = self.tasks_count;
            while (i < tasks_len) : (i += 1) {
                next_task_idx = (next_task_idx + 1) % tasks_len;
                if (self.tasks[next_task_idx].getState() == .ready) break;
            }

            // If no other task is ready, default back to the idle task (index 0).
            if (self.tasks[next_task_idx].getState() != .ready) {
                next_task_idx = 0;
            }
            self.current_task = @as(u8, @intCast(next_task_idx));

            // Load the next task's resume address into MEPC.
            const next_mepc_addr = self.tasks[self.current_task].next_addr;
            hal.cpu.csr.mepc.write(next_mepc_addr);
            // Clear the Software Interrupt pending bit.
            PFIC.STK_CTLR.modify(.{ .SWIE = 0 });
        }

        /// A trampoline function to call `scheduleNextTask_internal` from the ISR context.
        /// It unwraps the global `zico_instance` to get the current scheduler.
        fn scheduleNextTask_trampoline() void {
            const zico_unwrapped: *anyopaque = zico_instance orelse return;
            const zico: *Self = @ptrCast(@alignCast(zico_unwrapped));
            zico.scheduleNextTask_internal();
        }
    };
}

/// A basic counting semaphore for inter-task synchronization.
pub const Semaphore = struct {
    /// The current count of the semaphore.
    count: u8,

    /// Initializes a semaphore with an `initial_count`.
    pub fn init(initial_count: u8) Semaphore {
        return .{ .count = initial_count };
    }

    /// Attempts to acquire the semaphore.
    /// If the count is zero, the calling task will block (`waiting_on_semaphore`).
    pub fn wait(self: *Semaphore) void {
        if (self.count > 0) {
            self.count -= 1;
        } else {
            // Perform an ecall to block the task and wait for the semaphore.
            asm volatile ("li a0, %[sem_wait_type]\nmv a1, %[sem_ptr]\necall"
                : // output registers
                : [sem_wait_type] "i" (@intFromEnum(EcallType.sem_wait)),
                  [sem_ptr] "r" (self), // Pass pointer to semaphore as argument
                : .{ // clobbered registers
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
                });
        }
    }

    /// Releases the semaphore, incrementing its count.
    /// If tasks are waiting on this semaphore, one will be unblocked (`ready`).
    pub fn signal(self: *Semaphore) void {
        self.count += 1;
        // Perform an ecall to signal the semaphore and potentially unblock a task.
        asm volatile ("li a0, %[sem_signal_type]\nmv a1, %[sem_ptr]\necall"
            : // output registers
            : [sem_signal_type] "i" (@intFromEnum(EcallType.sem_signal)),
              [sem_ptr] "r" (self), // Pass pointer to semaphore as argument
            : .{ // clobbered registers
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
            });
    }
};

/// The main Software Interrupt (SWI) handler.
/// This function is called directly by the hardware when a software interrupt is triggered.
/// It delegates to the `scheduleNextTask` function.
pub fn switchTaskISR() callconv(.naked) void {
    // Jump to `scheduleNextTask` and then return from machine mode.
    asm volatile ("jal ra, %[scheduler]\nmret"
        :
        : [scheduler] "i" (scheduleNextTask),
        : .{ .memory = true });
}

/// Exported C function for the software interrupt.
/// It calls the internal `schedule_fn` (trampoline) which then calls the scheduler logic.
export fn scheduleNextTask() void {
    if (schedule_fn) |f| {
        f();
    }
}
