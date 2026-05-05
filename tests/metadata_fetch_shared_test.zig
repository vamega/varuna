//! Stage 4 zero-alloc — ut_metadata fetch buffer.
//!
//! Layered tests for the EventLoop's pre-allocated metadata-assembly
//! buffer. BEP 9 caps metadata at 16 MiB; varuna's own cap
//! (`ut_metadata.max_metadata_size`, currently 10 MiB) is stricter.
//! The EventLoop allocates one worst-case-sized buffer on first
//! `startMetadataFetch` and reuses it for every subsequent fetch
//! (the existing `metadata_fetch != null` invariant on EventLoop
//! serialises fetches across torrents — at most one in flight at a
//! time).
//!
//! ## Tests in this file
//!
//! * **Algorithm** — `MetadataAssembler.initShared`: claim/release
//!   semantics, capacity rejection, multi-fetch reuse.
//! * **Integration** — `AsyncMetadataFetch.create` with shared
//!   buffer ownership; verify the assembler is on the shared path.
//! * **Re-use across fetches** — run two metadata fetches against
//!   distinct hashes and sizes through the shared assembler with
//!   `resetForNewFetch`; assert no re-allocation.
//! * **Capacity bounds** — sizes that would have fit the legacy
//!   path but exceed a smaller shared buffer must be rejected.

const std = @import("std");
const testing = std.testing;

const varuna = @import("varuna");
const ut_metadata = varuna.net.ut_metadata;
const Sha1 = varuna.crypto.Sha1;

// ── Algorithm: bare MetadataAssembler invariants under shared storage ─

test "shared assembler: small payload uses prefix of buffer" {
    var buffer: [ut_metadata.max_metadata_size]u8 = undefined;
    var received: [ut_metadata.max_piece_count]bool = undefined;

    const data = "d4:name8:test.bin6:lengthi5e12:piece lengthi16384e6:pieces20:aabbccddeeff00112233e";
    var hash: [20]u8 = undefined;
    Sha1.hash(data, &hash, .{});

    var assembler = ut_metadata.MetadataAssembler.initShared(hash, buffer[0..], received[0..]);
    defer assembler.deinit();

    try assembler.setSize(@intCast(data.len));
    try testing.expectEqual(@as(u32, 1), assembler.totalPieces());

    const complete = try assembler.addPiece(0, data);
    try testing.expect(complete);

    const verified = try assembler.verify();
    try testing.expectEqualStrings(data, verified);
}

test "shared assembler: deinit does not free caller-owned slices" {
    var buffer: [ut_metadata.max_metadata_size]u8 = undefined;
    var received: [ut_metadata.max_piece_count]bool = undefined;

    var a = ut_metadata.MetadataAssembler.initShared(@as([20]u8, @splat(0)), buffer[0..], received[0..]);
    a.deinit(); // must NOT free buffer[]/received[]

    // If deinit had freed, reusing the same slices would tickle
    // a use-after-free. The test running cleanly under the GPA
    // leak/UAF detector is the assertion.
    var b = ut_metadata.MetadataAssembler.initShared(@as([20]u8, @splat(0)), buffer[0..], received[0..]);
    defer b.deinit();
    try testing.expect(!b.owns_storage);
}

test "shared assembler: rejects size > shared capacity" {
    const small_cap: u32 = 4096;
    const piece_cap: u32 = 1;
    var buffer: [small_cap]u8 = undefined;
    var received: [piece_cap]bool = undefined;

    var assembler = ut_metadata.MetadataAssembler.initShared(@as([20]u8, @splat(0)), buffer[0..], received[0..]);
    defer assembler.deinit();

    try testing.expectError(
        error.InvalidMetadataSize,
        assembler.setSize(small_cap + 1),
    );
}

test "shared assembler: rejects piece count > shared received capacity" {
    // Buffer is huge but `received` is sized for a single piece —
    // any size that needs >1 pieces must be rejected.
    var buffer: [ut_metadata.max_metadata_size]u8 = undefined;
    var received: [1]bool = undefined;

    var assembler = ut_metadata.MetadataAssembler.initShared(@as([20]u8, @splat(0)), buffer[0..], received[0..]);
    defer assembler.deinit();

    // metadata_piece_size + 1 needs 2 pieces; piece_cap is 1 → reject.
    try testing.expectError(
        error.InvalidMetadataSize,
        assembler.setSize(ut_metadata.metadata_piece_size + 1),
    );
}

test "shared assembler: resetForNewFetch cycles between fetches with no allocation" {
    var buffer: [ut_metadata.max_metadata_size]u8 = undefined;
    var received: [ut_metadata.max_piece_count]bool = undefined;

    // First fetch: small payload, hash A.
    const data1 = "d4:name4:teste";
    var hash1: [20]u8 = undefined;
    Sha1.hash(data1, &hash1, .{});

    var assembler = ut_metadata.MetadataAssembler.initShared(hash1, buffer[0..], received[0..]);
    defer assembler.deinit();

    try assembler.setSize(@intCast(data1.len));
    _ = try assembler.addPiece(0, data1);
    try testing.expect(assembler.isComplete());
    _ = try assembler.verify();

    // Second fetch: larger payload (multi-piece), different hash.
    const size2: u32 = ut_metadata.metadata_piece_size + 100;
    const data2 = try testing.allocator.alloc(u8, size2);
    defer testing.allocator.free(data2);
    @memset(data2, 'q');

    var hash2: [20]u8 = undefined;
    Sha1.hash(data2, &hash2, .{});

    assembler.resetForNewFetch(hash2);
    try testing.expectEqual(@as(u32, 0), assembler.total_size);
    try testing.expectEqual(@as(u32, 0), assembler.pieces_received);
    try testing.expect(!assembler.isComplete());

    try assembler.setSize(size2);
    try testing.expectEqual(@as(u32, 2), assembler.totalPieces());
    _ = try assembler.addPiece(0, data2[0..ut_metadata.metadata_piece_size]);
    _ = try assembler.addPiece(1, data2[ut_metadata.metadata_piece_size..size2]);
    try testing.expect(assembler.isComplete());
    _ = try assembler.verify();
}

test "shared assembler: prefix-only iteration in nextNeeded under poisoned suffix" {
    var buffer: [ut_metadata.max_metadata_size]u8 = undefined;
    var received: [ut_metadata.max_piece_count]bool = undefined;

    // Poison the entire `received` array with `true` to detect any
    // iteration that escapes the active prefix.
    @memset(received[0..], true);

    const size: u32 = ut_metadata.metadata_piece_size + 100;
    const data = try testing.allocator.alloc(u8, size);
    defer testing.allocator.free(data);
    @memset(data, 'x');

    var hash: [20]u8 = undefined;
    Sha1.hash(data, &hash, .{});

    var assembler = ut_metadata.MetadataAssembler.initShared(hash, buffer[0..], received[0..]);
    defer assembler.deinit();

    try assembler.setSize(size);
    // setSize must reset the active prefix to all-false; nextNeeded
    // therefore picks 0. If iteration escapes the prefix, the
    // poisoned bytes after [0..2] would be observed as `true` and
    // nextNeeded would return null even though pieces 0 and 1 are
    // unreceived.
    try testing.expectEqual(@as(u32, 0), assembler.nextNeeded().?);

    _ = try assembler.addPiece(0, data[0..ut_metadata.metadata_piece_size]);
    try testing.expectEqual(@as(u32, 1), assembler.nextNeeded().?);

    _ = try assembler.addPiece(1, data[ut_metadata.metadata_piece_size..size]);
    try testing.expect(assembler.nextNeeded() == null);
    try testing.expect(assembler.isComplete());
    _ = try assembler.verify();
}

test "max_piece_count covers BEP-9-cap-class metadata" {
    const expected = (ut_metadata.max_metadata_size +
        ut_metadata.metadata_piece_size - 1) /
        ut_metadata.metadata_piece_size;
    try testing.expectEqual(expected, ut_metadata.max_piece_count);
    try testing.expect(ut_metadata.max_piece_count > 0);
    // Sanity: the `received` slot is small enough not to be a worry.
    try testing.expect(@sizeOf(bool) * ut_metadata.max_piece_count < 4096);
}

// ── Integration: AsyncMetadataFetch with shared buffers ─────────

test "AsyncMetadataFetch with shared buffers: assembler routes through shared path" {
    const metadata_handler = varuna.io.metadata_handler;

    var io = try varuna.io.backend.initWithCapacity(testing.allocator, 4);
    defer io.deinit();

    const buf = try testing.allocator.alloc(u8, ut_metadata.max_metadata_size);
    defer testing.allocator.free(buf);
    const recv = try testing.allocator.alloc(bool, ut_metadata.max_piece_count);
    defer testing.allocator.free(recv);

    const peers = [_]std.net.Address{
        std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881),
        std.net.Address.initIp4(.{ 127, 0, 0, 2 }, 6882),
    };
    const mf = try metadata_handler.AsyncMetadataFetch.create(
        testing.allocator,
        &io,
        @as([20]u8, @splat(0xAA)),
        @as([20]u8, @splat(0xBB)),
        6881,
        false,
        &peers,
        null,
        null,
        buf,
        recv,
    );
    defer mf.destroy();

    try testing.expect(!mf.assembler.owns_storage);
    try testing.expectEqual(@as(u32, 2), mf.peer_count);
}

test "AsyncMetadataFetch without shared buffers: assembler owns storage" {
    const metadata_handler = varuna.io.metadata_handler;

    var io = try varuna.io.backend.initWithCapacity(testing.allocator, 4);
    defer io.deinit();

    const peers = [_]std.net.Address{};
    const mf = try metadata_handler.AsyncMetadataFetch.create(
        testing.allocator,
        &io,
        @as([20]u8, @splat(0xAA)),
        @as([20]u8, @splat(0xBB)),
        6881,
        false,
        &peers,
        null,
        null,
        null,
        null,
    );
    defer mf.destroy();

    // Owned-storage path: legacy lazy-alloc fallback for tests.
    try testing.expect(mf.assembler.owns_storage);
}
