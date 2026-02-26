test {
    _ = @import("spmc/mutex_spmc.zig");
    _ = @import("spmc/atomic_spmc.zig");
}

pub const SPMC = struct {
    pub const Mutex = @import("spmc/mutex_spmc.zig").Queue;
};
