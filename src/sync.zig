const std = @import("std");
const zico = @import("./zico.zig");
const syscall = @import("./syscall.zig");

const MAX_WAITING_TASKS = 8;

pub const WaitQueue = struct {
    tasks: [MAX_WAITING_TASKS]u8 = undefined,
    head: u4 = 0,
    tail: u4 = 0,
    count: u4 = 0,

    pub fn enqueue(self: *WaitQueue, task_id: u8) !void {
        if (self.count >= MAX_WAITING_TASKS) return error.QueueFull;
        self.tasks[self.tail] = task_id;
        self.tail = (self.tail + 1) % MAX_WAITING_TASKS;
        self.count += 1;
    }

    pub fn dequeue(self: *WaitQueue) ?u8 {
        if (self.count == 0) return null;
        const task_id = self.tasks[self.head];
        self.head = (self.head + 1) % MAX_WAITING_TASKS;
        self.count -= 1;
        return task_id;
    }
};

/// Contains the fixed-size management fields for a Channel.
/// By placing this at the beginning of the Channel struct, we ensure
/// it has a predictable memory layout, which is crucial for the scheduler.
pub const ChannelHeader = struct {
    head: usize = 0,
    tail: usize = 0,
    count: usize = 0,
    send_wait_queue: WaitQueue = .{},
    recv_wait_queue: WaitQueue = .{},
};

pub fn Channel(comptime T: type, comptime size: usize) type {
    return struct {
        const Self = @This();

        // Fixed-size header first
        header: ChannelHeader = .{},
        // Variable-size buffer last
        buffer: [size]T,

        pub fn init() Self {
            return .{
                .buffer = undefined,
            };
        }

        pub fn send(self: *Self, message: T) !void {
            if (self.header.count >= size) {
                zico.ecall_args_ptr.a0 = @intFromEnum(zico.EcallType.channel_send);
                zico.ecall_args_ptr.a1 = @intFromPtr(&self.header);
                asm volatile ("ecall" ::: zico.ClobbersForEcall);
                return self.send(message);
            }

            self.buffer[self.header.tail] = message;
            self.header.tail = (self.header.tail + 1) % size;
            self.header.count += 1;

            if (self.header.recv_wait_queue.dequeue()) |task_id| {
                zico.wakeTask(task_id);
            }
        }

        pub fn receive(self: *Self) !T {
            if (self.header.count == 0) {
                zico.ecall_args_ptr.a0 = @intFromEnum(zico.EcallType.channel_receive);
                zico.ecall_args_ptr.a1 = @intFromPtr(&self.header);
                asm volatile ("ecall" ::: zico.ClobbersForEcall);
                return self.receive();
            }

            const message = self.buffer[self.header.head];
            self.header.head = (self.header.head + 1) % size;
            self.header.count -= 1;

            if (self.header.send_wait_queue.dequeue()) |task_id| {
                zico.wakeTask(task_id);
            }

            return message;
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
            syscall.ecall_args_ptr.a0 = @intFromEnum(syscall.EcallType.sem_wait);
            syscall.ecall_args_ptr.a1 = @intFromPtr(self);
            asm volatile ("ecall");
        }
    }
    pub fn signal(self: *Semaphore) void {
        self.count += 1;
        syscall.ecall_args_ptr.a0 = @intFromEnum(syscall.EcallType.sem_signal);
        syscall.ecall_args_ptr.a1 = @intFromPtr(self);
        asm volatile ("ecall");
    }
};
