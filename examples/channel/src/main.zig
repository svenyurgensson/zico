const std = @import("std");
const hal = @import("hal");
const zico = @import("zico");

// Define a channel that can hold 4 `u8` messages.
var data_channel = zico.Channel(u8, 4).init();

// Sender task
fn sender_task() void {
    var count: u8 = 0;
    while (true) {
        data_channel.send(count);
        std.log.info("Sent: {}", .{count});
        count += 1;
        scheduler.delay(300); // Send every 300ms
    }
}

// Receiver task
fn receiver_task() void {
    while (true) {
        const received_value = data_channel.receive();
        std.log.warn("Received: {}", .{received_value});
        scheduler.delay(1000); // Process every 1000ms
    }
}

const AppTaskDefs = [_]zico.TaskDef{
    .{ .name = "sender", .func = &sender_task, .stack_size = 4 * 16 },
    .{ .name = "receiver", .func = &receiver_task, .stack_size = 4 * 16 },
};

// ... main function and scheduler setup ...
pub const Scheduler = zico.Zico(&AppTaskDefs);
pub var scheduler: Scheduler = undefined;

pub const interrupts: hal.interrupts.VectorTable = .{
    .SysTick = hal.time.sysTickHandler,
    .HardFault = zico.InterruptHandler,
};

pub fn main() !void {
    const clock = hal.clock.setOrGet(.hsi_max);
    hal.time.init(clock);

    scheduler = Scheduler.init();

    hal.interrupts.globalEnable();

    scheduler.runLoop();
}
