# Generic HttpExecutor + Synchronous HTTP Retirement

**Date:** 2026-04-16

## What Changed

Extracted a generic non-blocking io_uring HTTP client from the TrackerExecutor
and retired the former synchronous HTTP client from all daemon code paths.

### HttpExecutor (`src/io/http_executor.zig`, ~1011 lines)
- Async HTTP(S) client over io_uring: SOCKET → CONNECT → SEND → RECV
- DNS resolution via threadpool + eventfd
- TLS via BoringSSL BIO pairs
- Connection pooling with keep-alive
- Custom headers (up to 4 per request) — enables Range headers for web seeds
- `target_buf` + `target_offset` for zero-copy body writes into caller's buffer
- Response headers returned to caller for Content-Range inspection

### TrackerExecutor refactored (`src/daemon/tracker_executor.zig`, 880 → 92 lines)
- Thin wrapper over HttpExecutor
- Converts TrackerExecutor.Job → HttpExecutor.Job
- Delegates tick() and dispatchCqe() to HttpExecutor
- Backwards-compatible API for TorrentSession callers

### Synchronous HTTP client retired
- `torrent_session.zig` imports `url.zig` instead of `http.zig`
- `web_seed.zig:downloadPiece` removed (dead code, never called from daemon)
- New `src/io/url.zig` — pure URL parsing, no I/O dependency
- `http.zig` re-exports ParsedUrl/parseUrl for CLI/test backwards compat
- No daemon code path can reach the former synchronous HTTP client

### collectMagnetPeers migrated
- `collectMagnetPeers` replaced with `submitMagnetAnnounces`
- Magnet link tracker announces now go through TrackerExecutor/UdpTrackerExecutor
- Zero blocking network I/O on the background thread
- Last blocking I/O code path in the daemon eliminated

## Key Code References
- `src/io/http_executor.zig` — generic HTTP client
- `src/io/url.zig` — pure URL parser
- `src/daemon/tracker_executor.zig` — thin wrapper (92 lines)
- `src/daemon/torrent_session.zig:submitMagnetAnnounces` — async magnet path
