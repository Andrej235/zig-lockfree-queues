const std = @import("std");
const core = @import("core");
const Queue = core.SPSC.Atomic(u64);

// config
const TOTAL_ITEMS: usize = 100_000_000;
const Bench = @import("bench_utils.zig").Bench(Queue, TOTAL_ITEMS, .atomic_spsc);

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();

    const allocator = gpa.allocator();

    std.debug.print("Starting benchmark for Atomic SPSC Queue:\n", .{});

    try Bench.run(allocator, 1, 1);
}
