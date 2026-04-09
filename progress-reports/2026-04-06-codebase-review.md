# Codebase Modularization & Redundancy Review

**Date:** 2026-04-06
**Scope:** Read-only review of all `src/` Zig sources (~50,900 lines across 95 files)

---

## 1. File Size Audit

Total codebase: **50,915 lines** in 95 `.zig` files under `src/`.

### Files over 500 lines (sorted by size)

| File | Lines | Prod lines (est.) | Test lines (est.) |
|------|------:|-------------------:|-------------------:|
| `src/io/event_loop.zig` | 2,525 | 2,340 | 185 |
| `src/crypto/mse.zig` | 2,345 | 1,575 | 770 |
| `src/rpc/handlers.zig` | 2,256 | 1,863 | 393 |
| `src/perf/workloads.zig` | 2,018 | 2,018 | 0 |
| `src/storage/resume.zig` | 1,777 | ~1,500 | ~277 |
| `src/daemon/torrent_session.zig` | 1,767 | 1,617 | 150 |
| `src/daemon/session_manager.zig` | 1,747 | 1,601 | 146 |
| `src/io/protocol.zig` | 1,611 | 909 | 702 |
| `src/net/utp.zig` | 1,356 | ~1,000 | ~356 |
| `src/io/peer_policy.zig` | 1,270 | 873 | 397 |
| `src/crypto/sha1.zig` | 1,004 | ~800 | ~204 |
| `src/dht/dht.zig` | 987 | ~800 | ~187 |
| `src/io/peer_handler.zig` | 909 | ~750 | ~159 |
| `src/net/ban_list.zig` | 878 | ~600 | ~278 |
| `src/torrent/merkle_cache.zig` | 855 | ~650 | ~205 |
| `src/daemon/tracker_executor.zig` | 853 | ~800 | ~53 |
| `src/torrent/piece_tracker.zig` | 848 | ~600 | ~248 |
| `src/rpc/server.zig` | 837 | ~700 | ~137 |
| `src/net/metadata_fetch.zig` | 799 | ~700 | ~99 |
| `src/io/http.zig` | 782 | ~650 | ~132 |
| `src/dht/krpc.zig` | 782 | ~500 | ~282 |
| `src/io/utp_handler.zig` | 703 | ~650 | ~53 |
| `src/net/web_seed.zig` | 695 | ~600 | ~95 |
| `src/io/dns_threadpool.zig` | 659 | ~500 | ~159 |
| `src/net/pex.zig` | 650 | ~450 | ~200 |
| `src/io/hasher.zig` | 650 | ~450 | ~200 |
| `src/ctl/main.zig` | 638 | ~600 | ~38 |
| `src/torrent/metainfo.zig` | 624 | ~400 | ~224 |
| `src/net/ut_metadata.zig` | 596 | ~450 | ~146 |
| `src/tracker/announce.zig` | 589 | ~400 | ~189 |
| `src/io/dns_cares.zig` | 583 | ~500 | ~83 |
| `src/net/extensions.zig` | 582 | ~400 | ~182 |
| `src/torrent/layout.zig` | 581 | ~400 | ~181 |
| `src/storage/verify.zig` | 579 | ~450 | ~129 |
| `src/net/peer_wire.zig` | 568 | ~350 | ~218 |
| `src/net/utp_manager.zig` | 527 | ~400 | ~127 |
| `src/torrent/bencode.zig` | 507 | ~300 | ~207 |
| `src/main.zig` | 502 | ~500 | ~2 |

### Directory totals

| Directory | Lines | Notes |
|-----------|------:|-------|
| `src/io/` | 11,363 | Largest subsystem by far |
| `src/net/` | 7,977 | Protocol codecs, extensions |
| `src/torrent/` | 5,471 | Metadata, layout, piece tracking |
| `src/daemon/` | 5,263 | Session/torrent management |
| `src/rpc/` | 4,512 | API server + handlers |
| `src/crypto/` | 3,811 | MSE, SHA1, RC4 |
| `src/dht/` | 3,370 | Distributed hash table |
| `src/storage/` | 3,288 | Resume DB, disk writes |
| `src/perf/` | 2,238 | Benchmarks |
| `src/tracker/` | 1,462 | Tracker client |

---

## 2. Top 10 Modularization Opportunities

### 1. Extract `EventLoop` data types into `src/io/types.zig` (HIGH IMPACT)

**File:** `src/io/event_loop.zig` (2,525 lines)

The `EventLoop` struct is a massive monolith. Lines 38-651 define ~15 nested types (`OpData`, `Peer`, `PeerState`, `TorrentContext`, `SpeedStats`, `PieceBuffer`, `PieceBufferPool`, `VectoredSendState`, `VectoredSendPool`, `PendingSend`, `SmallSendPool`, `UtpQueuedPacket`, `QueuedBlockResponse`, `PendingPieceRead`) and standalone types before the `EventLoop` struct itself begins at line 255. These types are referenced by every `src/io/*.zig` sub-module.

**Suggested split:**
- Extract `Peer`, `PeerState`, `PeerMode`, `Transport`, `OpData`, `OpType`, `encodeUserData`, `decodeUserData` into `src/io/types.zig`.
- Extract `PieceBufferPool`, `VectoredSendPool`, `SmallSendPool` into `src/io/buffer_pools.zig` -- these are self-contained allocator wrappers with their own tests.
- `TorrentContext`, `SpeedStats` into `src/io/torrent_context.zig`.

**Impact:** Reduces event_loop.zig by ~600 lines and makes the data model importable without pulling in the entire EventLoop + io_uring dependency.

### 2. Deduplicate torrent JSON serialization (HIGH IMPACT)

**Files:**
- `src/rpc/handlers.zig:1692` -- `serializeTorrentInfo()`
- `src/rpc/sync.zig:235` -- `serializeTorrentObject()`

These two functions are **nearly character-for-character identical** (~80 lines each). Both:
- Compute `qbt_state`, `time_active`, `amount_left`, `completion_on`
- Build `content_path` and `magnet_uri` via `compat.*`
- Emit the same two `json.print()` calls with identical format strings and field lists
- The only difference: `sync.zig:289` omits the `"partial_seed"` field

**Suggested fix:** Move the shared serialization into `src/rpc/compat.zig` (which already holds `torrentStateString`, `buildContentPath`, `buildMagnetUri`). Both `handlers.zig` and `sync.zig` import it. One function, one format string.

### 3. Extract `transferInfo` computation (MEDIUM IMPACT)

**Files:**
- `src/rpc/handlers.zig:155-178` -- `handleTransferInfo()`
- `src/rpc/sync.zig:52-72` -- inside `computeDelta()`

Both sum `total_dl_speed`, `total_ul_speed`, `total_dl_data`, `total_ul_data` across all stats, then query `el.getGlobalDlLimit()`, `el.getGlobalUlLimit()`, `el.getDhtNodeCount()`. The code is duplicated line-for-line.

**Suggested fix:** A `computeTransferTotals(stats, event_loop)` helper in `src/rpc/compat.zig`.

### 4. Split `rpc/handlers.zig` by endpoint group (MEDIUM IMPACT)

**File:** `src/rpc/handlers.zig` (2,256 lines, 1,863 prod)

The `ApiHandler` struct contains ~35 handler methods, ~4 JSON extractors, ~1 serialization function, and ~500 lines of tests. The main `handle()` method (lines 40-124) is an `if`-chain that dispatches on path strings.

**Suggested split:**
- `src/rpc/torrent_handlers.zig` -- all `handleTorrents*()` methods (~800 lines)
- `src/rpc/transfer_handlers.zig` -- transfer info, ban management, speed limits (~200 lines)
- `src/rpc/category_handlers.zig` -- categories and tags (~200 lines)
- Keep `handle()` dispatch, auth, and preferences in `handlers.zig`

This also eliminates the 64 occurrences of `.status = 500, .body = "{\"error\":\"internal\"}"` scattered through the file -- a shared `internalError()` helper could be used.

### 5. Consolidate socket configuration (LOW-MEDIUM IMPACT)

**Files:**
- `src/io/event_loop.zig:1356-1365` -- outbound TCP sockets
- `src/io/peer_handler.zig:79-82` -- inbound accepted sockets
- `src/net/socket.zig:75` -- exists but only has `applyBindConfig/applyBindDevice`

Both locations set TCP_NODELAY, SO_RCVBUF (2MB), SO_SNDBUF (512KB) on peer sockets with identical code:
```zig
posix.setsockopt(fd, posix.IPPROTO.TCP, linux.TCP.NODELAY, &std.mem.toBytes(@as(c_int, 1))) catch {};
posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVBUF, &std.mem.toBytes(@as(c_int, 2 * 1024 * 1024))) catch {};
posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.SNDBUF, &std.mem.toBytes(@as(c_int, 512 * 1024))) catch {};
```

**Suggested fix:** Add `configurePeerSocket(fd)` to `src/net/socket.zig`.

### 6. Consolidate JSON extraction utilities (LOW-MEDIUM IMPACT)

**File:** `src/rpc/handlers.zig:1775-1862`

`extractParam`, `extractJsonInt`, `extractJsonBool`, `extractJsonFloat` are general-purpose utilities embedded in the handler file. They have no dependency on `ApiHandler`. The three `extractJson*` functions share an identical needle-building preamble (~8 lines each, 24 lines total of copy-paste).

**Suggested fix:**
- Move to `src/rpc/params.zig`
- Factor out the shared `buildJsonNeedle()` helper

### 7. Extract `initBare()` / `init()` shared initialization (LOW IMPACT)

**File:** `src/io/event_loop.zig:796-871`

`initBare()` and `init()` contain 20+ identical field initializations (the struct literal). `init()` calls `initBare()` conceptually but is actually a separate copy that adds one `addTorrent` call.

**Suggested fix:** Have `init()` call `initBare()` then `addTorrent()`.

### 8. Unify `peer_id` modules (LOW IMPACT)

**Files:**
- `src/torrent/peer_id.zig` (273 lines) -- peer ID generation + masquerading
- `src/net/peer_id.zig` (246 lines) -- peer ID to client name parsing

These are logically one concern: peer identity. Both are small, but having them split across `src/torrent/` and `src/net/` obscures the relationship.

**Suggested fix:** Merge into `src/net/peer_id.zig` (which handles both generation and parsing), or move both under a `src/peer/` directory.

### 9. Extract `PieceBufferPool` and `VectoredSendPool` (MEDIUM IMPACT)

**File:** `src/io/event_loop.zig:283-556`

These are self-contained, allocation-heavy data structures (~270 lines combined) with their own internal freelists, size classes, and retention policies. They have no dependency on the event loop or io_uring -- they're pure allocator wrappers.

**Suggested fix:** `src/io/buffer_pools.zig`. This also makes them independently testable.

### 10. Factor out error response pattern in handlers (LOW IMPACT)

**File:** `src/rpc/handlers.zig`

The pattern:
```zig
const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
    return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
return .{ .status = <code>, .body = msg, .owned_body = msg };
```
appears **26+ times** with only the status code varying (400, 404, 409, 500).

**Suggested fix:** A `fn errorResponse(allocator, status, err)` helper.

---

## 3. Redundancy Instances

### 3.1 Torrent JSON serialization (EXACT DUPLICATE)

- `src/rpc/handlers.zig:1692-1769` (`serializeTorrentInfo`)
- `src/rpc/sync.zig:235-311` (`serializeTorrentObject`)

~77 lines of format strings and argument lists are identical. The sync version only omits the `partial_seed` field (an easy parameterization).

### 3.2 Transfer info aggregation (NEAR DUPLICATE)

- `src/rpc/handlers.zig:155-178` -- loops over stats, sums speeds/bytes, queries event loop limits
- `src/rpc/sync.zig:52-72` -- identical loop, same variables, same event loop queries

### 3.3 Socket configuration (EXACT DUPLICATE)

- `src/io/event_loop.zig:1356-1362` (outbound)
- `src/io/peer_handler.zig:79-82` (inbound)

Three identical `setsockopt` calls.

### 3.4 Error response boilerplate in handlers (PATTERN DUPLICATE)

- `src/rpc/handlers.zig` -- 26+ occurrences of the `allocPrint("{{\"error\":\"{s}\"}}", @errorName(err))` pattern
- 64 occurrences of `.status = 500, .body = "{\"error\":\"internal\"}"` fallback

### 3.5 JSON extraction needle building (STRUCTURAL DUPLICATE)

- `src/rpc/handlers.zig:1788-1812` (`extractJsonInt`)
- `src/rpc/handlers.zig:1817-1836` (`extractJsonBool`)
- `src/rpc/handlers.zig:1840-1862` (`extractJsonFloat`)

Each builds the same `"key":` needle with an identical 8-line preamble.

### 3.6 EventLoop init struct literals (NEAR DUPLICATE)

- `src/io/event_loop.zig:805-825` (`initBare`)
- `src/io/event_loop.zig:845-865` (`init`)

20+ identical field initializations. `init` should call `initBare`.

### 3.7 `hash`/`hashes` parameter extraction pattern

- `src/rpc/handlers.zig` -- 13 handler methods start with `extractParam(body, "hashes")` or `extractParam(body, "hash")` followed by the same 400-error return. A `requireHash(body)` helper would eliminate this repetition.

---

## 4. Module Coupling Issues

### 4.1 `src/io/` is a mega-module (11,363 lines)

The `io/` directory conflates three concerns:
- **io_uring event loop** (`event_loop.zig`, `ring.zig`, `signal.zig`)
- **BitTorrent peer protocol** (`peer_handler.zig`, `protocol.zig`, `seed_handler.zig`, `peer_policy.zig`)
- **Transport layers** (`utp_handler.zig`, `dht_handler.zig`, `http.zig`, `dns*.zig`, `tls.zig`, `hasher.zig`)

The peer protocol files (`protocol.zig`, `peer_policy.zig`) import heavily from both `../net/` and `../torrent/`, creating a web of cross-dependencies:
- `src/io/protocol.zig` imports 5 modules from `src/net/` and 3 from `src/torrent/`
- `src/io/peer_policy.zig` imports from `src/net/pex.zig`, `src/torrent/merkle_cache.zig`, `src/torrent/layout.zig`
- `src/io/event_loop.zig` imports from `src/net/` (7 modules) and `src/torrent/` (3 modules)

This means adding a new BEP extension requires touching `io/` internals.

### 4.2 `rpc/handlers.zig` reaches through `SessionManager` to `EventLoop`

Lines 171-174 in `handlers.zig`:
```zig
const el = self.session_manager.shared_event_loop;
const dl_limit: u64 = if (el) |e| e.getGlobalDlLimit() else 0;
const ul_limit: u64 = if (el) |e| e.getGlobalUlLimit() else 0;
const dht_nodes: usize = if (el) |e| e.getDhtNodeCount() else 0;
```
The API handler accesses the EventLoop directly through SessionManager's internal pointer. This pattern repeats at lines 580, 1509, 1635.

**Better boundary:** SessionManager should expose `getGlobalLimits()` and `getDhtNodeCount()` methods that hide the EventLoop dependency.

### 4.3 `daemon/session_manager.zig` directly iterates `EventLoop.peers`

Line 1526 in `session_manager.zig`:
```zig
for (el.peers) |*peer| {
    if (peer.state == .free) continue;
```
`getTorrentPeers()` reads raw Peer structs, checking `.state`, `.peer_choking`, `.am_choking`, `.transport`, `.crypto`, `.extensions_supported`, etc. This is a layering violation -- the session manager knows intimate details of peer wire state.

**Better boundary:** EventLoop should expose a `getPeersForTorrent(torrent_id)` method returning a summary struct.

### 4.4 Bidirectional dependency: `daemon/` and `io/`

- `daemon/torrent_session.zig` imports `io/event_loop.zig` (the `EventLoop` type, `TorrentId`)
- `io/event_loop.zig` imports `torrent/session.zig` and `torrent/piece_tracker.zig`
- `rpc/server.zig` imports both `io/ring.zig` and `io/event_loop.zig`

This creates a diamond dependency pattern where `daemon` and `rpc` both depend on `io`, and `io` depends on `torrent`. Not circular per se, but tightly coupled.

---

## 5. Quick Wins (Low Effort, Immediate Benefit)

### 5.1 Deduplicate `serializeTorrentInfo` / `serializeTorrentObject`

Move the shared serialization to `src/rpc/compat.zig`. Both call sites become one-liners. Eliminates ~77 lines of duplication. Prevents future drift (e.g., one adds a field and the other doesn't).

### 5.2 Add `fn errorResponse(allocator, status, err) Response` to handlers

Replaces 26+ copies of the same 3-line error pattern. Reduces `handlers.zig` by ~52 lines.

### 5.3 Add `fn configurePeerSocket(fd)` to `socket.zig`

Centralizes the TCP_NODELAY + buffer size configuration. Two call sites become one-liners.

### 5.4 Have `EventLoop.init()` call `initBare()`

Replace the duplicate 20-field struct literal with a call to `initBare()` followed by `addTorrent()`. Eliminates ~20 lines of duplication and prevents them from drifting.

### 5.5 Move `extractParam`, `extractJson*` to `src/rpc/params.zig`

Pure utility functions with no handler dependency. Makes them independently testable and reusable.

### 5.6 Factor `requireHash(body)` helper

Eliminates 13 copies of the `extractParam(body, "hashes") orelse return .{ .status = 400 ... }` pattern.

---

## 6. Larger Refactors (Higher Effort, Worth Considering)

### 6.1 Split `src/io/` into `src/io/` + `src/peer/`

The current `io/` directory mixes io_uring mechanics with BitTorrent protocol logic. A cleaner split:
- `src/io/` -- event loop, ring, signal, buffer pools, rate limiter (pure I/O infrastructure)
- `src/peer/` -- peer_handler, protocol, seed_handler, peer_policy (BT peer wire logic)

This would make it clear that adding a new BEP extension means touching `src/peer/` or `src/net/`, not `src/io/`.

**Effort:** Medium. The `peer_handler.zig`, `protocol.zig`, `seed_handler.zig`, `peer_policy.zig` files already operate on `*EventLoop` as a parameter rather than being methods on EventLoop, so the move is mostly import path changes.

### 6.2 Extract EventLoop type definitions into `src/io/types.zig`

Move `Peer`, `PeerState`, `PeerMode`, `Transport`, `TorrentContext`, `SpeedStats`, `OpData`, `OpType` into a shared types module. Currently every sub-handler does:
```zig
const Peer = @import("event_loop.zig").Peer;
const PeerState = @import("event_loop.zig").PeerState;
const TorrentContext = @import("event_loop.zig").TorrentContext;
const encodeUserData = @import("event_loop.zig").encodeUserData;
```
This forces them to depend on the 2,525-line event_loop module for a handful of type definitions.

**Effort:** Low-medium. Mechanical move of struct definitions and import path updates.

### 6.3 Introduce a `SessionManager.getTransferInfo()` method

Currently `handlers.zig` and `sync.zig` both manually iterate stats and query the event loop. A `getTransferInfo()` on `SessionManager` that returns a `TransferInfo` struct would:
- Eliminate the transfer-info duplication
- Hide the `shared_event_loop` pointer from RPC callers
- Reduce coupling between `rpc/` and `io/`

### 6.4 Split `rpc/handlers.zig` by endpoint group

At 2,256 lines with 35+ handler methods, this file benefits from splitting by API section:
- Torrent CRUD operations (~800 lines)
- Transfer/ban management (~250 lines)
- Category/tag management (~300 lines)
- Queue management (~100 lines)

Each group has its own imports and test blocks. The dispatch `handle()` method stays in the main file.

### 6.5 Extract `crypto/mse.zig` big-integer arithmetic

Lines 62-400 of `mse.zig` implement `U768` -- a complete 768-bit modular arithmetic library (add, subtract, multiply, modPow, modular reduction). This is ~340 lines of pure math with no MSE/BEP-6 dependency.

If the project ever needs big-integer arithmetic elsewhere (DHT node distance calculations already use a simpler version in `dht/node_id.zig`), this should be its own `src/crypto/bigint.zig`.

---

## Summary

The codebase is well-organized for its size, with sensible subsystem boundaries. The main areas for improvement are:

1. **`src/io/event_loop.zig`** at 2,525 lines is the single biggest target. It hosts ~600 lines of type definitions and ~270 lines of buffer pool implementations that have no io_uring dependency and should be extracted.

2. **`src/rpc/handlers.zig`** at 2,256 lines has extensive boilerplate repetition (error responses, hash extraction, JSON serialization) that can be factored into helpers.

3. **The torrent JSON serialization duplication** between `handlers.zig` and `sync.zig` is the highest-value fix -- it's an exact copy of ~77 lines that will inevitably drift.

4. **The `src/io/` directory** at 11,363 lines conflates I/O infrastructure with BitTorrent protocol logic. A `src/peer/` extraction would clarify the architecture.

5. **Cross-module coupling** is manageable but the `rpc/` -> `SessionManager` -> `EventLoop` chain exposes internal state unnecessarily. A few facade methods on `SessionManager` would tighten the boundary.
