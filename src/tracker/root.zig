pub const announce = @import("announce.zig");
pub const scrape = @import("scrape.zig");
pub const types = @import("types.zig");
pub const udp = @import("udp.zig");

// Pull subsystem source-side `test "..."` blocks into the test runner.
// Mirrors the pattern in `src/io/root.zig` and `src/dht/root.zig`. Wired
// into `mod_tests` via `_ = tracker;` in `src/root.zig`'s test block.
test {
    _ = announce;
    _ = scrape;
    _ = udp;
}
