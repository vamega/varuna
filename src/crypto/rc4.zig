//! RC4 stream cipher for MSE/PE (BEP 6).
//!
//! RC4 is used for obfuscation of the BitTorrent stream after the MSE
//! handshake completes. The first 1024 bytes of the keystream are discarded
//! per the specification to defend against known-plaintext attacks on the
//! early RC4 keystream.

const std = @import("std");

pub const Rc4 = struct {
    s: [256]u8,
    i: u8 = 0,
    j: u8 = 0,

    /// Initialize the RC4 state with the given key using the KSA.
    pub fn init(key: []const u8) Rc4 {
        if (key.len == 0) @panic("RC4 key must not be empty");
        var rc4 = Rc4{ .s = undefined };
        // Key-Scheduling Algorithm (KSA)
        for (0..256) |idx| {
            rc4.s[idx] = @intCast(idx);
        }
        var j: u8 = 0;
        for (0..256) |idx| {
            const ii: u8 = @intCast(idx);
            j = j +% rc4.s[ii] +% key[idx % key.len];
            std.mem.swap(u8, &rc4.s[ii], &rc4.s[j]);
        }
        return rc4;
    }

    /// Initialize RC4 and discard the first 1024 bytes of keystream.
    /// This is required by BEP 6 to avoid known-plaintext attacks.
    pub fn initDiscardBep6(key: []const u8) Rc4 {
        var rc4 = Rc4.init(key);
        // Discard first 1024 bytes
        var discard: [1024]u8 = undefined;
        rc4.process(&discard, &discard);
        return rc4;
    }

    /// XOR the input with the keystream to produce output.
    /// For encryption and decryption (RC4 is symmetric).
    pub fn process(self: *Rc4, dst: []u8, src: []const u8) void {
        std.debug.assert(dst.len == src.len);
        for (0..src.len) |idx| {
            self.i = self.i +% 1;
            self.j = self.j +% self.s[self.i];
            std.mem.swap(u8, &self.s[self.i], &self.s[self.j]);
            const k = self.s[self.s[self.i] +% self.s[self.j]];
            dst[idx] = src[idx] ^ k;
        }
    }

    /// Generate keystream bytes without XOR (useful for padding generation).
    pub fn keystream(self: *Rc4, dst: []u8) void {
        for (0..dst.len) |idx| {
            self.i = self.i +% 1;
            self.j = self.j +% self.s[self.i];
            std.mem.swap(u8, &self.s[self.i], &self.s[self.j]);
            dst[idx] = self.s[self.s[self.i] +% self.s[self.j]];
        }
    }
};

// ── Tests ─────────────────────────────────────────────────

test "RC4 known test vector - Key=Key, Plaintext=Plaintext" {
    // RFC 6229 test vectors are for longer outputs; use the classic test:
    // Key: "Key", Plaintext: "Plaintext"
    // Expected ciphertext: BBF316E8D940AF0AD3 (hex)
    var rc4 = Rc4.init("Key");
    const plaintext = "Plaintext";
    var ciphertext: [9]u8 = undefined;
    rc4.process(&ciphertext, plaintext);
    const expected = [_]u8{ 0xBB, 0xF3, 0x16, 0xE8, 0xD9, 0x40, 0xAF, 0x0A, 0xD3 };
    try std.testing.expectEqualSlices(u8, &expected, &ciphertext);
}

test "RC4 known test vector - Key=Wiki, Plaintext=pedia" {
    var rc4 = Rc4.init("Wiki");
    const plaintext = "pedia";
    var ciphertext: [5]u8 = undefined;
    rc4.process(&ciphertext, plaintext);
    const expected = [_]u8{ 0x10, 0x21, 0xBF, 0x04, 0x20 };
    try std.testing.expectEqualSlices(u8, &expected, &ciphertext);
}

test "RC4 encrypt then decrypt is identity" {
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

test "RC4 with BEP 6 discard produces different output than plain RC4" {
    const key = "test_key";
    var plain_rc4 = Rc4.init(key);
    var bep6_rc4 = Rc4.initDiscardBep6(key);
    var out1: [16]u8 = undefined;
    var out2: [16]u8 = undefined;
    const input = [_]u8{0} ** 16;
    plain_rc4.process(&out1, &input);
    bep6_rc4.process(&out2, &input);
    // After discarding 1024 bytes, keystream should differ
    try std.testing.expect(!std.mem.eql(u8, &out1, &out2));
}

test "RC4 BEP 6 discard encrypt-decrypt roundtrip" {
    const key = "mse_shared_secret_key_abc123";
    const plaintext = "BitTorrent protocol data stream";
    var enc = Rc4.initDiscardBep6(key);
    var dec = Rc4.initDiscardBep6(key);
    var ciphertext: [plaintext.len]u8 = undefined;
    var recovered: [plaintext.len]u8 = undefined;
    enc.process(&ciphertext, plaintext);
    // Ciphertext should not equal plaintext
    try std.testing.expect(!std.mem.eql(u8, plaintext, &ciphertext));
    dec.process(&recovered, &ciphertext);
    try std.testing.expectEqualSlices(u8, plaintext, &recovered);
}

test "RC4 keystream generation" {
    const key = "stream_key";
    var rc4a = Rc4.init(key);
    var rc4b = Rc4.init(key);
    var ks: [32]u8 = undefined;
    rc4a.keystream(&ks);
    // XOR with zeros should produce the same keystream
    const zeros = [_]u8{0} ** 32;
    var xored: [32]u8 = undefined;
    rc4b.process(&xored, &zeros);
    try std.testing.expectEqualSlices(u8, &ks, &xored);
}
