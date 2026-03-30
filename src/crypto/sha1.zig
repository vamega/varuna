//! SHA-1 with SHA-NI hardware acceleration on x86_64.
//!
//! When compiled for an x86_64 target with the `sha` and `sse4_1` features
//! enabled (e.g. `-Dcpu=native` on AMD Zen / Intel Goldmont+), the round
//! function uses SHA-NI intrinsics for ~3-5x throughput vs the software
//! fallback.  On targets without SHA-NI the implementation falls back to
//! the same scalar code as `std.crypto.hash.Sha1`.
//!
//! API-compatible with `std.crypto.hash.Sha1`: init / update / final / hash.

const std = @import("std");
const builtin = @import("builtin");
const mem = std.mem;
const math = std.math;

const Sha1 = @This();

pub const block_length = 64;
pub const digest_length = 20;
pub const Options = struct {};

s: [5]u32,
buf: [64]u8 = undefined,
buf_len: u8 = 0,
total_len: u64 = 0,

pub fn init(options: Options) Sha1 {
    _ = options;
    return .{
        .s = .{
            0x67452301,
            0xEFCDAB89,
            0x98BADCFE,
            0x10325476,
            0xC3D2E1F0,
        },
    };
}

pub fn hash(b: []const u8, out: *[digest_length]u8, options: Options) void {
    var d = Sha1.init(options);
    d.update(b);
    d.final(out);
}

pub fn update(d: *Sha1, b: []const u8) void {
    var off: usize = 0;

    if (d.buf_len != 0 and d.buf_len + b.len >= 64) {
        off += 64 - d.buf_len;
        @memcpy(d.buf[d.buf_len..][0..off], b[0..off]);
        d.round(d.buf[0..]);
        d.buf_len = 0;
    }

    while (off + 64 <= b.len) : (off += 64) {
        d.round(b[off..][0..64]);
    }

    @memcpy(d.buf[d.buf_len..][0 .. b.len - off], b[off..]);
    d.buf_len += @as(u8, @intCast(b[off..].len));
    d.total_len += b.len;
}

pub fn peek(d: Sha1) [digest_length]u8 {
    var copy = d;
    return copy.finalResult();
}

pub fn final(d: *Sha1, out: *[digest_length]u8) void {
    @memset(d.buf[d.buf_len..], 0);
    d.buf[d.buf_len] = 0x80;
    d.buf_len += 1;

    if (64 - d.buf_len < 8) {
        d.round(d.buf[0..]);
        @memset(d.buf[0..], 0);
    }

    var i: usize = 1;
    var len = d.total_len >> 5;
    d.buf[63] = @as(u8, @intCast(d.total_len & 0x1f)) << 3;
    while (i < 8) : (i += 1) {
        d.buf[63 - i] = @as(u8, @intCast(len & 0xff));
        len >>= 8;
    }

    d.round(d.buf[0..]);

    for (d.s, 0..) |s_val, j| {
        mem.writeInt(u32, out[4 * j ..][0..4], s_val, .big);
    }
}

pub fn finalResult(d: *Sha1) [digest_length]u8 {
    var result: [digest_length]u8 = undefined;
    d.final(&result);
    return result;
}

/// Returns true when this binary was compiled with SHA-NI acceleration.
pub fn hasShaNi() bool {
    return use_sha_ni;
}

const use_sha_ni: bool = blk: {
    if (builtin.cpu.arch != .x86_64) break :blk false;
    if (builtin.zig_backend == .stage2_c) break :blk false;
    break :blk builtin.cpu.has(.x86, .sha) and builtin.cpu.has(.x86, .sse4_1);
};

fn round(d: *Sha1, b: *const [64]u8) void {
    if (!@inComptime() and use_sha_ni) {
        d.roundShaNi(b);
        return;
    }
    d.roundSoftware(b);
}

// ── SHA-NI accelerated round ────────────────────────────────────────
//
// Uses sha1rnds4, sha1nexte, sha1msg1, sha1msg2 instructions.
// Reference: noloader/SHA-Intrinsics (sha1-x86.c).
//
// State layout in xmm registers (x86 little-endian V4u32):
//   Index 0 = bits [31:0], index 3 = bits [127:96].
//   ABCD register: A at [127:96] = index 3, D at [31:0] = index 0.
//   E register: E at [127:96] = index 3, rest zero.
fn roundShaNi(d: *Sha1, b: *const [64]u8) void {
    const V4u32 = @Vector(4, u32);
    const Vu8x16 = @Vector(16, u8);

    // Byte-swap mask matching _mm_set_epi64x(0x0001020304050607, 0x08090a0b0c0d0e0f).
    // In memory (little-endian): 0f 0e 0d 0c 0b 0a 09 08 07 06 05 04 03 02 01 00.
    // This reverses all 16 bytes, which byte-swaps each 32-bit word AND reverses
    // word order -- exactly what SHA-NI needs for the message schedule.
    const bswap_mask = V4u32{ 0x0c0d0e0f, 0x08090a0b, 0x04050607, 0x00010203 };

    // Load and byte-swap message blocks.
    var msg0: V4u32 = @bitCast(shuffleBytes(@as(Vu8x16, @bitCast(@as(*align(1) const [16]u8, b[0..16]).*)), @as(Vu8x16, @bitCast(bswap_mask))));
    var msg1: V4u32 = @bitCast(shuffleBytes(@as(Vu8x16, @bitCast(@as(*align(1) const [16]u8, b[16..32]).*)), @as(Vu8x16, @bitCast(bswap_mask))));
    var msg2: V4u32 = @bitCast(shuffleBytes(@as(Vu8x16, @bitCast(@as(*align(1) const [16]u8, b[32..48]).*)), @as(Vu8x16, @bitCast(bswap_mask))));
    var msg3: V4u32 = @bitCast(shuffleBytes(@as(Vu8x16, @bitCast(@as(*align(1) const [16]u8, b[48..64]).*)), @as(Vu8x16, @bitCast(bswap_mask))));

    // Load state.  The hardware wants A at bits [127:96].
    // In memory state is [A, B, C, D] = s[0..3]. Loading as V4u32 gives
    // index0=A, index3=D.  We need to reverse so A lands at index 3.
    var abcd = V4u32{ d.s[3], d.s[2], d.s[1], d.s[0] };
    var e0 = V4u32{ 0, 0, 0, d.s[4] };

    const abcd_save = abcd;
    const e_save = e0;

    // Rounds 0-3
    e0 = paddd(e0, msg0);
    var e1 = abcd;
    abcd = sha1rnds4(abcd, e0, 0);

    // Rounds 4-7
    e1 = sha1nexte(e1, msg1);
    e0 = abcd;
    abcd = sha1rnds4(abcd, e1, 0);
    msg0 = sha1msg1(msg0, msg1);

    // Rounds 8-11
    e0 = sha1nexte(e0, msg2);
    e1 = abcd;
    abcd = sha1rnds4(abcd, e0, 0);
    msg1 = sha1msg1(msg1, msg2);
    msg0 ^= msg2;

    // Rounds 12-15
    e1 = sha1nexte(e1, msg3);
    e0 = abcd;
    msg0 = sha1msg2(msg0, msg3);
    abcd = sha1rnds4(abcd, e1, 0);
    msg2 = sha1msg1(msg2, msg3);
    msg1 ^= msg3;

    // Rounds 16-19
    e0 = sha1nexte(e0, msg0);
    e1 = abcd;
    msg1 = sha1msg2(msg1, msg0);
    abcd = sha1rnds4(abcd, e0, 0);
    msg3 = sha1msg1(msg3, msg0);
    msg2 ^= msg0;

    // Rounds 20-23
    e1 = sha1nexte(e1, msg1);
    e0 = abcd;
    msg2 = sha1msg2(msg2, msg1);
    abcd = sha1rnds4(abcd, e1, 1);
    msg0 = sha1msg1(msg0, msg1);
    msg3 ^= msg1;

    // Rounds 24-27
    e0 = sha1nexte(e0, msg2);
    e1 = abcd;
    msg3 = sha1msg2(msg3, msg2);
    abcd = sha1rnds4(abcd, e0, 1);
    msg1 = sha1msg1(msg1, msg2);
    msg0 ^= msg2;

    // Rounds 28-31
    e1 = sha1nexte(e1, msg3);
    e0 = abcd;
    msg0 = sha1msg2(msg0, msg3);
    abcd = sha1rnds4(abcd, e1, 1);
    msg2 = sha1msg1(msg2, msg3);
    msg1 ^= msg3;

    // Rounds 32-35
    e0 = sha1nexte(e0, msg0);
    e1 = abcd;
    msg1 = sha1msg2(msg1, msg0);
    abcd = sha1rnds4(abcd, e0, 1);
    msg3 = sha1msg1(msg3, msg0);
    msg2 ^= msg0;

    // Rounds 36-39
    e1 = sha1nexte(e1, msg1);
    e0 = abcd;
    msg2 = sha1msg2(msg2, msg1);
    abcd = sha1rnds4(abcd, e1, 1);
    msg0 = sha1msg1(msg0, msg1);
    msg3 ^= msg1;

    // Rounds 40-43
    e0 = sha1nexte(e0, msg2);
    e1 = abcd;
    msg3 = sha1msg2(msg3, msg2);
    abcd = sha1rnds4(abcd, e0, 2);
    msg1 = sha1msg1(msg1, msg2);
    msg0 ^= msg2;

    // Rounds 44-47
    e1 = sha1nexte(e1, msg3);
    e0 = abcd;
    msg0 = sha1msg2(msg0, msg3);
    abcd = sha1rnds4(abcd, e1, 2);
    msg2 = sha1msg1(msg2, msg3);
    msg1 ^= msg3;

    // Rounds 48-51
    e0 = sha1nexte(e0, msg0);
    e1 = abcd;
    msg1 = sha1msg2(msg1, msg0);
    abcd = sha1rnds4(abcd, e0, 2);
    msg3 = sha1msg1(msg3, msg0);
    msg2 ^= msg0;

    // Rounds 52-55
    e1 = sha1nexte(e1, msg1);
    e0 = abcd;
    msg2 = sha1msg2(msg2, msg1);
    abcd = sha1rnds4(abcd, e1, 2);
    msg0 = sha1msg1(msg0, msg1);
    msg3 ^= msg1;

    // Rounds 56-59
    e0 = sha1nexte(e0, msg2);
    e1 = abcd;
    msg3 = sha1msg2(msg3, msg2);
    abcd = sha1rnds4(abcd, e0, 2);
    msg1 = sha1msg1(msg1, msg2);
    msg0 ^= msg2;

    // Rounds 60-63
    e1 = sha1nexte(e1, msg3);
    e0 = abcd;
    msg0 = sha1msg2(msg0, msg3);
    abcd = sha1rnds4(abcd, e1, 3);
    msg2 = sha1msg1(msg2, msg3);
    msg1 ^= msg3;

    // Rounds 64-67
    e0 = sha1nexte(e0, msg0);
    e1 = abcd;
    msg1 = sha1msg2(msg1, msg0);
    abcd = sha1rnds4(abcd, e0, 3);
    msg3 = sha1msg1(msg3, msg0);
    msg2 ^= msg0;

    // Rounds 68-71
    e1 = sha1nexte(e1, msg1);
    e0 = abcd;
    msg2 = sha1msg2(msg2, msg1);
    abcd = sha1rnds4(abcd, e1, 3);
    msg3 ^= msg1;

    // Rounds 72-75
    e0 = sha1nexte(e0, msg2);
    e1 = abcd;
    msg3 = sha1msg2(msg3, msg2);
    abcd = sha1rnds4(abcd, e0, 3);

    // Rounds 76-79
    e1 = sha1nexte(e1, msg3);
    e0 = abcd;
    abcd = sha1rnds4(abcd, e1, 3);

    // Add back initial state.
    e0 = sha1nexte(e0, e_save);
    abcd +%= abcd_save;

    d.s[0] = abcd[3];
    d.s[1] = abcd[2];
    d.s[2] = abcd[1];
    d.s[3] = abcd[0];
    d.s[4] = e0[3];
}

inline fn sha1rnds4(cdba: @Vector(4, u32), e_msg: @Vector(4, u32), comptime func: u8) @Vector(4, u32) {
    return asm ("sha1rnds4 %[imm], %[e_msg], %[cdba]"
        : [cdba] "=x" (-> @Vector(4, u32)),
        : [_] "0" (cdba),
          [e_msg] "x" (e_msg),
          [imm] "n" (func),
    );
}

inline fn sha1nexte(e: @Vector(4, u32), msg: @Vector(4, u32)) @Vector(4, u32) {
    return asm ("sha1nexte %[msg], %[e]"
        : [e] "=x" (-> @Vector(4, u32)),
        : [_] "0" (e),
          [msg] "x" (msg),
    );
}

inline fn sha1msg1(a: @Vector(4, u32), b: @Vector(4, u32)) @Vector(4, u32) {
    return asm ("sha1msg1 %[b], %[a]"
        : [a] "=x" (-> @Vector(4, u32)),
        : [_] "0" (a),
          [b] "x" (b),
    );
}

inline fn sha1msg2(a: @Vector(4, u32), b: @Vector(4, u32)) @Vector(4, u32) {
    return asm ("sha1msg2 %[b], %[a]"
        : [a] "=x" (-> @Vector(4, u32)),
        : [_] "0" (a),
          [b] "x" (b),
    );
}

inline fn paddd(a: @Vector(4, u32), b: @Vector(4, u32)) @Vector(4, u32) {
    return a +% b;
}

inline fn shuffleBytes(a: @Vector(16, u8), mask: @Vector(16, u8)) @Vector(16, u8) {
    return asm ("pshufb %[mask], %[a]"
        : [a] "=x" (-> @Vector(16, u8)),
        : [_] "0" (a),
          [mask] "x" (mask),
    );
}

// ── Software fallback (same as std.crypto.hash.Sha1) ────────────────
fn roundSoftware(d: *Sha1, b: *const [64]u8) void {
    var s: [16]u32 = undefined;

    var v: [5]u32 = d.s;

    const round0a = comptime [_]RoundParam{
        rp(0, 1, 2, 3, 4, 0),  rp(4, 0, 1, 2, 3, 1),  rp(3, 4, 0, 1, 2, 2),  rp(2, 3, 4, 0, 1, 3),
        rp(1, 2, 3, 4, 0, 4),  rp(0, 1, 2, 3, 4, 5),  rp(4, 0, 1, 2, 3, 6),  rp(3, 4, 0, 1, 2, 7),
        rp(2, 3, 4, 0, 1, 8),  rp(1, 2, 3, 4, 0, 9),  rp(0, 1, 2, 3, 4, 10), rp(4, 0, 1, 2, 3, 11),
        rp(3, 4, 0, 1, 2, 12), rp(2, 3, 4, 0, 1, 13), rp(1, 2, 3, 4, 0, 14), rp(0, 1, 2, 3, 4, 15),
    };
    inline for (round0a) |r| {
        s[r.i] = mem.readInt(u32, b[r.i * 4 ..][0..4], .big);
        v[r.e] = v[r.e] +% math.rotl(u32, v[r.a], @as(u32, 5)) +% 0x5A827999 +% s[r.i & 0xf] +% ((v[r.b] & v[r.c]) | (~v[r.b] & v[r.d]));
        v[r.b] = math.rotl(u32, v[r.b], @as(u32, 30));
    }

    const round0b = comptime [_]RoundParam{
        rp(4, 0, 1, 2, 3, 16), rp(3, 4, 0, 1, 2, 17), rp(2, 3, 4, 0, 1, 18), rp(1, 2, 3, 4, 0, 19),
    };
    inline for (round0b) |r| {
        const t = s[(r.i - 3) & 0xf] ^ s[(r.i - 8) & 0xf] ^ s[(r.i - 14) & 0xf] ^ s[(r.i - 16) & 0xf];
        s[r.i & 0xf] = math.rotl(u32, t, @as(u32, 1));
        v[r.e] = v[r.e] +% math.rotl(u32, v[r.a], @as(u32, 5)) +% 0x5A827999 +% s[r.i & 0xf] +% ((v[r.b] & v[r.c]) | (~v[r.b] & v[r.d]));
        v[r.b] = math.rotl(u32, v[r.b], @as(u32, 30));
    }

    const round1 = comptime [_]RoundParam{
        rp(0, 1, 2, 3, 4, 20), rp(4, 0, 1, 2, 3, 21), rp(3, 4, 0, 1, 2, 22), rp(2, 3, 4, 0, 1, 23),
        rp(1, 2, 3, 4, 0, 24), rp(0, 1, 2, 3, 4, 25), rp(4, 0, 1, 2, 3, 26), rp(3, 4, 0, 1, 2, 27),
        rp(2, 3, 4, 0, 1, 28), rp(1, 2, 3, 4, 0, 29), rp(0, 1, 2, 3, 4, 30), rp(4, 0, 1, 2, 3, 31),
        rp(3, 4, 0, 1, 2, 32), rp(2, 3, 4, 0, 1, 33), rp(1, 2, 3, 4, 0, 34), rp(0, 1, 2, 3, 4, 35),
        rp(4, 0, 1, 2, 3, 36), rp(3, 4, 0, 1, 2, 37), rp(2, 3, 4, 0, 1, 38), rp(1, 2, 3, 4, 0, 39),
    };
    inline for (round1) |r| {
        const t = s[(r.i - 3) & 0xf] ^ s[(r.i - 8) & 0xf] ^ s[(r.i - 14) & 0xf] ^ s[(r.i - 16) & 0xf];
        s[r.i & 0xf] = math.rotl(u32, t, @as(u32, 1));
        v[r.e] = v[r.e] +% math.rotl(u32, v[r.a], @as(u32, 5)) +% 0x6ED9EBA1 +% s[r.i & 0xf] +% (v[r.b] ^ v[r.c] ^ v[r.d]);
        v[r.b] = math.rotl(u32, v[r.b], @as(u32, 30));
    }

    const round2 = comptime [_]RoundParam{
        rp(0, 1, 2, 3, 4, 40), rp(4, 0, 1, 2, 3, 41), rp(3, 4, 0, 1, 2, 42), rp(2, 3, 4, 0, 1, 43),
        rp(1, 2, 3, 4, 0, 44), rp(0, 1, 2, 3, 4, 45), rp(4, 0, 1, 2, 3, 46), rp(3, 4, 0, 1, 2, 47),
        rp(2, 3, 4, 0, 1, 48), rp(1, 2, 3, 4, 0, 49), rp(0, 1, 2, 3, 4, 50), rp(4, 0, 1, 2, 3, 51),
        rp(3, 4, 0, 1, 2, 52), rp(2, 3, 4, 0, 1, 53), rp(1, 2, 3, 4, 0, 54), rp(0, 1, 2, 3, 4, 55),
        rp(4, 0, 1, 2, 3, 56), rp(3, 4, 0, 1, 2, 57), rp(2, 3, 4, 0, 1, 58), rp(1, 2, 3, 4, 0, 59),
    };
    inline for (round2) |r| {
        const t = s[(r.i - 3) & 0xf] ^ s[(r.i - 8) & 0xf] ^ s[(r.i - 14) & 0xf] ^ s[(r.i - 16) & 0xf];
        s[r.i & 0xf] = math.rotl(u32, t, @as(u32, 1));
        v[r.e] = v[r.e] +% math.rotl(u32, v[r.a], @as(u32, 5)) +% 0x8F1BBCDC +% s[r.i & 0xf] +% ((v[r.b] & v[r.c]) ^ (v[r.b] & v[r.d]) ^ (v[r.c] & v[r.d]));
        v[r.b] = math.rotl(u32, v[r.b], @as(u32, 30));
    }

    const round3 = comptime [_]RoundParam{
        rp(0, 1, 2, 3, 4, 60), rp(4, 0, 1, 2, 3, 61), rp(3, 4, 0, 1, 2, 62), rp(2, 3, 4, 0, 1, 63),
        rp(1, 2, 3, 4, 0, 64), rp(0, 1, 2, 3, 4, 65), rp(4, 0, 1, 2, 3, 66), rp(3, 4, 0, 1, 2, 67),
        rp(2, 3, 4, 0, 1, 68), rp(1, 2, 3, 4, 0, 69), rp(0, 1, 2, 3, 4, 70), rp(4, 0, 1, 2, 3, 71),
        rp(3, 4, 0, 1, 2, 72), rp(2, 3, 4, 0, 1, 73), rp(1, 2, 3, 4, 0, 74), rp(0, 1, 2, 3, 4, 75),
        rp(4, 0, 1, 2, 3, 76), rp(3, 4, 0, 1, 2, 77), rp(2, 3, 4, 0, 1, 78), rp(1, 2, 3, 4, 0, 79),
    };
    inline for (round3) |r| {
        const t = s[(r.i - 3) & 0xf] ^ s[(r.i - 8) & 0xf] ^ s[(r.i - 14) & 0xf] ^ s[(r.i - 16) & 0xf];
        s[r.i & 0xf] = math.rotl(u32, t, @as(u32, 1));
        v[r.e] = v[r.e] +% math.rotl(u32, v[r.a], @as(u32, 5)) +% 0xCA62C1D6 +% s[r.i & 0xf] +% (v[r.b] ^ v[r.c] ^ v[r.d]);
        v[r.b] = math.rotl(u32, v[r.b], @as(u32, 30));
    }

    d.s[0] +%= v[0];
    d.s[1] +%= v[1];
    d.s[2] +%= v[2];
    d.s[3] +%= v[3];
    d.s[4] +%= v[4];
}

const RoundParam = struct {
    a: usize,
    b: usize,
    c: usize,
    d: usize,
    e: usize,
    i: u32,
};

fn rp(a: usize, b: usize, c: usize, d: usize, e: usize, i: u32) RoundParam {
    return .{ .a = a, .b = b, .c = c, .d = d, .e = e, .i = i };
}

// ── Tests ───────────────────────────────────────────────────────────

test "sha1 basic vectors" {
    var out: [20]u8 = undefined;

    // Empty string
    Sha1.hash("", &out, .{});
    try std.testing.expectEqualSlices(u8, &hexToBytes("da39a3ee5e6b4b0d3255bfef95601890afd80709"), &out);

    // "abc"
    Sha1.hash("abc", &out, .{});
    try std.testing.expectEqualSlices(u8, &hexToBytes("a9993e364706816aba3e25717850c26c9cd0d89d"), &out);

    // 448-bit message
    Sha1.hash("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq", &out, .{});
    try std.testing.expectEqualSlices(u8, &hexToBytes("84983e441c3bd26ebaae4aa1f95129e5e54670f1"), &out);

    // Long message
    Sha1.hash("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu", &out, .{});
    try std.testing.expectEqualSlices(u8, &hexToBytes("a49b2446a02c645bf419f995b67091253a04a259"), &out);
}

test "sha1 streaming" {
    var h = Sha1.init(.{});
    var out: [20]u8 = undefined;

    h.final(&out);
    try std.testing.expectEqualSlices(u8, &hexToBytes("da39a3ee5e6b4b0d3255bfef95601890afd80709"), &out);

    h = Sha1.init(.{});
    h.update("a");
    h.update("b");
    h.update("c");
    h.final(&out);
    try std.testing.expectEqualSlices(u8, &hexToBytes("a9993e364706816aba3e25717850c26c9cd0d89d"), &out);
}

test "sha1 aligned final" {
    var block = [_]u8{0} ** Sha1.block_length;
    var out: [Sha1.digest_length]u8 = undefined;

    var h = Sha1.init(.{});
    h.update(&block);
    h.final(out[0..]);
    // Just verify it doesn't crash -- the exact hash is checked by basic vectors.
}

test "sha1 matches std lib" {
    const StdSha1 = std.crypto.hash.Sha1;

    // Test with various sizes including cross-block boundaries
    const sizes = [_]usize{ 0, 1, 55, 56, 63, 64, 65, 100, 127, 128, 256, 1000, 4096 };
    for (sizes) |size| {
        var buf: [4096]u8 = undefined;
        for (buf[0..size], 0..) |*byte, idx| {
            byte.* = @truncate(idx *% 7 +% 13);
        }

        var expected: [20]u8 = undefined;
        StdSha1.hash(buf[0..size], &expected, .{});

        var actual: [20]u8 = undefined;
        Sha1.hash(buf[0..size], &actual, .{});

        try std.testing.expectEqualSlices(u8, &expected, &actual);
    }
}

test "sha1 large streaming matches std lib" {
    const StdSha1 = std.crypto.hash.Sha1;

    // Feed data in various chunk sizes to stress streaming logic
    const data_size = 256 * 1024;
    var data: [data_size]u8 = undefined;
    for (&data, 0..) |*byte, idx| {
        byte.* = @truncate(idx *% 7 +% 13);
    }

    var expected: [20]u8 = undefined;
    StdSha1.hash(&data, &expected, .{});

    // One-shot
    var actual: [20]u8 = undefined;
    Sha1.hash(&data, &actual, .{});
    try std.testing.expectEqualSlices(u8, &expected, &actual);

    // Streaming in 100-byte chunks
    var h = Sha1.init(.{});
    var off: usize = 0;
    while (off < data_size) {
        const chunk = @min(100, data_size - off);
        h.update(data[off..][0..chunk]);
        off += chunk;
    }
    h.final(&actual);
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}

fn hexToBytes(comptime hex: *const [40]u8) [20]u8 {
    var result: [20]u8 = undefined;
    for (&result, 0..) |*byte, i| {
        byte.* = std.fmt.parseInt(u8, hex[2 * i ..][0..2], 16) catch unreachable;
    }
    return result;
}
