pub const auth = @import("auth.zig");
pub const compat = @import("compat.zig");
pub const handlers = @import("handlers.zig");
pub const json = @import("json.zig");
pub const multipart = @import("multipart.zig");
pub const scratch = @import("scratch.zig");
pub const server = @import("server.zig");
pub const sync = @import("sync.zig");

// Pull subsystem source-side `test "..."` blocks into the test runner.
// Mirrors the pattern in `src/io/root.zig` and `src/dht/root.zig`. Wired
// into `mod_tests` via `_ = rpc;` in `src/root.zig`'s test block.
test {
    _ = auth;
    _ = compat;
    _ = handlers;
    _ = json;
    _ = multipart;
    _ = scratch;
    _ = server;
    _ = sync;
}
