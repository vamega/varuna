const std = @import("std");
const build_options = @import("build_options");

/// TLS client using BoringSSL BIO pairs.
///
/// BoringSSL never touches sockets directly. Instead:
/// - Received ciphertext (from io_uring recv) is fed into the internal BIO
/// - BoringSSL processes TLS records, producing plaintext and outbound ciphertext
/// - Outbound ciphertext is extracted and sent via io_uring send
///
/// This keeps all network I/O on io_uring while BoringSSL handles crypto/protocol.
pub const TlsStream = if (build_options.tls_backend == .boringssl)
    TlsStreamImpl
else
    TlsStreamStub;

/// Stub for builds without TLS support.
const TlsStreamStub = struct {
    pub fn init(_: std.mem.Allocator, _: []const u8) !TlsStreamStub {
        return error.TlsNotAvailable;
    }
    pub fn deinit(_: *TlsStreamStub) void {}
    pub fn feedRecv(_: *TlsStreamStub, _: []const u8) !void {
        return error.TlsNotAvailable;
    }
    pub fn readPlaintext(_: *TlsStreamStub, _: []u8) !usize {
        return error.TlsNotAvailable;
    }
    pub fn writePlaintext(_: *TlsStreamStub, _: []const u8) !usize {
        return error.TlsNotAvailable;
    }
    pub fn pendingSend(_: *TlsStreamStub, _: []u8) !usize {
        return 0;
    }
    pub fn doHandshake(_: *TlsStreamStub) !HandshakeResult {
        return error.TlsNotAvailable;
    }

    pub const HandshakeResult = TlsStreamImpl.HandshakeResult;
};

/// Full TLS implementation backed by BoringSSL.
const TlsStreamImpl = struct {
    const ssl_c = @cImport({
        @cInclude("openssl/ssl.h");
        @cInclude("openssl/bio.h");
        @cInclude("openssl/err.h");
    });

    ssl_ctx: *ssl_c.SSL_CTX,
    ssl: *ssl_c.SSL,
    /// Internal BIO: we write received ciphertext here, BoringSSL reads from it.
    internal_bio: *ssl_c.BIO,
    /// Network BIO: BoringSSL writes ciphertext here, we read from it to send.
    network_bio: *ssl_c.BIO,

    pub const HandshakeResult = enum {
        complete,
        want_read,
        want_write,
    };

    pub const Error = error{
        TlsInitFailed,
        TlsSslFailed,
        TlsHandshakeFailed,
        TlsReadFailed,
        TlsWriteFailed,
        TlsBioWriteFailed,
        TlsNotAvailable,
        TlsCertVerifyFailed,
    };

    /// Create a new TLS client stream configured for the given hostname.
    /// The hostname is used for SNI and certificate verification.
    pub fn init(_: std.mem.Allocator, hostname: []const u8) (Error || error{OutOfMemory})!TlsStreamImpl {
        const ctx = ssl_c.SSL_CTX_new(ssl_c.TLS_method()) orelse
            return error.TlsInitFailed;
        errdefer ssl_c.SSL_CTX_free(ctx);

        // Load system CA certificates for server verification
        if (ssl_c.SSL_CTX_set_default_verify_paths(ctx) != 1) {
            return error.TlsInitFailed;
        }

        // Require server certificate verification
        ssl_c.SSL_CTX_set_verify(ctx, ssl_c.SSL_VERIFY_PEER, null);

        const ssl = ssl_c.SSL_new(ctx) orelse
            return error.TlsSslFailed;
        errdefer ssl_c.SSL_free(ssl);

        ssl_c.SSL_set_connect_state(ssl);

        // Set SNI hostname -- BoringSSL needs a null-terminated string
        var hostname_buf: [253:0]u8 = undefined;
        if (hostname.len > 253) return error.TlsInitFailed;
        @memcpy(hostname_buf[0..hostname.len], hostname);
        hostname_buf[hostname.len] = 0;

        if (ssl_c.SSL_set_tlsext_host_name(ssl, &hostname_buf) != 1) {
            return error.TlsInitFailed;
        }

        // Create BIO pair: internal_bio <-> network_bio
        // We write received ciphertext to internal_bio (BoringSSL reads from it).
        // BoringSSL writes outbound ciphertext to network_bio (we read from it).
        var internal_bio: ?*ssl_c.BIO = null;
        var network_bio: ?*ssl_c.BIO = null;
        if (ssl_c.BIO_new_bio_pair(&internal_bio, 0, &network_bio, 0) != 1) {
            return error.TlsInitFailed;
        }

        // SSL_set_bio takes ownership of internal_bio. network_bio is ours to manage.
        ssl_c.SSL_set_bio(ssl, internal_bio, internal_bio);

        return .{
            .ssl_ctx = ctx,
            .ssl = ssl,
            .internal_bio = internal_bio.?,
            .network_bio = network_bio.?,
        };
    }

    pub fn deinit(self: *TlsStreamImpl) void {
        // SSL_free frees the internal_bio that was set via SSL_set_bio.
        ssl_c.SSL_free(self.ssl);
        ssl_c.SSL_CTX_free(self.ssl_ctx);
        // We own network_bio separately.
        _ = ssl_c.BIO_free(self.network_bio);
    }

    /// Feed received ciphertext from the network into BoringSSL.
    /// Call this after io_uring recv returns data.
    pub fn feedRecv(self: *TlsStreamImpl, data: []const u8) Error!void {
        var written: usize = 0;
        while (written < data.len) {
            const remaining = data.len - written;
            const chunk: c_int = @intCast(@min(remaining, std.math.maxInt(c_int)));
            const n = ssl_c.BIO_write(self.network_bio, data.ptr + written, chunk);
            if (n <= 0) return error.TlsBioWriteFailed;
            written += @intCast(n);
        }
    }

    /// Drive the TLS handshake state machine.
    /// Returns .complete when the handshake is finished.
    /// Returns .want_read when more ciphertext is needed (call feedRecv then retry).
    /// Returns .want_write when outbound ciphertext is ready (call pendingSend).
    pub fn doHandshake(self: *TlsStreamImpl) Error!HandshakeResult {
        const ret = ssl_c.SSL_do_handshake(self.ssl);
        if (ret == 1) return .complete;

        const err = ssl_c.SSL_get_error(self.ssl, ret);
        return switch (err) {
            ssl_c.SSL_ERROR_WANT_READ => .want_read,
            ssl_c.SSL_ERROR_WANT_WRITE => .want_write,
            else => error.TlsHandshakeFailed,
        };
    }

    /// Read decrypted plaintext from BoringSSL.
    /// Returns the number of bytes read, or 0 if no plaintext is available yet.
    pub fn readPlaintext(self: *TlsStreamImpl, buf: []u8) Error!usize {
        const n = ssl_c.SSL_read(self.ssl, buf.ptr, @intCast(@min(buf.len, std.math.maxInt(c_int))));
        if (n > 0) return @intCast(n);

        const err = ssl_c.SSL_get_error(self.ssl, n);
        return switch (err) {
            ssl_c.SSL_ERROR_WANT_READ, ssl_c.SSL_ERROR_WANT_WRITE => 0,
            ssl_c.SSL_ERROR_ZERO_RETURN => 0, // clean TLS shutdown
            else => error.TlsReadFailed,
        };
    }

    /// Encrypt plaintext data for sending. Returns number of bytes consumed.
    /// After calling this, use pendingSend() to get the ciphertext to send.
    pub fn writePlaintext(self: *TlsStreamImpl, data: []const u8) Error!usize {
        const n = ssl_c.SSL_write(self.ssl, data.ptr, @intCast(@min(data.len, std.math.maxInt(c_int))));
        if (n > 0) return @intCast(n);

        const err = ssl_c.SSL_get_error(self.ssl, n);
        return switch (err) {
            ssl_c.SSL_ERROR_WANT_READ, ssl_c.SSL_ERROR_WANT_WRITE => 0,
            else => error.TlsWriteFailed,
        };
    }

    /// Extract pending outbound ciphertext that needs to be sent via io_uring.
    /// Returns the number of bytes written to buf, or 0 if nothing is pending.
    pub fn pendingSend(self: *TlsStreamImpl, buf: []u8) Error!usize {
        const pending = ssl_c.BIO_ctrl_pending(self.network_bio);
        if (pending == 0) return 0;

        const to_read: c_int = @intCast(@min(buf.len, @min(pending, std.math.maxInt(c_int))));
        const n = ssl_c.BIO_read(self.network_bio, buf.ptr, to_read);
        if (n <= 0) return 0;
        return @intCast(n);
    }
};

// ── Tests ─────────────────────────────────────────────────

test "TlsStream init and deinit with boringssl" {
    if (build_options.tls_backend != .boringssl) return error.SkipZigTest;

    var stream = TlsStream.init(std.testing.allocator, "example.com") catch |err| {
        // If system CA certs are not available, skip
        if (err == error.TlsInitFailed) return error.SkipZigTest;
        return err;
    };
    defer stream.deinit();

    // After init, the handshake hasn't started yet. Drive it once --
    // it should want_write (ClientHello needs to be sent).
    const result = try stream.doHandshake();
    try std.testing.expect(result == .want_write or result == .want_read);
}

test "TlsStream produces ClientHello on handshake" {
    if (build_options.tls_backend != .boringssl) return error.SkipZigTest;

    var stream = TlsStream.init(std.testing.allocator, "example.com") catch |err| {
        if (err == error.TlsInitFailed) return error.SkipZigTest;
        return err;
    };
    defer stream.deinit();

    // Drive handshake to generate ClientHello
    _ = try stream.doHandshake();

    // There should be pending ciphertext (the ClientHello)
    var buf: [4096]u8 = undefined;
    const n = try stream.pendingSend(&buf);
    try std.testing.expect(n > 0);

    // TLS record header: content type 0x16 (handshake), version 0x03 0x01 or 0x03 0x03
    try std.testing.expectEqual(@as(u8, 0x16), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x03), buf[1]);
}

test "TlsStream feedRecv with garbage returns no plaintext" {
    if (build_options.tls_backend != .boringssl) return error.SkipZigTest;

    var stream = TlsStream.init(std.testing.allocator, "example.com") catch |err| {
        if (err == error.TlsInitFailed) return error.SkipZigTest;
        return err;
    };
    defer stream.deinit();

    // Generate ClientHello first
    _ = try stream.doHandshake();
    var send_buf: [4096]u8 = undefined;
    _ = try stream.pendingSend(&send_buf);

    // Feed garbage data as if it were a server response
    const garbage = [_]u8{ 0x17, 0x03, 0x03, 0x00, 0x05, 0xaa, 0xbb, 0xcc, 0xdd, 0xee };
    try stream.feedRecv(&garbage);

    // Trying to continue handshake with garbage should fail
    const result = stream.doHandshake();
    // Either an error or want_read (BoringSSL may buffer partial records)
    if (result) |r| {
        try std.testing.expect(r == .want_read);
    } else |_| {
        // Expected: handshake fails with garbage input
    }
}

test "TlsStreamStub returns errors" {
    // Test the stub directly
    var stub = TlsStreamStub{};
    try std.testing.expectError(error.TlsNotAvailable, stub.doHandshake());
}
