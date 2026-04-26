const std = @import("std");
const blocks = @import("blocks.zig");
const layout = @import("layout.zig");
const metainfo = @import("metainfo.zig");
const manifest = @import("../storage/manifest.zig");

/// Per-torrent loaded session state.
///
/// Lifecycle of v1/hybrid piece hashes (`docs/piece-hash-lifecycle.md`):
///   - `loadForDownload`: parses pieces, copies into `pieces` heap buffer,
///     points `layout.piece_hashes` at it.
///   - `loadForSeeding`: skips pieces parsing entirely; `pieces == null`.
///   - During download, `zeroPieceHash(i)` clobbers the 20-byte hash for
///     verified piece `i` (Phase 1 piece-by-piece).
///   - When all pieces verify, `freePieces()` releases the heap buffer
///     and clears `layout.piece_hashes` (Phase 1 endgame).
///   - On operator-triggered recheck against a seeding-only session,
///     `loadPiecesForRecheck()` re-parses pieces from `torrent_bytes`.
pub const Session = struct {
    arena_state: ?std.heap.ArenaAllocator = null,
    torrent_bytes: []const u8,
    metainfo: metainfo.Metainfo,
    layout: layout.Layout,
    manifest: manifest.Manifest,
    block_size: u32 = blocks.default_block_size,

    /// Heap-owned mutable working copy of the v1 SHA-1 piece hash table.
    ///
    /// Separately allocated from the session arena so it can be freed mid-
    /// session without dropping the rest of the metadata. Always allocated
    /// via the same `gpa` passed to `Session.load*` and freed by
    /// `freePieces()` / `deinit()`.
    ///
    /// `null` means "no pieces in memory":
    ///   - never materialised (loadForSeeding), or
    ///   - already discarded (freePieces after full verification), or
    ///   - pure v2 torrent (uses Merkle roots; not applicable).
    pieces: ?[]u8 = null,

    /// gpa used to allocate `pieces`. Stored so `freePieces` /
    /// `loadPiecesForRecheck` / `zeroPieceHash` don't need an extra
    /// argument. Equals `Session.deinit`'s allocator argument by contract.
    pieces_allocator: std.mem.Allocator = undefined,

    /// Tracks which pieces have had their hash zeroed via `zeroPieceHash`.
    /// Lazily allocated on first call (cold path; only touched on piece
    /// completion). Lets `allHashesVerified()` answer the Phase 1 endgame
    /// question without iterating the hash bytes.
    verified_hashes: ?std.bit_set.DynamicBitSetUnmanaged = null,

    /// Standard load: parses metainfo (including the v1 `pieces` field for
    /// v1/hybrid), builds the layout, and dupes pieces into a session-
    /// owned heap buffer. Suitable for any torrent the session may
    /// actively download.
    pub fn load(
        allocator: std.mem.Allocator,
        torrent_bytes: []const u8,
        target_root: []const u8,
    ) !Session {
        return loadForDownload(allocator, torrent_bytes, target_root);
    }

    /// Phase-explicit alias for `Session.load`. Materialises the v1 piece
    /// hash table; required for any session that may verify pieces it
    /// downloads.
    pub fn loadForDownload(
        allocator: std.mem.Allocator,
        torrent_bytes: []const u8,
        target_root: []const u8,
    ) !Session {
        return loadInternal(allocator, torrent_bytes, target_root, .{ .seeding_only = false });
    }

    /// Phase 2 of the piece-hash lifecycle: load a session WITHOUT
    /// materialising the v1 piece hash table. Suitable only for torrents
    /// already 100% complete and verified (the seeder never consults
    /// piece hashes — peers verify with their own copy).
    ///
    /// Calling `layout.pieceHash(...)` on a seeding-only session returns
    /// `error.PiecesNotLoaded`. Operator-triggered recheck must call
    /// `loadPiecesForRecheck()` first.
    pub fn loadForSeeding(
        allocator: std.mem.Allocator,
        torrent_bytes: []const u8,
        target_root: []const u8,
    ) !Session {
        return loadInternal(allocator, torrent_bytes, target_root, .{ .seeding_only = true });
    }

    const LoadOptions = struct {
        seeding_only: bool,
    };

    fn loadInternal(
        allocator: std.mem.Allocator,
        torrent_bytes: []const u8,
        target_root: []const u8,
        opts: LoadOptions,
    ) !Session {
        var arena_state = std.heap.ArenaAllocator.init(allocator);
        errdefer arena_state.deinit();
        const arena = arena_state.allocator();

        const owned_torrent_bytes = try arena.dupe(u8, torrent_bytes);

        var parsed = if (opts.seeding_only)
            try metainfo.parseSeedingOnly(arena, owned_torrent_bytes)
        else
            try metainfo.parse(arena, owned_torrent_bytes);

        var built_layout = try layout.build(arena, &parsed);

        const built_manifest = try manifest.build(arena, target_root, parsed, built_layout);

        // For full-fat loads with v1/hybrid pieces, dupe the bencode-aliased
        // pieces slice into a separately-allocated heap buffer. This lets
        // freePieces() / zeroPieceHash() mutate or release the storage
        // without touching the arena.
        var pieces_buf: ?[]u8 = null;
        errdefer if (pieces_buf) |buf| allocator.free(buf);
        if (!opts.seeding_only and parsed.pieces.len > 0) {
            const buf = try allocator.alloc(u8, parsed.pieces.len);
            @memcpy(buf, parsed.pieces);
            pieces_buf = buf;
            // Repoint metainfo + layout at the heap-owned mutable copy so
            // subsequent reads see the freeable storage.
            parsed.pieces = buf;
            built_layout.piece_hashes = buf;
        }

        return .{
            .arena_state = arena_state,
            .torrent_bytes = owned_torrent_bytes,
            .metainfo = parsed,
            .layout = built_layout,
            .manifest = built_manifest,
            .pieces = pieces_buf,
            .pieces_allocator = allocator,
        };
    }

    pub fn deinit(self: Session, allocator: std.mem.Allocator) void {
        if (self.pieces) |buf| {
            self.pieces_allocator.free(buf);
        }
        if (self.verified_hashes) |vh| {
            var local = vh;
            local.deinit(self.pieces_allocator);
        }
        if (self.arena_state) |arena_state| {
            var arena = arena_state;
            arena.deinit();
        } else {
            manifest.freeManifest(allocator, self.manifest);
            layout.freeLayout(allocator, self.layout);
            metainfo.freeMetainfo(allocator, self.metainfo);
            allocator.free(self.torrent_bytes);
        }
    }

    pub fn geometry(self: *const Session) blocks.Geometry {
        return .{
            .layout = &self.layout,
            .block_size = self.block_size,
        };
    }

    pub fn fileCount(self: Session) usize {
        return self.manifest.files.len;
    }

    pub fn pieceCount(self: Session) u32 {
        return self.layout.piece_count;
    }

    pub fn totalSize(self: Session) u64 {
        return self.layout.total_size;
    }

    /// True if v1 piece hashes are currently in memory.
    pub fn hasPieceHashes(self: *const Session) bool {
        return self.pieces != null;
    }

    /// Phase 1 piece-by-piece: clobber the 20-byte SHA-1 for a verified
    /// piece. Idempotent; no-op when pieces is null (already freed) or
    /// when the layout has no v1 hashes (pure v2). Records the verified
    /// state in `verified_hashes` so callers can ask `allHashesVerified()`.
    ///
    /// Caller must hold any external invariants — typically called only
    /// after `PieceTracker.completePiece` returns true (first completion,
    /// disk write done) so smart-ban has already finished its per-piece
    /// records (it consumes them in `processHashResults` before disk
    /// writes are submitted).
    pub fn zeroPieceHash(self: *Session, piece_index: u32) void {
        if (piece_index >= self.layout.piece_count) return;
        // No-op for pure v2 (no flat hash table) and for sessions whose
        // pieces have already been freed.
        if (self.layout.version == .v2) return;
        if (self.pieces == null) return;

        const pieces = self.pieces.?;
        const start = @as(usize, piece_index) * 20;
        if (start + 20 > pieces.len) return;
        @memset(pieces[start .. start + 20], 0);

        // Lazily allocate the verified bitset on first call.
        if (self.verified_hashes == null) {
            const bs = std.bit_set.DynamicBitSetUnmanaged.initEmpty(
                self.pieces_allocator,
                self.layout.piece_count,
            ) catch return;
            self.verified_hashes = bs;
        }
        if (self.verified_hashes) |*vh| {
            vh.set(piece_index);
        }
    }

    /// True when every piece's hash has been zeroed via `zeroPieceHash`.
    /// Used to drive Phase 1's endgame `freePieces` from the EL.
    pub fn allHashesVerified(self: *const Session) bool {
        // No pieces means already freed / never materialised — treat as
        // "yes" so callers don't double-free or oscillate.
        if (self.pieces == null) return true;
        const vh = self.verified_hashes orelse return false;
        return vh.count() == self.layout.piece_count;
    }

    /// Phase 1 endgame: discard the v1 piece hash table once all pieces
    /// are verified. After this, `layout.pieceHash` returns
    /// `error.PiecesNotLoaded`. Idempotent.
    pub fn freePieces(self: *Session) void {
        if (self.pieces) |buf| {
            self.pieces_allocator.free(buf);
            self.pieces = null;
        }
        self.layout.piece_hashes = null;
        // metainfo.pieces still aliases the freed buffer; clear so any
        // stray reader can't UAF. The arena's torrent_bytes is unaffected.
        self.metainfo.pieces = "";
        if (self.verified_hashes) |*vh| {
            vh.deinit(self.pieces_allocator);
            self.verified_hashes = null;
        }
    }

    /// Phase 3: re-materialise the v1 piece hash table from
    /// `torrent_bytes` for an operator-triggered recheck. Safe to call
    /// when pieces is already loaded (no-op). Returns
    /// `error.UnsupportedForV2` for pure v2 torrents.
    pub fn loadPiecesForRecheck(self: *Session) !void {
        if (self.pieces != null) return; // already loaded
        if (self.layout.version == .v2) return error.UnsupportedForV2;

        // Re-parse to get the bencode-aliased pieces slice. We don't keep
        // the rest of the parsed metainfo — only the pieces bytes are
        // copied out to a heap buffer. The temporary parse uses an arena
        // that we tear down immediately.
        var tmp_arena = std.heap.ArenaAllocator.init(self.pieces_allocator);
        defer tmp_arena.deinit();

        const reparsed = try metainfo.parse(tmp_arena.allocator(), self.torrent_bytes);
        if (reparsed.pieces.len == 0) return error.PiecesNotLoaded;

        const buf = try self.pieces_allocator.alloc(u8, reparsed.pieces.len);
        errdefer self.pieces_allocator.free(buf);
        @memcpy(buf, reparsed.pieces);

        self.pieces = buf;
        self.metainfo.pieces = buf;
        self.layout.piece_hashes = buf;
    }
};

test "load single file torrent session" {
    const input =
        "d8:announce14:http://tracker" ++ "4:infod6:lengthi10e4:name8:test.bin12:piece lengthi4e" ++ "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

    var loaded = try Session.load(std.testing.allocator, input, "/srv/torrents");
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), loaded.fileCount());
    try std.testing.expectEqual(@as(u32, 3), loaded.pieceCount());
    try std.testing.expectEqual(@as(u64, 10), loaded.totalSize());
    try std.testing.expectEqualStrings("/srv/torrents/test.bin", loaded.manifest.files[0].full_path);

    const geometry = loaded.geometry();
    try std.testing.expectEqual(@as(u32, 1), try geometry.blockCount(2));
    try std.testing.expectEqual(@as(u32, 2), try geometry.blockSize(2, 0));
}

test "load multi file torrent session" {
    const input =
        "d4:infod5:filesl" ++ "d6:lengthi3e4:pathl5:alphaee" ++ "d6:lengthi7e4:pathl4:beta5:gammaeee" ++ "4:name4:root" ++ "12:piece lengthi4e" ++ "6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

    var loaded = try Session.load(std.testing.allocator, input, "/srv/torrents");
    defer loaded.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), loaded.fileCount());
    try std.testing.expectEqualStrings("root/alpha", loaded.manifest.files[0].relative_path);
    try std.testing.expectEqualStrings("/srv/torrents/root/beta/gamma", loaded.manifest.files[1].full_path);

    var spans: [2]layout.Layout.Span = undefined;
    const mapped = try loaded.layout.mapPiece(0, spans[0..]);
    try std.testing.expectEqual(@as(usize, 2), mapped.len);
    try std.testing.expectEqual(@as(u32, 3), mapped[0].length);
    try std.testing.expectEqual(@as(u32, 1), mapped[1].length);
}

test "session owns torrent bytes after load" {
    const torrent_bytes = try std.testing.allocator.dupe(
        u8,
        "d4:infod6:lengthi4e4:name8:test.bin12:piece lengthi4e6:pieces20:abcdefghijklmnopqrstee",
    );
    defer std.testing.allocator.free(torrent_bytes);

    var loaded = try Session.load(std.testing.allocator, torrent_bytes, "/srv/torrents");
    defer loaded.deinit(std.testing.allocator);

    @memset(torrent_bytes, 'x');
    try std.testing.expectEqualStrings("test.bin", loaded.metainfo.name);
}

// ── Piece hash lifecycle tests ─────────────────────────────

test "loadForDownload materialises pieces in heap" {
    const input =
        "d4:infod6:lengthi10e4:name8:test.bin12:piece lengthi4e6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

    var sess = try Session.loadForDownload(std.testing.allocator, input, "/srv/torrents");
    defer sess.deinit(std.testing.allocator);

    try std.testing.expect(sess.hasPieceHashes());
    try std.testing.expect(sess.pieces != null);
    try std.testing.expect(sess.layout.piece_hashes != null);

    // Hash for piece 0 reads back correctly.
    const h0 = try sess.layout.pieceHash(0);
    try std.testing.expectEqualStrings("abcdefghijklmnopqrst", h0);
}

test "loadForSeeding skips pieces parsing entirely" {
    const input =
        "d4:infod6:lengthi10e4:name8:test.bin12:piece lengthi4e6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

    var sess = try Session.loadForSeeding(std.testing.allocator, input, "/srv/torrents");
    defer sess.deinit(std.testing.allocator);

    // Phase 2 invariant: no pieces in memory.
    try std.testing.expect(!sess.hasPieceHashes());
    try std.testing.expect(sess.pieces == null);
    try std.testing.expect(sess.layout.piece_hashes == null);

    // Layout still answers piece_count from file sizes.
    try std.testing.expectEqual(@as(u32, 3), sess.pieceCount());
    try std.testing.expectEqual(@as(u64, 10), sess.totalSize());

    // pieceHash is unavailable until loadPiecesForRecheck.
    try std.testing.expectError(error.PiecesNotLoaded, sess.layout.pieceHash(0));
}

test "freePieces releases the slice and clears layout pointer" {
    const input =
        "d4:infod6:lengthi10e4:name8:test.bin12:piece lengthi4e6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

    var sess = try Session.loadForDownload(std.testing.allocator, input, "/srv/torrents");
    defer sess.deinit(std.testing.allocator);

    try std.testing.expect(sess.hasPieceHashes());

    sess.freePieces();
    try std.testing.expect(!sess.hasPieceHashes());
    try std.testing.expect(sess.layout.piece_hashes == null);
    try std.testing.expectError(error.PiecesNotLoaded, sess.layout.pieceHash(0));

    // Idempotent.
    sess.freePieces();
    try std.testing.expect(!sess.hasPieceHashes());
}

test "loadPiecesForRecheck restores the hash table from torrent_bytes" {
    const input =
        "d4:infod6:lengthi10e4:name8:test.bin12:piece lengthi4e6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

    var sess = try Session.loadForSeeding(std.testing.allocator, input, "/srv/torrents");
    defer sess.deinit(std.testing.allocator);

    try std.testing.expect(!sess.hasPieceHashes());
    try sess.loadPiecesForRecheck();
    try std.testing.expect(sess.hasPieceHashes());

    const h0 = try sess.layout.pieceHash(0);
    try std.testing.expectEqualStrings("abcdefghijklmnopqrst", h0);

    // Re-call is a no-op (already loaded).
    try sess.loadPiecesForRecheck();
    try std.testing.expect(sess.hasPieceHashes());
}

test "zeroPieceHash clobbers per-piece bytes and tracks verified state" {
    const input =
        "d4:infod6:lengthi10e4:name8:test.bin12:piece lengthi4e6:pieces60:abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ12345678ee";

    var sess = try Session.loadForDownload(std.testing.allocator, input, "/srv/torrents");
    defer sess.deinit(std.testing.allocator);

    sess.zeroPieceHash(1);
    const after = try sess.layout.pieceHash(1);
    try std.testing.expectEqualSlices(u8, &([_]u8{0} ** 20), after);
    // Other piece hashes are untouched.
    try std.testing.expectEqualStrings("abcdefghijklmnopqrst", try sess.layout.pieceHash(0));

    try std.testing.expect(!sess.allHashesVerified());

    sess.zeroPieceHash(0);
    sess.zeroPieceHash(2);
    try std.testing.expect(sess.allHashesVerified());
}

test "pure v2 sessions have no piece hashes regardless of load mode" {
    const pr = [_]u8{0xAA} ** 32;
    const input = "d4:infod9:file treed8:test.bind0:d6:lengthi5e11:pieces root32:" ++ pr ++ "eee4:name4:test12:piece lengthi16384eee";

    var sess = try Session.loadForDownload(std.testing.allocator, input, "/srv/torrents");
    defer sess.deinit(std.testing.allocator);

    try std.testing.expect(sess.layout.version == .v2);
    try std.testing.expect(sess.pieces == null);
    try std.testing.expect(sess.layout.piece_hashes == null);

    // zeroPieceHash is a safe no-op on v2.
    sess.zeroPieceHash(0);
    // freePieces is a safe no-op on v2.
    sess.freePieces();
    // loadPiecesForRecheck rejects v2.
    try std.testing.expectError(error.UnsupportedForV2, sess.loadPiecesForRecheck());
}
