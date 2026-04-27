pub const app = @import("app.zig");
pub const bitfield = @import("bitfield.zig");
pub const config = @import("config.zig");
pub const crypto = @import("crypto/root.zig");
pub const daemon = @import("daemon/root.zig");
pub const dht = @import("dht/root.zig");
pub const io = @import("io/root.zig");
pub const rpc = @import("rpc/root.zig");
pub const net = @import("net/root.zig");
pub const runtime = @import("runtime/root.zig");
pub const sim = @import("sim/root.zig");
pub const storage = @import("storage/root.zig");
pub const tracker = @import("tracker/root.zig");
pub const torrent = @import("torrent/root.zig");

// Pull subsystem source-side `test "..."` blocks into the test runner.
// `pub const x = @import(...)` does NOT propagate test discovery in
// Zig 0.15.2 — only files reached from a TEST CONTEXT import
// participate. Each `_ = subsystem;` here forces that subsystem's
// `test { _ = ... }` chain to fire.
//
// Subsystems are added one at a time as their source-side tests are
// verified to compile and pass against current Zig std + production
// logic. Bit-rotted subsystems stay out and are tracked in Task #9.
test {
    _ = app;
    _ = bitfield;
    _ = config;
    _ = crypto;
    _ = dht;
    _ = io;
    _ = net;
    _ = rpc;
    _ = runtime;
    _ = sim;
    _ = storage;
    _ = torrent;
    _ = tracker;
}
