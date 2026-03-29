# Code Review and Optimization Pass

**Date:** 2026-03-29

## Context

Four parallel code reviews were conducted covering thread efficiency, dead code, performance, and testing gaps. The reviews produced a phased improvement plan that was executed across 4 phases.

## Phase 1: Quick Wins

| Change | File | Impact |
|--------|------|--------|
| `@popCount` for bitfield counting | `bitfield.zig` | ~8x faster for `countSetBits` — was iterating per-bit, now per-byte |
| Remove dead `transport.zig` | `net/transport.zig` | 41 lines of unused code removed (direct ring calls replaced it) |
| Remove legacy EventLoop fields | `event_loop.zig` | 5 fields (session, piece_tracker, shared_fds, info_hash, peer_id) duplicated TorrentContext — removed ~200 bytes from struct |
| Fix hardcoded port 6881 | `event_loop.zig` | Re-announce used hardcoded port instead of config value |
| Pre-allocate queued_responses | `event_loop.zig` | ArrayList pre-sized to 256 to avoid hot-path growth |
| Replace sleep drain loop | `torrent_session.zig` | `sleep(10ms)` replaced with `submitTimeout` + `tick` — stays on io_uring instead of blocking |

## Phase 2: High Impact

### Inline message buffer (`event_loop.zig`)
Most peer messages are tiny (choke=1 byte, have=5 bytes). Added a 16-byte inline buffer to the Peer struct. Messages ≤16 bytes use the inline buffer; larger ones (bitfield, piece data) still heap-allocate. Eliminates ~90% of per-message allocations.

### Peer wire protocol tests (`peer_wire.zig`)
Added 19 unit tests covering handshake roundtrip, all message types (choke, unchoke, interested, have, bitfield, request, piece, keepalive), and edge cases. Refactored write functions to expose pure serialization helpers that don't require io_uring.

### Bencode fuzz tests (`bencode.zig`, `http.zig`)
- Bencode: fuzz test with 20-entry seed corpus + 14 deterministic edge cases (empty input, all 256 byte values, deep nesting, integer overflow, truncated input)
- HTTP: fuzz tests for `findBodyStart`, `parseContentLength`, `parseStatusCode`, `parseUrl` + edge cases

## Phase 3: Performance

### Download/upload speed tracking
- `SpeedStats` computed per-torrent every 2 seconds from peer byte counters
- API now returns real speeds instead of zeros
- `handleTransferInfo` aggregates across all sessions

### Idle peers list (`event_loop.zig`)
`tryAssignPieces` scanned all 4096 peer slots every tick. Now maintains an `idle_peers: ArrayList(u16)` of peers needing piece assignment. Updated at all transition points (unchoke, bitfield, piece complete, disconnect). Complexity: O(k) where k = idle peers, typically <50.

### HashMap for pending_writes (`event_loop.zig`)
`handleDiskWrite` did linear scan of `pending_writes` for every disk write CQE. Replaced `ArrayList(PendingWrite)` with `AutoHashMapUnmanaged(PendingWriteKey, PendingWrite)` keyed by `(piece_index, torrent_id)`. O(1) lookup.

## Phase 4: Algorithm + Quality

### claimPiece optimization (`piece_tracker.zig`)
Added `scan_hint` (lowest unclaimed index) and `min_availability` tracking. Scan starts from `scan_hint` instead of 0 and exits early when finding a piece at `min_availability`. As download progresses, the scan range shrinks to just the unclaimed tail.

### Error logging (`event_loop.zig`)
Added `std.log.scoped(.event_loop)` with targeted `log.warn` for serious failures (ring submit, accept, disk I/O) and `log.debug` for less critical paths. Left disconnect/cleanup paths silent (expected errors).

## Key Lessons

### 1. O(max_peers) scans add up
With 4096 max peer slots, `tryAssignPieces` and `checkPeerTimeouts` both iterated the full array every tick. The idle peers list reduced assignment from O(4096) to O(k). Timeout checking still scans all peers but runs less frequently.

### 2. Hot-path allocations compound
The per-message `alloc(u8, msg_len)` in handleRecv was called for every peer message — including 1-byte choke/unchoke messages. The 16-byte inline buffer eliminates heap allocations for ~90% of messages.

### 3. Silent `catch {}` hides bugs
65+ instances of `catch {}` in the event loop silently swallowed errors. Adding logging to the important ones (ring submit, disk I/O, accept) immediately revealed failure patterns during testing that would have been invisible otherwise.

### 4. Drain+clear is an antipattern
This lesson appeared independently in both the code review (as a design smell) and the corruption investigation (as a real bug). Atomic swap is always safer for producer-consumer queues.
