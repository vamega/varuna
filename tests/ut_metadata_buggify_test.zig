//! BUGGIFY/fuzz coverage for the BEP 9 ut_metadata extension parser
//! and the BEP 29 uTP SACK extension decoder.
//!
//! These two parsers sit on attacker-controlled wire paths:
//!
//! * **`src/net/ut_metadata.zig`** is invoked from
//!   `src/io/protocol.zig:handleUtMetadata` for every BEP 10 extension
//!   message a connected peer sends. Pre-hardening, the inline
//!   `findDictEnd` -> `skipByteString` helpers used the unsafe
//!   `idx + length` form; an adversarial peer could send a bencoded
//!   key with declared length `maxInt(u64)` and panic the daemon with
//!   "integer overflow" in safe builds. The same parser also
//!   recursed without a depth bound, so a 1 MiB payload of `lllll...`
//!   could blow the native call stack. Every connected peer could
//!   trigger either, so this is a Round-1-class ut_metadata BT-PIECE-
//!   shape vulnerability.
//!
//! * **`src/net/utp.zig:SelectiveAck.decode`** is reachable any time
//!   a uTP peer sets `extension == selective_ack`. Pre-hardening, a
//!   peer-controlled `len` of 36/40/.../252 (multiple of 4, > 32)
//!   bypassed the BEP 29 length check and panicked the `@memcpy` into
//!   the 32-byte `bitmask` array. The function isn't yet wired into
//!   the production hot path (only the fuzz harness invokes it today),
//!   but it's still a defense-in-depth fix and a regression guard for
//!   the day SACK parsing lands.
//!
//! Coverage:
//!
//! * **Layer 1 — random-byte fuzz of `ut_metadata.decode`.** 32 seeds ×
//!   1024 random byte buffers (length 0..2048). Asserts: never panics,
//!   never leaks. Allowed outcomes: any error from `DecodeError` or a
//!   valid `MetadataMessage`.
//! * **Layer 1 — adversarial corpus.** Hand-crafted inputs covering
//!   the regression shapes (length-prefix overflow, depth flood,
//!   negative integers, truncated messages, type confusion).
//! * **Layer 1 — round-trip pinning.** Encode/decode pairs survive
//!   the rewrite.
//! * **Layer 1 — uTP SACK adversarial decode.** Every `len` in [0..255]
//!   probed against a synthetic buffer. Asserts: never panics,
//!   accepted only for `len ∈ {4, 8, 12, …, 32}`, rejected otherwise.

const std = @import("std");
const testing = std.testing;
const varuna = @import("varuna");

const ut_metadata = varuna.net.ut_metadata;
const utp = varuna.net.utp;

const fuzz_seeds = [_]u64{
    0x00000000, 0x00000001, 0xffffffff, 0xfffffffe, 0xdeadbeef,
    0xcafebabe, 0x12345678, 0x87654321, 0x11111111, 0x22222222,
    0x33333333, 0x44444444, 0x55555555, 0x66666666, 0x77777777,
    0x88888888, 0x99999999, 0xaaaaaaaa, 0xbbbbbbbb, 0xcccccccc,
    0xdddddddd, 0xeeeeeeee, 0xa1b2c3d4, 0xe5f60708, 0x1a2b3c4d,
    0x5e6f7080, 0xdeaddead, 0xfedcba98, 0x76543210, 0x089abcde,
    0xf01234ab, 0x55aa55aa,
};

// ── Layer 1: ut_metadata.decode random-byte fuzz ────────────────

fn ut_metadata_fuzz_once(prng: *std.Random.DefaultPrng, max_len: usize) void {
    const rand = prng.random();
    const len = rand.uintLessThan(usize, max_len + 1);
    var buf: [2048]u8 = undefined;
    const data = buf[0..len];
    rand.bytes(data);

    // The decode function must not panic on any input. Catch every
    // possible error and ignore it.
    _ = ut_metadata.decode(testing.allocator, data) catch return;
}

test "BUGGIFY: ut_metadata.decode survives 32k random byte buffers" {
    for (fuzz_seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        for (0..1024) |_| {
            ut_metadata_fuzz_once(&prng, 2048);
        }
    }
}

// ── Layer 1: ut_metadata.decode adversarial corpus ──────────────

test "ut_metadata.decode rejects length-prefix overflow at maxInt(u64)" {
    // The killer input. Pre-hardening, this panicked with "integer
    // overflow" inside `skipByteString` because of `idx + length`
    // where `length = maxInt(u64)`. Post-hardening, the digit-cap on
    // `parseBytes` rejects the 20-digit prefix as InvalidMessage.
    const adversarial = "d18446744073709551615:ABCD";
    try testing.expectError(
        error.InvalidMessage,
        ut_metadata.decode(testing.allocator, adversarial),
    );
}

test "ut_metadata.decode rejects 21-digit length prefix" {
    // Past-the-cap digit run. Pre-hardening, parseUnsigned would
    // error.Overflow → null → InvalidMessage anyway, but post-hardening
    // we cap the digit scan itself so we don't even attempt to parse.
    const adversarial = "d999999999999999999999:KEY3:val";
    try testing.expectError(
        error.InvalidMessage,
        ut_metadata.decode(testing.allocator, adversarial),
    );
}

test "ut_metadata.decode rejects deep-recursion attack" {
    // 1024 bytes of 'l' is far past max_depth (64). Pre-hardening,
    // `skipBencodeValue` would recurse 1024 frames; with a 1 MiB
    // payload ceiling, a malicious peer could trivially blow the
    // native call stack.
    var deep: [1024]u8 = undefined;
    @memset(&deep, 'l');
    try testing.expectError(
        error.InvalidMessage,
        ut_metadata.decode(testing.allocator, &deep),
    );
}

test "ut_metadata.decode rejects nested-dict depth attack" {
    // Same shape with dicts. Each `d` opens a new container so
    // skipValue must recurse. 65 deep dicts breaks the bound.
    var deep: [65]u8 = undefined;
    @memset(&deep, 'd');
    try testing.expectError(
        error.InvalidMessage,
        ut_metadata.decode(testing.allocator, &deep),
    );
}

test "ut_metadata.decode rejects truncated input" {
    // Length prefix claims more bytes than remain after the colon.
    const truncated = "d10:abcdefe"; // claims 10 bytes, has 5 left
    try testing.expectError(
        error.InvalidMessage,
        ut_metadata.decode(testing.allocator, truncated),
    );
}

test "ut_metadata.decode rejects negative msg_type" {
    const bad = "d8:msg_typei-1e5:piecei0ee";
    try testing.expectError(
        error.InvalidMsgType,
        ut_metadata.decode(testing.allocator, bad),
    );
}

test "ut_metadata.decode rejects negative piece" {
    const bad = "d8:msg_typei0e5:piecei-7ee";
    try testing.expectError(
        error.InvalidMessage,
        ut_metadata.decode(testing.allocator, bad),
    );
}

test "ut_metadata.decode rejects out-of-range piece (> u32)" {
    // i64 holds values larger than u32's max; we must reject them.
    const bad = "d8:msg_typei0e5:piecei9999999999ee";
    try testing.expectError(
        error.InvalidMessage,
        ut_metadata.decode(testing.allocator, bad),
    );
}

test "ut_metadata.decode rejects non-dict top-level" {
    try testing.expectError(
        error.InvalidMessage,
        ut_metadata.decode(testing.allocator, "li1ei2ee"),
    );
    try testing.expectError(
        error.InvalidMessage,
        ut_metadata.decode(testing.allocator, "i42e"),
    );
    try testing.expectError(
        error.InvalidMessage,
        ut_metadata.decode(testing.allocator, "5:hello"),
    );
}

test "ut_metadata.decode handles request round-trip" {
    const payload = try ut_metadata.encodeRequest(testing.allocator, 7);
    defer testing.allocator.free(payload);
    const msg = try ut_metadata.decode(testing.allocator, payload);
    try testing.expectEqual(ut_metadata.MsgType.request, msg.msg_type);
    try testing.expectEqual(@as(u32, 7), msg.piece);
}

test "ut_metadata.decode handles reject round-trip" {
    const payload = try ut_metadata.encodeReject(testing.allocator, 3);
    defer testing.allocator.free(payload);
    const msg = try ut_metadata.decode(testing.allocator, payload);
    try testing.expectEqual(ut_metadata.MsgType.reject, msg.msg_type);
    try testing.expectEqual(@as(u32, 3), msg.piece);
}

test "ut_metadata.decode data message records correct data_offset" {
    // Critical for the BEP 9 data path: piece bytes start at
    // `payload[2 + msg.data_offset..]` in protocol.zig. If
    // `data_offset` were wrong, we'd either pass garbage to the
    // assembler or panic on slice indexing.
    const header = try ut_metadata.encodeData(testing.allocator, 1, 200);
    defer testing.allocator.free(header);

    const piece_data = "PIECE_DATA_HERE_EXACTLY_16_BYTES_OR_SO";
    var full: [256]u8 = undefined;
    @memcpy(full[0..header.len], header);
    @memcpy(full[header.len..][0..piece_data.len], piece_data);

    const total = header.len + piece_data.len;
    const msg = try ut_metadata.decode(testing.allocator, full[0..total]);
    try testing.expectEqual(ut_metadata.MsgType.data, msg.msg_type);
    try testing.expectEqual(@as(u32, 1), msg.piece);
    try testing.expectEqual(@as(u32, 200), msg.total_size);
    try testing.expectEqualStrings(piece_data, full[msg.data_offset..total]);
}

// ── Layer 1: uTP SelectiveAck adversarial decode ──────────────

test "BUGGIFY: SelectiveAck.decode rejects every out-of-cap len" {
    // Probe every `len` byte in [0, 255]. Synthetic buffer has 257
    // bytes (more than any valid declared len) so the size check
    // never fails before the cap check runs. Accepted shapes are
    // exactly the BEP 29 multiples of 4 in [4, 32].
    var buf: [257]u8 = undefined;
    @memset(&buf, 0xAA);
    buf[0] = 0; // next_extension = none

    var len: u16 = 0;
    while (len <= 255) : (len += 1) {
        buf[1] = @intCast(len);
        const result = utp.SelectiveAck.decode(&buf);
        const should_accept = (len > 0) and (len <= 32) and (len % 4 == 0);
        if (should_accept) {
            try testing.expect(result != null);
            try testing.expectEqual(@as(u8, @intCast(len)), result.?.len);
        } else {
            try testing.expect(result == null);
        }
    }
}

test "SelectiveAck.decode rejects out-of-cap len without truncation panic" {
    // Pre-hardening killer input: len=36 is a multiple of 4, the
    // buffer-size check `buf.len < 2 + 36` passes, but then
    // `@memcpy(sack.bitmask[0..36], ...)` panics because the bitmask
    // is only 32 bytes. Post-hardening, the cap-check rejects first.
    var buf: [40]u8 = undefined;
    @memset(&buf, 0);
    buf[0] = 0;
    buf[1] = 36;
    try testing.expect(utp.SelectiveAck.decode(&buf) == null);

    // 252 = max u8 multiple of 4. Same shape.
    var big: [255]u8 = undefined;
    @memset(&big, 0);
    big[0] = 0;
    big[1] = 252;
    try testing.expect(utp.SelectiveAck.decode(&big) == null);
}

test "SelectiveAck.decode roundtrip survives the cap rewrite" {
    // Round-trip every legal `len` to make sure we didn't break
    // happy-path SACK encoding.
    var buf: [40]u8 = undefined;
    inline for ([_]u8{ 4, 8, 12, 16, 20, 24, 28, 32 }) |valid_len| {
        var sack = utp.SelectiveAck{
            .next_extension = .none,
            .len = valid_len,
        };
        sack.setBit(0);
        sack.setBit(@as(u16, valid_len) * 8 - 1);
        const written = sack.encode(&buf);
        try testing.expectEqual(@as(usize, 2 + valid_len), written);
        const decoded = utp.SelectiveAck.decode(buf[0..written]) orelse return error.DecodeFailed;
        try testing.expectEqual(valid_len, decoded.len);
        try testing.expect(decoded.isAcked(0));
        try testing.expect(decoded.isAcked(@as(u16, valid_len) * 8 - 1));
    }
}

test "BUGGIFY: SelectiveAck.decode random byte fuzz" {
    for (fuzz_seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();
        for (0..512) |_| {
            const len = rand.uintLessThan(usize, 300);
            var buf: [300]u8 = undefined;
            const data = buf[0..len];
            rand.bytes(data);
            // Must never panic.
            _ = utp.SelectiveAck.decode(data);
        }
    }
}
