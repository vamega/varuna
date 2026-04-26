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
// Subsystems left out:
//  - `app`, `config`: source-side tests reference Zig std APIs that
//    drifted (Io.GenericWriter.interface, fs.Dir.close *Dir vs *const).
//    Test fixes are in this commit, but pulling them in via `_ = app;`
//    triggers comptime-eval errors elsewhere in the io_interface
//    parity check (likely a transitive-import ordering issue Zig 0.15
//    handles when these modules aren't reached from a test context).
//    Tracked for follow-up; the per-file test fixes are in place so
//    a future maintainer can re-enable when the comptime issue resolves.
test {
    _ = bitfield;
    _ = crypto;
    _ = torrent;
}
