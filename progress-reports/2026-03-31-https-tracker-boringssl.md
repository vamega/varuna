# HTTPS Tracker Support via BoringSSL

**Date**: 2026-03-31

## What was done

Added HTTPS tracker support using vendored BoringSSL, built entirely with Zig's build system (no cmake/ninja required).

### Phase 1: Build Integration
- Added BoringSSL as a git submodule at `vendor/boringssl` (pinned to commit 992dfa0).
- Copied `build/boringssl.zig` from the reference worktree -- this reads `gen/sources.json` and compiles bcm, crypto, and ssl as static libraries.
- Integrated into `build.zig` with a `-Dtls=boringssl|none` build option (default: boringssl).
- All three BoringSSL libraries (bcm, crypto, ssl) are linked into the varuna module.

### Phase 2: TLS Client (`src/io/tls.zig`)
- `TlsStream` wraps BoringSSL's SSL_CTX/SSL/BIO via `@cImport`.
- Uses `BIO_new_bio_pair()` to decouple BoringSSL from socket I/O.
- Interface: `feedRecv()` pushes received ciphertext into the BIO read side, `pendingSend()` extracts outbound ciphertext from the BIO write side, `readPlaintext()`/`writePlaintext()` handle the application data.
- `doHandshake()` drives the TLS handshake state machine, returning `want_read`/`want_write`/`complete`.
- SNI hostname set via `SSL_set_tlsext_host_name`.
- System CA certificates loaded via `SSL_CTX_set_default_verify_paths`.
- Server certificate verification enabled (`SSL_VERIFY_PEER`).
- Conditional compilation: `TlsStreamStub` used when `tls_backend == .none`.

### Phase 3: HTTPS HTTP Client
- `parseUrl` now recognizes `https://` and sets `is_https=true` with default port 443.
- `getHttps()` method: TCP connect via io_uring, TLS handshake driven via io_uring send/recv, HTTP request/response tunneled through TlsStream.
- `tlsHandshake()`: loops doHandshake/pendingSend/feedRecv until complete, with max iteration guard.
- `tlsSendAll()`: encrypts plaintext and flushes ciphertext via io_uring.
- `tlsRecvResponse()`: receives ciphertext via io_uring, feeds to TLS, reads decrypted plaintext.
- Existing HTTP parser (findBodyStart, parseContentLength, parseStatusCode) reused unchanged.
- Tracker announce path (`fetchViaRing` in `src/tracker/announce.zig`) works unchanged -- it calls `http_client.get(url)` which now handles both HTTP and HTTPS.

## Key design decisions

1. **BIO pairs instead of custom BIO methods**: Simpler to implement and well-tested in BoringSSL. The small overhead of an extra memcpy through the BIO pair buffer is negligible for tracker announces (small payloads, infrequent).

2. **All network I/O stays on io_uring**: BoringSSL never touches sockets. The TlsStream acts as a pure crypto/protocol processor. This satisfies the io_uring policy for the daemon.

3. **Build-time TLS toggle**: `-Dtls=none` compiles without BoringSSL at all (faster builds for development). The stub returns `error.TlsNotAvailable` for any TLS operation.

## What was learned

- BoringSSL's `BIO_free` returns `c_int` (not void), and Zig requires the return value to be explicitly discarded with `_ =`.
- The `gen/sources.json` already exists in the BoringSSL repo at commit 992dfa0, so no generation step is needed.
- The pure Zig build of BoringSSL compiles bcm+crypto+ssl from the source list with platform-specific assembly selection for x86_64/aarch64 Linux.

## Tests

- `TlsStream init and deinit with boringssl`: verifies SSL_CTX/SSL/BIO creation and cleanup.
- `TlsStream produces ClientHello on handshake`: verifies that driving the handshake produces a valid TLS record (content type 0x16, version 0x03).
- `TlsStream feedRecv with garbage returns no plaintext`: verifies graceful handling of invalid ciphertext.
- `TlsStreamStub returns errors`: verifies the no-TLS stub.
- 3 new HTTPS URL parsing tests (default port 443, explicit port, is_https flag).

## Code references

- `build/boringssl.zig` -- pure Zig build for BoringSSL static libraries
- `build.zig:28-30` -- `-Dtls` build option
- `build.zig:82-93` -- BoringSSL library linking
- `src/io/tls.zig` -- TlsStream implementation
- HTTPS GET implementation in the former HTTP client module
- TLS handshake driver in the former HTTP client module
