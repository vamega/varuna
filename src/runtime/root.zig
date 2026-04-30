pub const clock = @import("clock.zig");
pub const Clock = clock.Clock;
pub const kernel = @import("kernel.zig");
pub const probe = @import("probe.zig");
pub const requirements = @import("requirements.zig");

// Pull subsystem source-side `test "..."` blocks into the test runner.
// Mirrors the pattern in `src/io/root.zig` and `src/dht/root.zig`. Wired
// into `mod_tests` via `_ = runtime;` in `src/root.zig`'s test block.
test {
    _ = clock;
    _ = kernel;
    _ = probe;
    _ = requirements;
}
