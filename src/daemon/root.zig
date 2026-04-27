pub const categories = @import("categories.zig");
pub const queue_manager = @import("queue_manager.zig");
pub const session_manager = @import("session_manager.zig");
pub const systemd = @import("systemd.zig");
pub const tracker_executor = @import("tracker_executor.zig");
pub const torrent_session = @import("torrent_session.zig");
pub const udp_tracker_executor = @import("udp_tracker_executor.zig");

// Pull subsystem source-side `test "..."` blocks into the test runner.
// Mirrors the pattern in `src/io/root.zig` and `src/dht/root.zig`. Wired
// into `mod_tests` via `_ = daemon;` in `src/root.zig`'s test block.
//
// `udp_tracker_executor.zig` and `tracker_executor.zig` have no inline
// tests today; they're exercised via `tests/udp_tracker_test.zig` and
// `tests/torrent_session_test.zig`.
test {
    _ = categories;
    _ = queue_manager;
    _ = session_manager;
    _ = systemd;
    _ = torrent_session;
}
