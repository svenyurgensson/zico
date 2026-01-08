const std = @import("std");
const zico = @import("./zico.zig");
const syscall = @import("./syscall.zig");

const MAX_WAITING_TASKS = 8;

pub const WaitQueue = struct {
    tasks: [MAX_WAITING_TASKS]u8 = undefined,
    head: u3 = 0,
    tail: u3 = 0,
    count: u4 = 0,

    pub fn enqueue(self: *WaitQueue, task_id: u8) !void {
        if (self.count >= MAX_WAITING_TASKS) return error.QueueFull;
        self.tasks[self.tail] = task_id;
        self.tail +%= 1;
        self.count += 1;
    }

    pub fn dequeue(self: *WaitQueue) ?u8 {
        if (self.count == 0) return null;
        const task_id = self.tasks[self.head];
        self.head +%= 1;
        self.count -= 1;
        return task_id;
    }
};

// This function generates a `ChannelHeader` struct at compile-time.
// To minimize memory usage, it dynamically creates the smallest possible unsigned
// integer types for `head`, `tail`, and `count` based on the channel's `size`.
pub fn ChannelHeader(comptime size: usize) type {
    if (size == 0) {
        @compileError("Channel size cannot be 0");
    }

    // Calculate the number of bits needed to store the index (0 to size-1).
    // This uses a formula with `@clz` (count leading zeros) to find the integer
    // log base 2 of (size - 1), and then adds 1.
    // The `if (size == 1)` is a special case to handle `@clz(0)`, which is undefined.
    const IndexBits = if (size == 1) 1 else ((@sizeOf(usize) * 8 - 1) - @clz(size - 1) + 1);
    // Create the smallest unsigned integer type that can hold the index.
    const IndexType = @Type(.{ .int = .{ .signedness = .unsigned, .bits = IndexBits } });

    // Calculate the number of bits needed to store the count (0 to size).
    const CountBits = (@sizeOf(usize) * 8 - 1) - @clz(size) + 1;
    // Create the smallest unsigned integer type that can hold the count.
    const CountType = @Type(.{ .int = .{ .signedness = .unsigned, .bits = CountBits } });

    return struct {
        pub const Index = IndexType;
        pub const Count = CountType;

        head: IndexType = 0,
        tail: IndexType = 0,
        count: CountType = 0,
        send_wait_queue: WaitQueue = .{},
        recv_wait_queue: WaitQueue = .{},
    };
}

pub fn Channel(comptime T: type, comptime size: usize) type {
    if (size == 0) {
        @compileError("Channel size cannot be 0");
    }
    return struct {
        const Self = @This();

        // Fixed-size header first
        header: ChannelHeader(size) = .{},
        // Variable-size buffer last
        buffer: [size]T,

        pub fn init() Self {
            return .{
                .buffer = undefined,
            };
        }

        pub fn send(self: *Self, message: T) void {
            if (self.header.count >= size) {
                syscall.ecall_args_ptr.a0 = @intFromEnum(syscall.EcallType.channel_send);
                syscall.ecall_args_ptr.a1 = @intFromPtr(&self.header.send_wait_queue);
                asm volatile ("ecall" ::: syscall.ClobbersForEcall);
                return self.send(message);
            }

            self.buffer[self.header.tail] = message;

            const HeaderType = @TypeOf(self.header);
            const new_tail_index = (@as(HeaderType.Count, self.header.tail) + 1) % @as(HeaderType.Count, size);
            self.header.tail = @intCast(new_tail_index);
            self.header.count += 1;

            if (self.header.recv_wait_queue.dequeue()) |task_id| {
                zico.wakeTask(task_id);
            }
        }

        pub fn receive(self: *Self) T {
            if (self.header.count == 0) {
                syscall.ecall_args_ptr.a0 = @intFromEnum(syscall.EcallType.channel_receive);
                syscall.ecall_args_ptr.a1 = @intFromPtr(&self.header.recv_wait_queue);
                asm volatile ("ecall" ::: syscall.ClobbersForEcall);
                return self.receive();
            }

            const message = self.buffer[self.header.head];

            const HeaderType = @TypeOf(self.header);
            const new_head_index = (@as(HeaderType.Count, self.header.head) + 1) % @as(HeaderType.Count, size);
            self.header.head = @intCast(new_head_index);

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
    wait_queue: WaitQueue = .{},

    pub fn init(initial_count: u8) Semaphore {
        return .{
            .count = initial_count,
            .wait_queue = .{},
        };
    }
    pub fn wait(self: *Semaphore) void {
        if (self.count > 0) {
            self.count -= 1;
        } else {
            // Block and let the scheduler add this task to the wait queue.
            syscall.ecall_args_ptr.a0 = @intFromEnum(syscall.EcallType.sem_wait);
            syscall.ecall_args_ptr.a1 = @intFromPtr(self);
            asm volatile ("ecall" ::: syscall.ClobbersForEcall);
        }
    }
    pub fn signal(self: *Semaphore) void {
        // If any tasks are waiting for this semaphore, wake one up.
        if (self.wait_queue.dequeue()) |task_id| {
            zico.wakeTask(task_id);
        } else {
            // Otherwise, increment the semaphore's count.
            self.count += 1;
        }
    }
};

test "WaitQueue functionality" {
    var queue = WaitQueue{};

    // Test 1: Enqueue and Dequeue basic operation
    try std.testing.expect(queue.dequeue() == null); // Empty queue

    try queue.enqueue(10);
    try queue.enqueue(20);
    try std.testing.expect(queue.count == 2);
    try std.testing.expect(queue.head == 0);
    try std.testing.expect(queue.tail == 2);

    try std.testing.expect(queue.dequeue().? == 10);
    try std.testing.expect(queue.dequeue().? == 20);
    try std.testing.expect(queue.dequeue() == null); // Should be empty again
    try std.testing.expect(queue.count == 0);
    try std.testing.expect(queue.head == 2);
    try std.testing.expect(queue.tail == 2);

    // Test 2: Queue full
    var i: u8 = 0;
    while (i < MAX_WAITING_TASKS) : (i += 1) {
        try queue.enqueue(i);
    }
    try std.testing.expect(queue.count == MAX_WAITING_TASKS);
    try std.testing.expectError(error.QueueFull, queue.enqueue(MAX_WAITING_TASKS)); // Should fail to enqueue more

    // Test 3: Wrap-around behavior
    for (0..MAX_WAITING_TASKS / 2) |_| {
        _ = queue.dequeue(); // Dequeue half the elements
    }
    try std.testing.expect(queue.count == MAX_WAITING_TASKS / 2);

    try queue.enqueue(100); // Enqueue some more
    try queue.enqueue(101);
    try std.testing.expect(queue.count == MAX_WAITING_TASKS / 2 + 2);

    // Continue dequeuing and checking order
    try std.testing.expect(queue.dequeue().? == MAX_WAITING_TASKS / 2);
    try std.testing.expect(queue.dequeue().? == MAX_WAITING_TASKS / 2 + 1);
    
    // Dequeue remaining
    while (queue.dequeue()) |task_id| {
        _ = task_id;
    }
    try std.testing.expect(queue.count == 0);
    try std.testing.expect(queue.head == queue.tail); // Head and tail should meet
}