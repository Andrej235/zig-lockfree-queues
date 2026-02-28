const std = @import("std");
const core = @import("core");
const Queue = core.SPMC.Mutex(u64);

// config
const TOTAL_ITEMS: usize = 100_000_000;
const Bench = @import("bench_utils.zig").Bench(Queue, TOTAL_ITEMS, .mutex_spmc);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    const cpu_count = try std.Thread.getCpuCount();
    std.debug.print("Starting benchmark for Mutex SPMC Queue (detected {} CPU cores):\n", .{cpu_count});

    // scaling test
    var c: usize = 1;
    while (c <= cpu_count) : (c *= 2) {
        try Bench.run(allocator, c, 1);
    }
}
