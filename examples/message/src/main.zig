const std = @import("std");
const hal = @import("hal");
const zico = @import("zico");

// 1. Create a channel that can hold 4 `u8` messages.
// The `zico.Channel` function is available because we added `message.zig`
// as an import to the `zico` module in our `build.zig`.
var channel = zico.Channel(u8, 4).init();

// 2. Define the sender task
fn sender_task() void {
    var counter: u8 = 0;
    while (true) {
        // Send the counter value through the channel.
        // This will block if the channel buffer is full.
        channel.send(counter) catch |err| {
            std.log.err("Failed to send: {any}", .{err});
            scheduler.delay(1000);
            continue;
        };

        std.log.info("Sent: {}", .{counter});
        counter += 1;

        // Wait a bit before sending the next message.
        scheduler.delay(300);
    }
}

// 3. Define the receiver task
fn receiver_task() void {
    while (true) {
        // Receive a message from the channel.
        // This will block if the channel is empty.
        const received_msg = channel.receive() catch |err| {
            std.log.err("Failed to receive: {any}", .{err});
            scheduler.delay(1000);
            continue;
        };

        std.log.warn("Received: {}", .{received_msg});

        // Process the message...
        // Wait longer than the sender to see the buffer fill up.
        scheduler.delay(1000);
    }
}

// 4. Define the tasks for the scheduler
const AppTaskDefs = [_]zico.TaskDef{
    .{ .name = "sender", .func = &sender_task },
    .{ .name = "receiver", .func = &receiver_task },
};

// 5. Standard zico and HAL setup
pub const Scheduler = zico.Zico(&AppTaskDefs);
pub var scheduler: Scheduler = undefined;

pub const interrupts: hal.interrupts.VectorTable = .{
    .SysTick = hal.time.sysTickHandler,
    .SW = Scheduler.SoftwareInterruptHandler,
};

pub fn main() !void {
    const clock = hal.clock.setOrGet(.hsi_max);
    hal.time.init(clock);

    scheduler = Scheduler.init();

    hal.interrupts.globalEnable();

    scheduler.runLoop();
}
