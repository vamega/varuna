pub const huge_page_cache = @import("huge_page_cache.zig");
pub const manifest = @import("manifest.zig");
pub const resume_state = @import("state_db.zig");
pub const sqlite3 = @import("sqlite3.zig");
pub const verify = @import("verify.zig");
pub const writer = @import("writer.zig");

// Wire source-side `test "..."` blocks into the test runner. Mirrors
// the pattern in `src/torrent/root.zig`, `src/crypto/root.zig`, and
// `src/io/root.zig`. The parent `src/root.zig` test block must also
// opt-in via `_ = storage;`.
test {
    _ = huge_page_cache;
    _ = manifest;
    _ = resume_state;
    _ = verify;
    _ = writer;
}
