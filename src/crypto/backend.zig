//! Cryptographic algorithm dispatch module.
//!
//! Exports `Sha1`, `Sha256`, and `Rc4` types whose implementation is selected
//! at compile time via the `-Dcrypto=varuna|stdlib|boringssl` build option.
//!
//! All callers that need hashing or RC4 should import from this module
//! (via `@import("../crypto/root.zig")` or `varuna.crypto`) rather than
//! reaching directly into `sha1.zig`, `std.crypto`, or `boringssl.zig`.

const std = @import("std");
const build_options = @import("build_options");

pub const CryptoBackend = @TypeOf(build_options.crypto_backend);
pub const crypto_backend: CryptoBackend = build_options.crypto_backend;

// ── SHA-1 ────────────────────────────────────────────────────────────

pub const Sha1 = switch (crypto_backend) {
    .varuna => @import("sha1.zig"),
    .stdlib => std.crypto.hash.Sha1,
    .boringssl => @import("boringssl.zig").Sha1,
};

// ── SHA-256 ──────────────────────────────────────────────────────────

pub const Sha256 = switch (crypto_backend) {
    .varuna => std.crypto.hash.sha2.Sha256,
    .stdlib => std.crypto.hash.sha2.Sha256,
    .boringssl => @import("boringssl.zig").Sha256,
};

// ── RC4 ──────────────────────────────────────────────────────────────
// stdlib has no RC4, so both `varuna` and `stdlib` use our implementation.

pub const Rc4 = switch (crypto_backend) {
    .varuna => @import("rc4.zig").Rc4,
    .stdlib => @import("rc4.zig").Rc4,
    .boringssl => @import("boringssl.zig").Rc4,
};

// ── Tests ────────────────────────────────────────────────────────────

test "SHA-1 backend produces correct digest" {
    const input = "abc";
    const expected = [_]u8{
        0xa9, 0x99, 0x3e, 0x36, 0x47, 0x06, 0x81, 0x6a, 0xba, 0x3e,
        0x25, 0x71, 0x78, 0x50, 0xc2, 0x6c, 0x9c, 0xd0, 0xd8, 0x9d,
    };
    var out: [20]u8 = undefined;
    Sha1.hash(input, &out, .{});
    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "SHA-1 backend incremental update matches one-shot" {
    const input = "The quick brown fox jumps over the lazy dog";
    var one_shot: [20]u8 = undefined;
    Sha1.hash(input, &one_shot, .{});

    var d = Sha1.init(.{});
    d.update(input[0..10]);
    d.update(input[10..]);
    const incremental = d.finalResult();

    try std.testing.expectEqualSlices(u8, &one_shot, &incremental);
}

test "SHA-256 backend produces correct digest" {
    const input = "abc";
    const expected = [_]u8{
        0xba, 0x78, 0x16, 0xbf, 0x8f, 0x01, 0xcf, 0xea,
        0x41, 0x41, 0x40, 0xde, 0x5d, 0xae, 0x22, 0x23,
        0xb0, 0x03, 0x61, 0xa3, 0x96, 0x17, 0x7a, 0x9c,
        0xb4, 0x10, 0xff, 0x61, 0xf2, 0x00, 0x15, 0xad,
    };
    var out: [32]u8 = undefined;
    Sha256.hash(input, &out, .{});
    try std.testing.expectEqualSlices(u8, &expected, &out);
}

test "SHA-256 backend incremental update matches one-shot" {
    const input = "The quick brown fox jumps over the lazy dog";
    var one_shot: [32]u8 = undefined;
    Sha256.hash(input, &one_shot, .{});

    var d = Sha256.init(.{});
    d.update(input[0..15]);
    d.update(input[15..]);
    const incremental = d.finalResult();

    try std.testing.expectEqualSlices(u8, &one_shot, &incremental);
}

test "RC4 backend known test vector - Key=Key, Plaintext=Plaintext" {
    var rc4 = Rc4.init("Key");
    const plaintext = "Plaintext";
    var ciphertext: [9]u8 = undefined;
    rc4.process(&ciphertext, plaintext);
    const expected = [_]u8{ 0xBB, 0xF3, 0x16, 0xE8, 0xD9, 0x40, 0xAF, 0x0A, 0xD3 };
    try std.testing.expectEqualSlices(u8, &expected, &ciphertext);
}

test "RC4 backend encrypt-decrypt roundtrip" {
    const key = "test_key_12345";
    const plaintext = "Hello, World! This is a test of RC4 encryption.";
    var enc = Rc4.init(key);
    var dec = Rc4.init(key);
    var ciphertext: [plaintext.len]u8 = undefined;
    var recovered: [plaintext.len]u8 = undefined;
    enc.process(&ciphertext, plaintext);
    dec.process(&recovered, &ciphertext);
    try std.testing.expectEqualSlices(u8, plaintext, &recovered);
}

test "RC4 backend BEP 6 discard roundtrip" {
    const key = "mse_shared_secret_key_abc123";
    const plaintext = "BitTorrent protocol data stream";
    var enc = Rc4.initDiscardBep6(key);
    var dec = Rc4.initDiscardBep6(key);
    var ciphertext: [plaintext.len]u8 = undefined;
    var recovered: [plaintext.len]u8 = undefined;
    enc.process(&ciphertext, plaintext);
    try std.testing.expect(!std.mem.eql(u8, plaintext, &ciphertext));
    dec.process(&recovered, &ciphertext);
    try std.testing.expectEqualSlices(u8, plaintext, &recovered);
}

test "RC4 backend keystream matches XOR with zeros" {
    const key = "stream_key";
    var rc4a = Rc4.init(key);
    var rc4b = Rc4.init(key);
    var ks: [32]u8 = undefined;
    rc4a.keystream(&ks);
    const zeros = @as([32]u8, @splat(0));
    var xored: [32]u8 = undefined;
    rc4b.process(&xored, &zeros);
    try std.testing.expectEqualSlices(u8, &ks, &xored);
}

test "SHA-1 backend matches stdlib reference" {
    // Cross-check: regardless of backend, verify against a hardcoded known-good value.
    // SHA-1("") = da39a3ee5e6b4b0d3255bfef95601890afd80709
    const expected_empty = [_]u8{
        0xda, 0x39, 0xa3, 0xee, 0x5e, 0x6b, 0x4b, 0x0d,
        0x32, 0x55, 0xbf, 0xef, 0x95, 0x60, 0x18, 0x90,
        0xaf, 0xd8, 0x07, 0x09,
    };
    var out: [20]u8 = undefined;
    Sha1.hash("", &out, .{});
    try std.testing.expectEqualSlices(u8, &expected_empty, &out);
}

test "SHA-256 backend matches stdlib reference" {
    // SHA-256("") = e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855
    const expected_empty = [_]u8{
        0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
        0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
        0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
        0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
    };
    var out: [32]u8 = undefined;
    Sha256.hash("", &out, .{});
    try std.testing.expectEqualSlices(u8, &expected_empty, &out);
}
