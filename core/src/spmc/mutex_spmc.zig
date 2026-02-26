const std = @import("std");

pub const QueueErrors = error{
    QueueFull,
};

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();

        mutex: std.Thread.Mutex = .{},

        buf: []T,
        head: usize = 0,
        tail: usize = 0,
        count: usize = 0,

        pub fn init(allocator: std.mem.Allocator, count: usize) !Self {
            const buffer = try allocator.alloc(T, count);

            return Self{
                .buf = buffer,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.buf);
        }

        pub fn tryEnqueue(self: *Self, item: T) QueueErrors!void {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.count == self.buf.len) {
                return QueueErrors.QueueFull;
            }

            self.buf[self.tail] = item;
            self.tail = (self.tail + 1) % self.buf.len;
            self.count += 1;
        }

        pub fn tryDequeue(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.count == 0) {
                return null;
            }

            const item = self.buf[self.head];
            self.head = (self.head + 1) % self.buf.len;
            self.count -= 1;

            return item;
        }

        pub fn tryPeek(self: *Self) ?*T {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.closed or self.count == 0) {
                return null;
            }

            const item = &self.buf[self.head];
            return item;
        }

        pub fn isEmpty(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.count == 0;
        }

        pub fn isFull(self: *Self) bool {
            self.mutex.lock();
            defer self.mutex.unlock();

            return self.count == self.buf.len;
        }
    };
}

const testing = std.testing;

test "single threaded" {
    var queue = Queue(u32).init(std.heap.page_allocator, 4) catch unreachable;
    defer queue.deinit(std.heap.page_allocator);

    try queue.tryEnqueue(1);
    try queue.tryEnqueue(2);
    try queue.tryEnqueue(3);
    try queue.tryEnqueue(4);

    try testing.expectError(QueueErrors.QueueFull, queue.tryEnqueue(5));

    try testing.expectEqual(1, queue.tryDequeue());
    try testing.expectEqual(2, queue.tryDequeue());
    try testing.expectEqual(3, queue.tryDequeue());
    try testing.expectEqual(4, queue.tryDequeue());

    try testing.expectEqual(null, queue.tryDequeue());
}

test "1 producer, 1 consumer" {
    var queue = Queue(u32).init(std.heap.page_allocator, 4) catch unreachable;
    defer queue.deinit(std.heap.page_allocator);

    const producer = std.Thread.spawn(.{}, producerFn, .{ &queue, 1024 }) catch unreachable;
    const consumer = std.Thread.spawn(.{}, consumerFn, .{ &queue, 1024, 1 }) catch unreachable;

    producer.join();
    consumer.join();

    try testing.expectEqual(true, queue.isEmpty());
}

test "1 producer, 16 consumers" {
    var queue = Queue(u32).init(std.heap.page_allocator, 4) catch unreachable;
    defer queue.deinit(std.heap.page_allocator);

    const producer = std.Thread.spawn(.{}, producerFn, .{ &queue, 1024 }) catch unreachable;
    var consumers: [16]std.Thread = undefined;
    for (0..16) |i| {
        consumers[i] = std.Thread.spawn(.{}, consumerFn, .{ &queue, 1024, 16 }) catch unreachable;
    }

    producer.join();
    for (consumers) |consumer| {
        consumer.join();
    }

    try testing.expectEqual(true, queue.isEmpty());
}

fn producerFn(queue: *Queue(u32), comptime iteration_count: u32) !void {
    const start = std.time.milliTimestamp();
    const max_duration = 1000; // 1 second

    var i: u32 = 0;
    while (i < iteration_count) {
        queue.tryEnqueue(i) catch {
            if (std.time.milliTimestamp() - start > max_duration) {
                return error.Timeout;
            }
            continue;
        };
        i += 1;
    }
}

fn consumerFn(queue: *Queue(u32), comptime total_iterations: u32, comptime consumer_count: u32) !void {
    const start = std.time.milliTimestamp();
    const max_duration = 1000; // 1 second

    if (comptime total_iterations % consumer_count != 0) {
        @compileError("iteration_count must be divisible by consumer_count");
    }

    var count: usize = 0;
    while (count < comptime total_iterations / consumer_count) {
        if (queue.tryDequeue()) |item| {
            _ = item;
            count += 1;
        } else {
            if (std.time.milliTimestamp() - start > max_duration) {
                return error.Timeout;
            }
        }
    }
}
