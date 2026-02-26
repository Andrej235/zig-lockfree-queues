const std = @import("std");

pub const QueueErrors = error{
    QueueFull,
};

fn Cell(comptime T: type) type {
    return struct {
        data: T,
        sequence: std.atomic.Value(usize) = .init(0),
    };
}

pub fn Queue(comptime T: type) type {
    return struct {
        const Self = @This();
        const CellT = Cell(T);

        buffer: []CellT,
        head: std.atomic.Value(usize) = .init(0),
        tail: std.atomic.Value(usize) = .init(0),

        pub fn init(allocator: std.mem.Allocator, count: usize) !Self {
            const buffer = try allocator.alloc(CellT, count);

            for (buffer, 0..) |*slot, i| {
                slot.sequence = .init(i);
            }

            return Self{
                .buffer = buffer,
            };
        }

        pub fn deinit(self: *Self, allocator: std.mem.Allocator) void {
            allocator.free(self.buffer);
        }

        pub fn tryEnqueue(self: *Self, value: T) QueueErrors!void {
            const head = self.head.load(.monotonic);
            const slot = &self.buffer[head % self.buffer.len];

            const seq = slot.sequence.load(.acquire);
            const diff = @as(isize, @intCast(seq)) - @as(isize, @intCast(head));

            // queue full
            if (diff != 0)
                return QueueErrors.QueueFull;

            slot.data = value;

            // publish item
            slot.sequence.store(head + 1, .release);

            self.head.store(head + 1, .monotonic);
        }

        pub fn tryDequeue(self: *Self) ?T {
            while (true) { // loops until empty or successful pop
                const tail = self.tail.load(.acquire);
                const slot = &self.buffer[tail % self.buffer.len];

                const seq = slot.sequence.load(.acquire);

                const diff =
                    @as(isize, @intCast(seq)) -
                    @as(isize, @intCast(tail + 1));

                // queue empty
                if (diff < 0)
                    return null;

                // another consumer progressed
                if (diff > 0)
                    continue;

                // try to claim this index
                if (self.tail.cmpxchgWeak(
                    tail,
                    tail + 1,
                    .acq_rel,
                    .acquire,
                ) == null) {
                    const value = slot.data;

                    // mark slot reusable
                    slot.sequence.store(tail + self.buffer.len, .release);

                    return value;
                }

                // CAS failed, another consumer won -> retry
            }
        }

        pub fn isEmpty(self: *Self) bool {
            const tail = self.tail.load(.acquire);
            const slot = &self.buffer[tail % self.buffer.len];

            const seq = slot.sequence.load(.acquire);
            const diff = @as(isize, @intCast(seq)) - @as(isize, @intCast(tail + 1));

            return diff < 0;
        }

        pub fn isFull(self: *Self) bool {
            const head = self.head.load(.acquire);
            const slot = &self.buffer[head % self.buffer.len];

            const seq = slot.sequence.load(.acquire);
            const diff = @as(isize, @intCast(seq)) - @as(isize, @intCast(head));

            return diff != 0;
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
