# Varuna Codebase Review Results

Comprehensive review across security, performance, protocol correctness,
code organization, robustness, and testing coverage.

---

## Critical (must fix)

| # | Finding | Area | File(s) |
|---|---------|------|---------|
| 1 | **u32 overflow in `block_offset + block_length`** — wraps to small value, bypasses bounds check on seed requests | Security | `seed_handler.zig:198` |
| 2 | **No max `block_length` on incoming REQUESTs** — peer can request entire multi-MB piece, causing huge alloc + send | Security / DoS | `seed_handler.zig:180-198` |
| 3 | **Disk write error frees buffer while other spans still in-flight** — use-after-free from io_uring reading freed memory | Memory Safety | `peer_handler.zig:574-584` |
| 4 | **Availability counters never decremented on disconnect** — `removeBitfieldAvailability()` exists but is never called; rarest-first degrades over time as counters only increase | Correctness | `event_loop.zig:removePeer` / `piece_tracker.zig:149` |
| 5 | **Background announce thread accesses EventLoop after deinit** — thread is detached, not joined; shutdown can free memory the thread is still using | Memory Safety | `peer_policy.zig:674-716` |
| 6 | **CANCEL message (id=8) completely ignored** — never handled on receive, never sent; wastes bandwidth during endgame, poor swarm citizenship | Protocol | `protocol.zig` |
| 7 | **No TCP_NODELAY on peer sockets** — Nagle's algorithm delays small refill sends by up to 40ms; every mainstream BT client sets this | Performance | `event_loop.zig:1299` / `peer_handler.zig:69` |

---

## High (should fix soon)

| # | Finding | Area | File(s) |
|---|---------|------|---------|
| 8 | **Bencode parser: no recursion depth limit** — deeply nested input from tracker or ut_metadata can stack-exhaust the event loop thread | Security / DoS | `bencode.zig:53-155` |
| 9 | **Bencode parser: unbounded element allocation** — millions of tiny entries cause huge allocator pressure | Security / DoS | `bencode.zig:103-155` |
| 10 | **Race condition on announce_result_peers** — non-atomic pointer/length written by bg thread, read by event loop; works on x86 by accident, breaks on ARM | Memory Safety | `peer_policy.zig:610-714` |
| 11 | **`send_pending` serializes pipeline refill** — blocks `tryFillPipeline` when kernel hasn't ACK'd prior send; existing PendingSend system supports multiple in-flight sends | Performance | `peer_policy.zig:101` |
| 12 | **`completePiece` never clears `in_progress` bit** — causes `scan_hint` to skip eligible pieces and endgame to trigger prematurely | Correctness | `piece_tracker.zig:286-297` |
| 13 | **Choking algorithm only covers seed mode** — download-mode peers never get tit-for-tat unchoking; no optimistic unchoke rotation; interval is 30s vs spec's 10s | Protocol | `peer_policy.zig:549-604` |
| 14 | **No outbound keep-alive messages** — remote peers may disconnect us for inactivity; `writeKeepAlive` exists but is never called | Protocol | event loop tick |
| 15 | **io_uring ring created without optimization flags** — `COOP_TASKRUN`, `SINGLE_ISSUER`, `DEFER_TASKRUN` would reduce per-syscall overhead 5-15% | Performance | `event_loop.zig:795,835` |
| 16 | **Shutdown does not flush pending disk writes** — verified pieces with in-flight writes are lost; re-download required on restart | Robustness | `event_loop.zig:deinit` |

---

## Medium (should fix)

| # | Finding | Area | File(s) |
|---|---------|------|---------|
| 17 | **BITFIELD not validated** — no length check, no spare-bits check, no ordering enforcement (must come right after handshake) | Protocol | `protocol.zig:100-112` |
| 18 | **No per-peer request flood protection** — malicious unchoked peer can flood unlimited REQUESTs, each triggering disk I/O + alloc | Robustness | `protocol.zig:113` / `seed_handler.zig:180` |
| 19 | **Per-block heap allocation** — every 16KB PIECE message body allocates then frees; could recv directly into piece_buf | Performance | `peer_handler.zig:522-532` |
| 20 | **Triple `io_uring_enter` per tick** — first `submit()` is redundant before `submit_and_wait(1)` | Performance | `event_loop.zig:1523-1542` |
| 21 | **MSE byte-at-a-time VC scan** — async initiator reads 1 byte + creates fresh RC4 per iteration; amplification vector with large PadB | Security / Perf | `mse.zig:1055-1081` |
| 22 | **`looksLikeMse` too permissive** — any non-0x13 byte triggers expensive DH key gen; port scanners cause alloc + crypto overhead | Security / DoS | `mse.zig:1552-1556` |
| 23 | **DHT `addressEql` ignores IPv6** — reads `.in.sa.addr` on IPv6 address (UB) | Correctness | `dht_handler.zig:90-92` |
| 24 | **UDP tracker: no retry/timeout per BEP 15** — single send/recv, lost packet = permanent failure | Protocol | `tracker/udp.zig` |
| 25 | **Piece buffer pool not used for downloads** — `startPieceDownload` uses raw allocator while seed path uses the pool with huge page + retention | Performance | `peer_policy.zig:88` |
| 26 | **`pipeline_depth` config value ignored** — `Config.Performance.pipeline_depth` defaults to 5, actual constant hardcoded to 64 | Organization | `config.zig:75` / `peer_policy.zig:18` |
| 27 | **`submit_and_wait(1)` can block forever** — if no SQEs queued and timeout submission failed, ignores SIGINT/SIGTERM | Robustness | `event_loop.zig:1527` |

---

## Low / Suggestions

| # | Finding | Area |
|---|---------|------|
| 28 | **`wantedRemaining()` is O(piece_count) per tick** — maintain a counter instead of scanning | Performance |
| 29 | **Hasher queue uses O(n) `orderedRemove(0)`** — use `swapRemove` (one-line fix) | Performance |
| 30 | **Handshake construction duplicated 4 times** — extract `buildHandshake()` helper | Organization |
| 31 | **Encrypt-track-send pattern repeated 8+ times** — extract `submitTrackedSend()` | Organization |
| 32 | **Piece failure cleanup repeated 5 times in `completePieceDownload`** — extract helper | Organization |
| 33 | **`init`/`initBare` duplicate 30-line struct literal** — have `init` call `initBare` | Organization |
| 34 | **event_loop.zig at 2399 lines** — extract `PieceBufferPool`, `VectoredSendPool`, `SmallSendPool` | Organization |
| 35 | **Inline `@import` inside function bodies** — move to top-level for visibility | Style |
| 36 | **No anti-snubbing mechanism** — snubbed peers waste unchoke slots | Protocol |
| 37 | **Immediate unchoke on INTERESTED bypasses `max_unchoked`** — many peers connecting at once exceed limit | Protocol |
| 38 | **Unknown message IDs silently dropped** — at minimum log at debug level; PORT (id=9) needed for DHT | Protocol |
| 39 | **`allocSlot` is O(max_peers) scan** — use a free-slot stack | Performance |
| 40 | **`checkPeerTimeouts` allocates ArrayList every tick** — use stack buffer | Performance |

---

## Testing Gaps (most impactful)

| Priority | Gap |
|----------|-----|
| **#1** | `protocol.zig` — 838 lines, 0 tests. Processes all untrusted peer messages. |
| **#2** | `peer_policy.zig` — 895 lines, 0 tests. Choking algorithm, piece assignment. |
| **#3** | No test for piece hash failure -> re-download flow end-to-end. |
| **#4** | `rpc/handlers.zig` — 1870 lines, 4 trivial tests. The entire WebAPI surface. |
| **#5** | Adversarial tests check constants, not actual message injection through handlers. |
| **#6** | No resume-after-restart integration test (SQLite persistence tested at DB layer only). |
| **#7** | `peer_handler.zig` — 897 lines, 1 test. CQE dispatch, connection lifecycle. |
