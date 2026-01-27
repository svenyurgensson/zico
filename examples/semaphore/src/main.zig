const std = @import("std");
const hal = @import("hal");
const zico = @import("zico");

// A shared resource, e.g., a single-item buffer
var shared_buffer: ?u8 = null;

// A semaphore to signal when the buffer is full, starts at 0 (empty)
var buffer_full_sem = zico.Semaphore.init(0);
// A semaphore to signal when the buffer is empty, starts at 1 (empty)
var buffer_empty_sem = zico.Semaphore.init(1);

// Producer task: writes data to the buffer
fn producer_task() void {
    var data: u8 = 0;
    while (true) {
        // Wait until the buffer is empty (acquires the empty semaphore)
        buffer_empty_sem.wait();

        // Write to the shared resource
        shared_buffer = data;
        std.log.info("Produced: {}", .{data});
        data += 1;

        // Signal that the buffer is now full
        buffer_full_sem.signal();

        // Delay to allow consumer to run
        scheduler.delay(200);
    }
}

// Consumer task: reads data from the buffer
fn consumer_task() void {
    while (true) {
        // Wait until the buffer is full (acquires the full semaphore)
        buffer_full_sem.wait();

        // Read from the shared resource
        const data = shared_buffer orelse @panic("Buffer should not be null!");
        shared_buffer = null;
        std.log.info("Consumed: {}", .{data});

        // Signal that the buffer is now empty
        buffer_empty_sem.signal();

        // Delay to make the output readable
        scheduler.delay(1000);
    }
}

const AppTaskDefs = [_]zico.TaskDef{
    .{ .name = "producer", .func = &producer_task, .stack_size = 4 * 16 },
    .{ .name = "consumer", .func = &consumer_task, .stack_size = 4 * 16 },
};

pub const Scheduler = zico.Zico(&AppTaskDefs);
pub var scheduler: Scheduler = undefined;

pub const interrupts: hal.interrupts.VectorTable = .{
    .SysTick = hal.time.sysTickHandler,
    .HardFault = zico.InterruptHandler,
};

pub fn main() !void {
    const clock = hal.clock.setOrGet(.hsi_max);
    hal.time.init(clock);

    scheduler = Scheduler.init(.{
        .get_time_ms = hal.time.millis,
    });

    hal.interrupts.globalEnable();

    scheduler.runLoop();
}
