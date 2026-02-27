const std = @import("std");

pub fn Bench(comptime TQueue: type, comptime total_items: usize, comptime label: @Type(.enum_literal)) type {
    comptime {
        if (@typeInfo(TQueue) != .@"struct") {
            @compileError("Queue must be a struct");
        }

        if (!@hasDecl(TQueue, "init")) {
            @compileError("Queue must have init method");
        }

        const init_fn_type_info = @typeInfo(@TypeOf(TQueue.init));
        if (init_fn_type_info != .@"fn") {
            @compileError("Queue init must be a function");
        }

        const init_fn_params = @typeInfo(@TypeOf(TQueue.init)).@"fn".params;
        if (init_fn_params.len != 2) {
            @compileError("Queue init must take exactly 2 parameters (allocator, capacity)");
        }

        if (init_fn_params[0].type != std.mem.Allocator) {
            @compileError("First parameter of Queue init must be std.mem.Allocator");
        }

        if (init_fn_params[1].type != usize) {
            @compileError("Second parameter of Queue init must be usize (capacity)");
        }

        const init_return_type_info = @typeInfo(init_fn_type_info.@"fn".return_type orelse void);
        if (init_return_type_info != .error_union or init_return_type_info.error_union.payload != TQueue) {
            @compileError("Queue init must return !TQueue");
        }

        if (!@hasDecl(TQueue, "tryEnqueue")) {
            @compileError("Queue must have tryEnqueue method");
        }

        if (!@hasDecl(TQueue, "tryDequeue")) {
            @compileError("Queue must have tryDequeue method");
        }
    }

    const State = struct {
        queue: *TQueue,

        start_flag: std.atomic.Value(bool),
        producer_done: std.atomic.Value(bool),
        produced: std.atomic.Value(usize),
        consumed: std.atomic.Value(usize),

        // prevents false sharing
        _pad1: [64]u8 = undefined,
    };

    return struct {
        fn consumerThread(state: *State) void {
            // wait for synchronized start
            while (!state.start_flag.load(.acquire)) {
                std.atomic.spinLoopHint();
            }

            while (!state.producer_done.load(.acquire) and state.consumed.load(.acquire) < total_items) {
                if (state.queue.tryDequeue()) |item| {
                    std.mem.doNotOptimizeAway(item);

                    _ = state.consumed.fetchAdd(1, .acq_rel);
                } else {
                    // empty queue
                    std.atomic.spinLoopHint();
                }
            }
        }

        fn producerThread(state: *State) void {
            while (!state.start_flag.load(.acquire)) {
                std.atomic.spinLoopHint();
            }

            var i: usize = 0;
            while (i < total_items) {
                state.queue.tryEnqueue(@intCast(i)) catch continue;

                _ = state.produced.fetchAdd(1, .release);
                i += 1;
            }

            state.producer_done.store(true, .release);
        }

        pub fn run(
            allocator: std.mem.Allocator,
            consumer_count: usize,
            producer_count: usize,
        ) !void {
            std.debug.print(
                "\n--- Benchmark: {} with {} consumers and {} producers ---\n",
                .{ label, consumer_count, producer_count },
            );

            var queue = try TQueue.init(allocator, 64);
            defer queue.deinit(allocator);

            var state = State{
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

            // spawn producers
            const producers = try allocator.alloc(std.Thread, producer_count);
            defer allocator.free(producers);

            for (producers) |*t| {
                t.* = try std.Thread.spawn(.{}, producerThread, .{&state});
            }

            // warmup delay (lets threads settle)
            std.Thread.sleep(100 * std.time.ns_per_ms);

            const start = std.time.nanoTimestamp();

            state.start_flag.store(true, .release);

            for (producers) |*t| {
                t.join();
            }

            for (consumers) |*t| {
                t.join();
            }

            const end = std.time.nanoTimestamp();

            const elapsed_ns: u64 = @intCast(end - start);

            const seconds =
                @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000_000.0;

            const throughput =
                @as(f64, @floatFromInt(total_items)) / seconds;

            const throughputStr = try formatWithCommasAlloc(std.heap.page_allocator, throughput);

            std.debug.print(
                "time: {d:.3}s\nthroughput: {s} ops/sec\n",
                .{ seconds, throughputStr },
            );
        }
    };
}

pub fn formatWithCommasAlloc(
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

    var len_with_commas = original.len + @divFloor(original.len, 3);
    if (original.len % 3 == 0) {
        len_with_commas -= 1; // no leading comma if length is multiple of 3
    }

    var with_commas = try allocator.alloc(u8, len_with_commas);

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
