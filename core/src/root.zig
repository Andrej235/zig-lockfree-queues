test {
    _ = @import("spsc/atomic_spcs.zig");

    _ = @import("spmc/mutex_spmc.zig");
    _ = @import("spmc/atomic_spmc.zig");
}

pub const SPSC = struct {
    pub const Atomic = @import("spsc/atomic_spcs.zig").Queue;
};

pub const SPMC = struct {
    pub const Mutex = @import("spmc/mutex_spmc.zig").Queue;
    pub const Atomic = @import("spmc/atomic_spmc.zig").Queue;
};
