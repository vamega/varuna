pub const categories = @import("categories.zig");
pub const queue_manager = @import("queue_manager.zig");
pub const session_manager = @import("session_manager.zig");
pub const systemd = @import("systemd.zig");
pub const torrent_session = @import("torrent_session.zig");

// Pull subsystem source-side `test "..."` blocks into the test runner.
// Mirrors the pattern in `src/io/root.zig` and `src/dht/root.zig`. Wired
// into `mod_tests` via `_ = daemon;` in `src/root.zig`'s test block.
test {
    _ = categories;
    _ = queue_manager;
    _ = session_manager;
    _ = systemd;
    _ = torrent_session;
}
