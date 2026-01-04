const std = @import("std");
const zico = @import("./zico.zig");

const MAX_WAITING_TASKS = 8;

const WaitQueue = struct {
    tasks: [MAX_WAITING_TASKS]u8,
    head: u4 = 0,
    tail: u4 = 0,
    count: u4 = 0,

    fn enqueue(self: *WaitQueue, task_id: u8) !void {
        if (self.count >= MAX_WAITING_TASKS) return error.QueueFull;
        self.tasks[self.tail] = task_id;
        self.tail = (self.tail + 1) % MAX_WAITING_TASKS;
        self.count += 1;
    }

    fn dequeue(self: *WaitQueue) ?u8 {
        if (self.count == 0) return null;
        const task_id = self.tasks[self.head];
        self.head = (self.head + 1) % MAX_WAITING_TASKS;
        self.count -= 1;
        return task_id;
    }
};

pub fn Channel(comptime T: type, comptime size: usize) type {
    return struct {
        const Self = @This();

        buffer: [size]T,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,

        send_wait_queue: WaitQueue = .{},
        recv_wait_queue: WaitQueue = .{},

        pub fn init() Self {
            return .{ .buffer = undefined };
        }

        pub fn send(self: *Self, message: T) !void {
            // If the buffer is full, block the current task.
            if (self.count >= size) {
                const current_task_id = zico.getCurrentTaskId();
                try self.send_wait_queue.enqueue(current_task_id);
                // Make an ecall to block this task until it's woken up.
                asm volatile ("li a0, %[ecall_type]\nmv a1, %[wait_obj]\necall"
                    : // No output
                    : [ecall_type] "i" (@intFromEnum(zico.EcallType.channel_send)),
                      [wait_obj] "r" (self)
                    : zico.ClobbersYield);
            }

            // Add the message to the circular buffer.
            self.buffer[self.tail] = message;
            self.tail = (self.tail + 1) % size;
            self.count += 1;

            // If a task is waiting to receive, wake it up.
            if (self.recv_wait_queue.dequeue()) |task_id| {
                zico.wakeTask(task_id);
            }
        }

        pub fn receive(self: *Self) !T {
            // If the buffer is empty, block the current task.
            if (self.count == 0) {
                const current_task_id = zico.getCurrentTaskId();
                try self.recv_wait_queue.enqueue(current_task_id);
                // Make an ecall to block this task until a message is sent.
                asm volatile ("li a0, %[ecall_type]\nmv a1, %[wait_obj]\necall"
                    : // No output
                    : [ecall_type] "i" (@intFromEnum(zico.EcallType.channel_receive)),
                      [wait_obj] "r" (self)
                    : zico.ClobbersYield);
            }

            // Retrieve the message from the circular buffer.
            const message = self.buffer[self.head];
            self.head = (self.head + 1) % size;
            self.count -= 1;

            // If a task is waiting to send, wake it up.
            if (self.send_wait_queue.dequeue()) |task_id| {
                zico.wakeTask(task_id);
            }

            return message;
        }
    };
}
