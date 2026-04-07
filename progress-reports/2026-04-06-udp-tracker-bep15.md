# UDP Tracker Support (BEP 15)

## What was done

Implemented full UDP tracker support (BEP 15) for the varuna BitTorrent client. Many real-world trackers are UDP-only, so this was a significant gap for real-world usability.

### Protocol layer (`src/tracker/udp.zig`)

Rewrote the existing basic UDP tracker file into a comprehensive BEP 15 implementation:

- **Packet encode/decode**: Typed structs for all 4 message types: `ConnectRequest`/`ConnectResponse`, `AnnounceRequest`/`AnnounceResponse`, `ScrapeRequest`/`ScrapeResponse`, `ErrorResponse`. Each with `.encode()` and `.decode()` methods.
- **Connection ID caching**: `ConnectionCache` struct with per-host/port entries, 2-minute TTL (per BEP 15), LRU eviction when full (32 entries max). Shared across announces to the same tracker.
- **Retransmission**: `retransmitTimeout(attempt)` calculates BEP 15 exponential backoff: 15 * 2^n seconds, clamped at n=8 (3840 seconds max).
- **Error handling**: `isErrorResponse()`, `parseErrorMessage()`, `responseAction()`, `responseTransactionId()` helpers for inspecting raw response buffers. Stale connection ID detection: on error during announce, invalidates cache and re-connects.
- **Compact peer parsing**: `parseCompactPeers()` (IPv4, 6 bytes each) and `parseCompactPeers6()` (IPv6, 18 bytes each).
- **Blocking client**: `fetchViaUdp()` for announce, `scrapeViaUdp()` for scrape. Used by `varuna-ctl`, multi-announce workers, metadata fetching. Connection ID reuse across calls via global cache.

### io_uring executor (`src/daemon/udp_tracker_executor.zig`)

New async UDP tracker executor for the daemon, following the same pattern as the existing HTTP `TrackerExecutor`:

- **State machine**: `idle -> dns_resolving -> connecting -> announcing/scraping -> done`
- **io_uring I/O**: Uses `IORING_OP_SENDMSG` / `IORING_OP_RECVMSG` on the shared ring. No blocking I/O.
- **DNS offload**: Async DNS resolution via `DnsResolver` with eventfd notification.
- **Retransmission**: Tick-based timeout checking with BEP 15 exponential backoff.
- **Connection ID cache**: Per-executor cache shared across all request slots.
- **Slot-based multiplexing**: Up to 8 concurrent UDP tracker requests.

### Event loop integration

- Added `udp_tracker_send` and `udp_tracker_recv` OpType variants to `src/io/event_loop.zig:OpType`.
- Added `udp_tracker_executor` field to `EventLoop`, ticked every event loop cycle.
- CQE dispatch routes `udp_tracker_send`/`udp_tracker_recv` to the UDP executor.

### Daemon integration (`src/daemon/torrent_session.zig`, `src/daemon/session_manager.zig`)

- `SessionManager` lazily creates `UdpTrackerExecutor` and wires it into the event loop.
- `TorrentSession.scheduleCompletedAnnounce()` and `scheduleReannounce()` auto-detect `udp://` URLs and route them through the UDP executor. HTTP URLs continue through the existing `TrackerExecutor`.
- `TorrentSession.scheduleScrape()` similarly routes UDP scrape requests.
- Completion callbacks parse UDP announce responses and deliver peers to the event loop the same way HTTP announces do.

### Scrape consolidation (`src/tracker/scrape.zig`)

Replaced the duplicated UDP scrape protocol code in `scrape.zig` with a single delegation to `udp.scrapeViaUdp()`. Removed ~70 lines of duplicated connect/scrape logic.

### Tests

- **35+ unit tests** in `src/tracker/udp.zig`: packet encode/decode roundtrips, connection cache operations, retransmission timeout calculation, error response detection, URL parsing, event conversion.
- **Integration tests** in `tests/udp_tracker_test.zig`: Full protocol exchanges over real UDP loopback sockets with mock tracker servers:
  - Connect -> announce flow with peer validation
  - Connect -> scrape flow with stats validation
  - Error response handling
  - Connection ID reuse across multiple announces
  - Packet size verification, retransmission timeout spec compliance

## What was learned

- **BEP 15 event codes differ from HTTP**: HTTP uses string events (`started`, `completed`, `stopped`, no event). UDP uses integer codes where `none=0, completed=1, started=2, stopped=3`. The order is different from HTTP.
- **Connection ID caching is critical**: Without caching, every announce requires two round-trips (connect + announce). With caching, subsequent announces to the same tracker need only one round-trip. The 2-minute TTL is specified by BEP 15.
- **UDP `connect()` is useful for trackers**: Even though UDP is connectionless, calling `posix.connect()` on a UDP socket allows using `send()`/`recv()` instead of `sendto()`/`recvfrom()`, simplifying the code. For the io_uring path, we still use `sendmsg`/`recvmsg` with explicit address.
- **io_uring sendmsg/recvmsg require persistent msghdr**: The `msghdr`/`msghdr_const` structs and their iovec arrays must outlive the SQE submission until the CQE arrives. Storing them in the request slot ensures this.

## Key file references

- `src/tracker/udp.zig` -- Protocol encode/decode, connection cache, blocking client, 35+ tests
- `src/daemon/udp_tracker_executor.zig` -- io_uring-based async UDP tracker executor
- `src/io/event_loop.zig:38-55` -- OpType enum with new `udp_tracker_send`/`udp_tracker_recv`
- `src/io/event_loop.zig:1811-1813` -- CQE dispatch for UDP tracker ops
- `src/daemon/torrent_session.zig:1120-1200` -- UDP announce/scrape routing and completion callbacks
- `src/daemon/session_manager.zig:640-650` -- UdpTrackerExecutor lifecycle management
- `tests/udp_tracker_test.zig` -- Integration tests with mock UDP servers
- `src/tracker/scrape.zig:110-116` -- Scrape delegation to unified UDP implementation

## Remaining work

- **Multi-tracker UDP support**: The current implementation handles the primary announce URL. For announce-list (BEP 12) with mixed HTTP/UDP tiers, the `multi_announce.zig` already uses `fetchAuto()` which dispatches to UDP or HTTP. The daemon path handles the primary URL; multi-tier daemon announces could be extended.
- **IPv6 UDP peers**: The UDP announce response only returns compact IPv4 peers (6 bytes each). BEP 15 doesn't define an IPv6 peer format in announce responses. Some trackers may return IPv6 peers in a non-standard way.
