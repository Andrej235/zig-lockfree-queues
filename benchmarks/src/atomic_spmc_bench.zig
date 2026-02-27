const std = @import("std");
const core = @import("core");
const Queue = core.SPMC.Atomic(u64);

// config
const TOTAL_ITEMS: usize = 100_000_000;

const BenchState = struct {
    queue: *Queue,

    start_flag: std.atomic.Value(bool),
    producer_done: std.atomic.Value(bool),
    produced: std.atomic.Value(usize),
    consumed: std.atomic.Value(usize),

    // prevents false sharing
    _pad1: [64]u8 = undefined,
};

fn consumerThread(state: *BenchState) void {
    // wait for synchronized start
    while (!state.start_flag.load(.acquire)) {
        std.atomic.spinLoopHint();
    }

    while (!state.producer_done.load(.acquire) and state.consumed.load(.acquire) < TOTAL_ITEMS) {
        if (state.queue.tryDequeue()) |item| {
            std.mem.doNotOptimizeAway(item);

            _ = state.consumed.fetchAdd(1, .acq_rel);
        } else {
            // empty queue
            std.atomic.spinLoopHint();
        }
    }
}

fn producerThread(state: *BenchState) void {
    while (!state.start_flag.load(.acquire)) {
        std.atomic.spinLoopHint();
    }

    var i: usize = 0;
    while (i < TOTAL_ITEMS) {
        state.queue.tryEnqueue(@intCast(i)) catch continue;

        _ = state.produced.fetchAdd(1, .release);
        i += 1;
    }

    state.producer_done.store(true, .release);
}

fn runBenchmark(
    allocator: std.mem.Allocator,
    consumer_count: usize,
) !void {
    std.debug.print(
        "\n=== Consumers: {} ===\n",
        .{consumer_count},
    );

    var queue = try Queue.init(allocator, 64);
    defer queue.deinit(allocator);

    var state = BenchState{
        .queue = &queue,
        .start_flag = std.atomic.Value(bool).init(false),
        .producer_done = std.atomic.Value(bool).init(false),
        .produced = std.atomic.Value(usize).init(0),
        .consumed = std.atomic.Value(usize).init(1),
    };

    // spawn consumers
    const consumers = try allocator.alloc(std.Thread, consumer_count);
    defer allocator.free(consumers);

    for (consumers) |*t| {
        t.* = try std.Thread.spawn(.{}, consumerThread, .{&state});
    }

    // spawn producer
    var producer = try std.Thread.spawn(.{}, producerThread, .{&state});

    // warmup delay (lets threads settle)
    std.Thread.sleep(100 * std.time.ns_per_ms);

    const start = std.time.nanoTimestamp();

    state.start_flag.store(true, .release);

    producer.join();

    for (consumers) |*t| {
        t.join();
    }

    const end = std.time.nanoTimestamp();

    const elapsed_ns: u64 = @intCast(end - start);

    const seconds =
        @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

    const throughput =
        @as(f64, @floatFromInt(TOTAL_ITEMS)) / seconds;

    const throughputStr = try formatWithCommasAlloc(std.heap.page_allocator, throughput);

    std.debug.print(
        "time: {d:.3}s\nthroughput: {s} ops/sec\n",
        .{ seconds, throughputStr },
    );
}

fn formatWithCommasAlloc(
    allocator: std.mem.Allocator,
    value: anytype,
) ![]u8 {
    const T = @TypeOf(value);
    comptime {
        const info = @typeInfo(T);
        switch (info) {
            .int, .float, .comptime_int, .comptime_float => {},
            else => @compileError("Unsupported type for formatting"),
        }
    }

    const original = try std.fmt.allocPrint(allocator, "{d:.0}", .{value});
    defer allocator.free(original);
    var with_commas = try allocator.alloc(u8, original.len + @divFloor(original.len, 3));

    var comma_count: usize = 0;
    for (0..original.len) |i| {
        with_commas[i + comma_count] = original[i];
        if ((original.len - i - 1) % 3 == 0 and i != original.len - 1) {
            comma_count += 1;
            with_commas[i + comma_count] = ',';
        }
    }

    return with_commas;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const cpu_count = try std.Thread.getCpuCount();
    std.debug.print("CPU cores detected: {}\n", .{cpu_count});

    // scaling test
    var c: usize = 1;
    while (c <= cpu_count) : (c *= 2) {
        try runBenchmark(allocator, c);
    }
}
