//! BUGGIFY/fuzz coverage for the shared bencode scanner.
//!
//! `BencodeScanner` (`src/net/bencode_scanner.zig`) is the zero-alloc
//! pull-parser used by BEP 10 extension handshakes (`src/net/extensions.zig`)
//! and BEP 9 ut_metadata (`src/net/ut_metadata.zig`). Both surfaces
//! receive peer-controlled bytes — extension messages can be up to ~1
//! MiB per BEP 10, far past UDP MTU.
//!
//! This file pins the parser's bounds-checks against adversarial input:
//!
//! * length-prefix overflow on `parseBytes` (the `i + len > data.len`
//!   form panicked in safe mode for `len` near `maxInt(usize)`; the
//!   hardened form uses saturating subtraction + a 20-digit cap),
//! * digit-run overflow on `parseInteger` (similar bound),
//! * recursion depth on `skipValue` (peer-controlled extension messages
//!   can carry deeply-nested bencode; the hardened scanner has an
//!   explicit `max_depth = 64` per-instance bound that rejects beyond
//!   the limit instead of overflowing the native call stack).
//!
//! Per the layered testing strategy, this asserts SAFETY only —
//! no panics, no UB, no out-of-bounds reads. The parser is allowed to
//! reject inputs it doesn't understand; what it cannot do is crash.

const std = @import("std");
const testing = std.testing;
const varuna = @import("varuna");
const BencodeScanner = varuna.net.bencode_scanner.BencodeScanner;

const Scanner = BencodeScanner(error{InvalidMessage});

// ── parseBytes bounds ─────────────────────────────────────────

test "scanner: parseBytes rejects > 20-digit length prefix" {
    const inputs = [_][]const u8{
        "999999999999999999999:", // 21 digits
        "9999999999999999999999999999:hello", // 28 digits
        "12345678901234567890987654321:hi", // 29 digits
    };
    for (inputs) |inp| {
        var s = Scanner.init(inp);
        try testing.expectError(error.InvalidMessage, s.parseBytes());
    }
}

test "scanner: parseBytes with maxInt-ish length prefix does not panic" {
    // 20 nines: parseUnsigned succeeds with value > input.len. The
    // saturating-remainder check must catch this without overflow.
    const inp = "99999999999999999999:abc";
    var s = Scanner.init(inp);
    try testing.expectError(error.InvalidMessage, s.parseBytes());
}

test "scanner: parseBytes with claim > input length is rejected" {
    // 6-digit length, body is only 3 bytes long. Must reject cleanly.
    const inp = "100000:abc";
    var s = Scanner.init(inp);
    try testing.expectError(error.InvalidMessage, s.parseBytes());
}

test "scanner: parseBytes happy-path still works" {
    var s = Scanner.init("5:hello");
    const result = try s.parseBytes();
    try testing.expectEqualStrings("hello", result);
}

// ── parseInteger bounds ───────────────────────────────────────

test "scanner: parseInteger rejects > 21-char digit run" {
    const inputs = [_][]const u8{
        "i999999999999999999999e", // 21 digits, hits cap exactly
        "i-9999999999999999999999e", // sign + 22 digits
    };
    for (inputs) |inp| {
        var s = Scanner.init(inp);
        // 21-char digit run that ALSO exceeds i64 max would normally
        // pass through to parseInt and return Overflow. Either form is
        // a clean rejection.
        try testing.expectError(error.InvalidMessage, s.parseInteger());
    }
}

test "scanner: parseInteger happy-path still works" {
    var s = Scanner.init("i42e");
    try testing.expectEqual(@as(i64, 42), try s.parseInteger());
    var s_neg = Scanner.init("i-7e");
    try testing.expectEqual(@as(i64, -7), try s_neg.parseInteger());
}

// ── skipValue recursion bound ─────────────────────────────────

test "scanner: skipValue rejects nesting beyond max_depth" {
    // Build deeply-nested dict: d1:ad1:ad1:a...d1:ade...e
    // Each level adds 4 bytes (`d1:a`); innermost value is `de` (empty
    // dict), then closing 'e's. With max_depth=64, even a depth of 70
    // should reject cleanly.
    const depth: usize = 70;
    const total = depth * 4 + 2 + depth;
    var buf = try testing.allocator.alloc(u8, total);
    defer testing.allocator.free(buf);
    for (0..depth) |i| {
        buf[i * 4 + 0] = 'd';
        buf[i * 4 + 1] = '1';
        buf[i * 4 + 2] = ':';
        buf[i * 4 + 3] = 'a';
    }
    const prefix_len = depth * 4;
    buf[prefix_len] = 'd';
    buf[prefix_len + 1] = 'e';
    @memset(buf[prefix_len + 2 ..], 'e');

    var s = Scanner.init(buf);
    try testing.expectError(error.InvalidMessage, s.skipValue());
}

test "scanner: skipValue accepts nesting at the depth boundary" {
    // 60 levels — well within the 64 cap.
    const depth: usize = 60;
    const total = depth * 4 + 2 + depth;
    var buf = try testing.allocator.alloc(u8, total);
    defer testing.allocator.free(buf);
    for (0..depth) |i| {
        buf[i * 4 + 0] = 'd';
        buf[i * 4 + 1] = '1';
        buf[i * 4 + 2] = ':';
        buf[i * 4 + 3] = 'a';
    }
    const prefix_len = depth * 4;
    buf[prefix_len] = 'd';
    buf[prefix_len + 1] = 'e';
    @memset(buf[prefix_len + 2 ..], 'e');

    var s = Scanner.init(buf);
    try s.skipValue();
}

test "scanner: skipValue list nesting is also bounded" {
    // 70 nested lists. Same as the dict case but using 'l' wrappers.
    const depth: usize = 70;
    var buf = try testing.allocator.alloc(u8, depth + 3 + depth);
    defer testing.allocator.free(buf);
    @memset(buf[0..depth], 'l');
    buf[depth] = 'i';
    buf[depth + 1] = '0';
    buf[depth + 2] = 'e';
    @memset(buf[depth + 3 ..], 'e');

    var s = Scanner.init(buf);
    try testing.expectError(error.InvalidMessage, s.skipValue());
}

test "scanner: skipValue rejects 1024+ deep nesting without blowing the stack" {
    // The post-rewrite skipValue is iterative (explicit container stack
    // sized at `max_depth`). This exercises a depth far beyond what any
    // valid bencode payload would carry — even a 1500-byte UDP MTU could
    // only fit ~750 'd' bytes — so the input crosses well past the
    // recursion limit a hostile peer could realistically craft. The
    // safety property is "no native-stack overflow"; the visible
    // outcome is a clean `error.InvalidMessage` thanks to the
    // `max_depth = 64` cap.
    const depth: usize = 4096;
    var buf = try testing.allocator.alloc(u8, depth + 1);
    defer testing.allocator.free(buf);
    @memset(buf[0..depth], 'l');
    // Drop a single trailing 'e' to make the input syntactically
    // closeable in principle, even though the depth bound rejects it
    // first.
    buf[depth] = 'e';

    var s = Scanner.init(buf);
    try testing.expectError(error.InvalidMessage, s.skipValue());
}

// ── Random-byte fuzz ──────────────────────────────────────────

const fuzz_seeds = [_]u64{
    0x00000000, 0xdeadbeef, 0xcafebabe, 0xffffffff,
    0x12345678, 0x87654321, 0xa1b2c3d4,
};

test "BUGGIFY: scanner is panic-free over random bytes" {
    for (fuzz_seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        for (0..1024) |_| {
            const len = prng.random().uintLessThan(usize, 1024);
            var buf: [1024]u8 = undefined;
            prng.random().bytes(buf[0..len]);

            // Try each entry point — must not panic regardless of input.
            var s1 = Scanner.init(buf[0..len]);
            _ = s1.parseBytes() catch {};
            var s2 = Scanner.init(buf[0..len]);
            _ = s2.parseInteger() catch {};
            var s3 = Scanner.init(buf[0..len]);
            _ = s3.skipValue() catch {};
        }
    }
}
