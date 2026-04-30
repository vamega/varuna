pub const bencode = @import("bencode.zig");
pub const bencode_encode = @import("bencode_encode.zig");
pub const blocks = @import("blocks.zig");
pub const create = @import("create.zig");
pub const file_priority = @import("file_priority.zig");
pub const file_tree = @import("file_tree.zig");
pub const info_hash = @import("info_hash.zig");
pub const layout = @import("layout.zig");
pub const leaf_hashes = @import("leaf_hashes.zig");
pub const magnet = @import("magnet.zig");
pub const merkle = @import("merkle.zig");
pub const merkle_cache = @import("merkle_cache.zig");
pub const metainfo = @import("metainfo.zig");
pub const peer_id = @import("peer_id.zig");
pub const piece_tracker = @import("piece_tracker.zig");
pub const session = @import("session.zig");

// Pull subsystem source-side `test "..."` blocks into the test runner.
// `pub const x = @import(...)` does NOT propagate test discovery in
// Zig 0.15.2 — only files reached from a TEST CONTEXT import
// participate. (Mirrors `src/crypto/root.zig`'s pattern; required
// alongside `test { _ = torrent; }` in `src/root.zig` to actually
// reach test-context — see Task #6 audit + Task #9 cleanup.)
test {
    _ = bencode;
    _ = bencode_encode;
    _ = blocks;
    _ = create;
    _ = file_priority;
    _ = file_tree;
    _ = info_hash;
    _ = layout;
    _ = leaf_hashes;
    _ = magnet;
    _ = merkle;
    _ = merkle_cache;
    _ = metainfo;
    _ = peer_id;
    _ = piece_tracker;
    _ = session;
}
