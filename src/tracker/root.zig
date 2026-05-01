pub const announce = @import("announce.zig");
pub const executor = @import("executor.zig");
pub const scrape = @import("scrape.zig");
pub const types = @import("types.zig");
pub const udp = @import("udp.zig");
pub const udp_executor = @import("udp_executor.zig");

// Pull subsystem source-side `test "..."` blocks into the test runner.
// Mirrors the pattern in `src/io/root.zig` and `src/dht/root.zig`. Wired
// into `mod_tests` via `_ = tracker;` in `src/root.zig`'s test block.
//
// `executor.zig` is exercised via `tests/torrent_session_test.zig`;
// UDP executor also has source-side IO-contract tests below.
test {
    _ = announce;
    _ = scrape;
    _ = udp;
    _ = udp_executor;
}
