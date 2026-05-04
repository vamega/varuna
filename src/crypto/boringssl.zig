//! BoringSSL-backed cryptographic primitives.
//!
//! Wraps the BoringSSL C API into Zig-idiomatic types that match the
//! interface expected by `backend.zig`. Only compiled when `-Dcrypto=boringssl`.

const std = @import("std");
const build_options = @import("build_options");

const ssl_c = if (build_options.tls_backend != .none)
    @cImport({
        @cInclude("openssl/sha.h");
        @cInclude("openssl/rc4.h");
    })
else
    @compileError("BoringSSL crypto backend requires -Dtls=boringssl or -Dtls=system_boringssl");

// ── SHA-1 ────────────────────────────────────────────────────────────

pub const Sha1 = struct {
    ctx: ssl_c.SHA_CTX,

    pub const block_length = 64;
    pub const digest_length = 20;
    pub const Options = struct {};

    pub fn init(options: Options) Sha1 {
        _ = options;
        var self: Sha1 = undefined;
        _ = ssl_c.SHA1_Init(&self.ctx);
        return self;
    }

    pub fn update(self: *Sha1, data: []const u8) void {
        _ = ssl_c.SHA1_Update(&self.ctx, data.ptr, data.len);
    }

    pub fn final(self: *Sha1, out: *[digest_length]u8) void {
        _ = ssl_c.SHA1_Final(out, &self.ctx);
    }

    pub fn finalResult(self: *Sha1) [digest_length]u8 {
        var result: [digest_length]u8 = undefined;
        self.final(&result);
        return result;
    }

    pub fn hash(data: []const u8, out: *[digest_length]u8, options: Options) void {
        _ = options;
        _ = ssl_c.SHA1(data.ptr, data.len, out);
    }

    pub fn peek(self: Sha1) [digest_length]u8 {
        var copy = self;
        return copy.finalResult();
    }
};

// ── SHA-256 ──────────────────────────────────────────────────────────

pub const Sha256 = struct {
    ctx: ssl_c.SHA256_CTX,

    pub const block_length = 64;
    pub const digest_length = 32;
    pub const Options = struct {};

    pub fn init(options: Options) Sha256 {
        _ = options;
        var self: Sha256 = undefined;
        _ = ssl_c.SHA256_Init(&self.ctx);
        return self;
    }

    pub fn update(self: *Sha256, data: []const u8) void {
        _ = ssl_c.SHA256_Update(&self.ctx, data.ptr, data.len);
    }

    pub fn final(self: *Sha256, out: *[digest_length]u8) void {
        _ = ssl_c.SHA256_Final(out, &self.ctx);
    }

    pub fn finalResult(self: *Sha256) [digest_length]u8 {
        var result: [digest_length]u8 = undefined;
        self.final(&result);
        return result;
    }

    pub fn hash(data: []const u8, out: *[digest_length]u8, options: Options) void {
        _ = options;
        _ = ssl_c.SHA256(data.ptr, data.len, out);
    }

    pub fn peek(self: Sha256) [digest_length]u8 {
        var copy = self;
        return copy.finalResult();
    }
};

// ── RC4 ──────────────────────────────────────────────────────────────

pub const Rc4 = struct {
    key: ssl_c.RC4_KEY,

    /// Initialize the RC4 state with the given key.
    pub fn init(key: []const u8) Rc4 {
        var self: Rc4 = undefined;
        ssl_c.RC4_set_key(&self.key, @intCast(key.len), key.ptr);
        return self;
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
        ssl_c.RC4(&self.key, src.len, src.ptr, dst.ptr);
    }

    /// Generate keystream bytes without XOR (useful for padding generation).
    pub fn keystream(self: *Rc4, dst: []u8) void {
        @memset(dst, 0);
        ssl_c.RC4(&self.key, dst.len, dst.ptr, dst.ptr);
    }
};
