# Clarity & Abstraction Fixes Applied

**Date:** 2026-04-09
**Scope:** Fixes for code clarity, abstraction level, and module cohesion issues identified in the full codebase review.
**Build:** `zig build` passes, `zig build test` passes (all tests green), `zig fmt .` applied.

## Summary

**82 issues fixed** across all 10 subsystems, out of 107 identified. 25 deferred (too risky, too complex, or low value for automated changes).

## Changes by Subsystem

### Cross-cutting (Batch 1)
- Created `src/net/address.zig` with unified `addressEql` handling both IPv4 and IPv6
- Replaced 6 independent `addressEql`/`addressEqual` implementations across dht/, io/, net/ with the shared version
- Eliminated the IPv4-only variants that silently produced wrong results for IPv6

### src/crypto/ (7 changes)
- **Extracted `U768` bigint** from `mse.zig` into `src/crypto/bigint.zig` (~180 lines, 7 tests moved)
- **Renamed `hasShaNi()` -> `hasHwAccel()`** in sha1.zig (was misleading on AArch64)
- **Made `peerCryptoFromResult` a method** `HandshakeResult.toPeerCrypto()` instead of free function
- **Removed redundant `ensureDetected()`** in sha1.zig; `round()` now uses `accel()` directly
- **Fixed `root.zig` naming**: `VarunaSha1` -> `varuna_sha1` (consistent snake_case)
- **Unified `crypto_method` field name** on `PeerCrypto` (was `method`, inconsistent with other structs)
- **Extracted `hashWithLabel` helper** for 5 duplicated hash derivation functions

### src/tracker/ (7 changes)
- **Extracted `src/tracker/types.zig`** with `Request`, `Response`, `Peer`, `Event` + shared encoding helpers
- **Merged `appendQueryBytes`/`appendQueryString`** -> `appendQueryParam` (identical implementations)
- **Consolidated duplicated helpers** (`appendPercentEncoded`, `isUnreserved`, `parseCompactPeers`, `parseCompactPeers6`) into types.zig
- **Removed dead `fetch()`** (unused std.http.Client variant)
- **Removed dead `announceParallelWithRing`** (misleading pass-through alias)
- **Renamed `expectPositiveU32/U64` -> `expectU32/U64`** (accepted zero despite "positive" name)
- **Fixed `ScrapeResponse` namespace** (removed unused fields, kept as pure codec namespace)
- **Fixed `max_retries`**: changed from 8 to 4, removed redundant `@min` wrappers

### src/dht/ (7 changes)
- **Replaced local `addressEql`** implementations with shared `net/address.zig` version
- **Deduplicated `K` constant**: lookup.zig now imports from routing_table.zig
- **Renamed `generate()` -> `generateRandom()`** in node_id.zig
- **Removed dead `Response.values` field** in krpc.zig (never populated by parser)
- **Changed `encodeQuery` to accept `Method` enum** instead of string dispatch
- **Fixed `_mod` import suffixes**: `token_mod` -> `token`, `lookup_mod` -> `lookup`, `bootstrap_mod` -> `bootstrap`
- **Moved `classifyNode`** from `KBucket` static method to module-level function

### src/storage/ (6 changes)
- **Renamed `resume.zig` -> `state_db.zig`** (70% of file was non-resume state)
- **Broke circular dependency**: defined local `QueuePosition` struct, removed import from `daemon/queue_manager.zig`
- **Removed dead code** in verify.zig: unreachable `file.length == 0` branch, unused `pieces_skipped` counter
- **Made `freePiecePlan` a method**: `PiecePlan.deinit()` instead of free function
- **Removed dead `joinValidatedPath`** in manifest.zig
- **Moved `TransferStats` inside `ResumeDb`** for better cohesion

### src/torrent/ (10 changes)
- **Fixed `pieceCountFromFiles` fallback**: returns `error.V2FileTreeRequired` instead of silently falling back to v1 computation
- **Renamed `expectPositiveU64` -> `expectU64`** (accepted zero)
- **Added `Bitfield.clear()` method**, replaced manual bitfield internals manipulation in `clearInProgress`
- **Changed `creation_date` from sentinel to optional**: `i64 = -1` -> `?i64 = null`
- **Removed redundant `eqlIgnoreCase` duplicates** in peer_id.zig
- **Fixed `_mod` import suffixes**: `layout_mod` -> `layout` in file_priority.zig and merkle_cache.zig
- **Exported `merkle_cache` from root.zig**
- **Removed dead `piece_size` computation** in merkle_cache.zig
- **Fixed `addBitfieldAvailability` type asymmetry**: now accepts `*const Bitfield` matching `removeBitfieldAvailability`
- **Removed trivial `isPrivate()` accessor** (was just `return self.private`)

### src/rpc/ (6 changes)
- **Fixed `withCors` misleading no-op**: simplified to a clear null-guard
- **Renamed `extractParam` -> `extractParamMut`**: signals the in-place URL-decode mutation
- **Fixed `startsWith("add")` route match**: changed to `eql` to prevent future `add*` endpoints from matching
- **Fixed `formatInfoHashV2`**: returns `?[64]u8` instead of zero-string sentinel
- **Renamed `json_mod` -> `json_esc`** in sync.zig and compat.zig
- **Removed unused `allocator` parameter** from `SyncState.Snapshot.deinit`

### src/daemon/ + src/io/ + src/runtime/ (15 changes)
- **Removed `TorrentIdType` alias**: kept only `TorrentId`
- **Deleted `Hasher.init` error stub** ("UseCreateInstead")
- **Renamed `PeerMode.seed/.download` -> `.inbound/.outbound`** across entire codebase
- **Replaced local `addressEql`** in dht_handler.zig and protocol.zig with shared version
- **Moved inline `@import`s to top of protocol.zig** (peer_policy, seed_handler)
- **Removed duplicated doc comment** in event_loop.zig
- **Fixed stale "io_uring" comments** in http.zig (uses blocking posix I/O)
- **Fixed `isDownloading` tautology**: simplified to `state != .seeding`
- **Renamed `resume_session` -> `unpause`** (avoided collision with persistence "resume" concept)
- **Fixed `@constCast` in categories.zig**: changed self from `*const` to `*` (honest about mutation)
- **Added top-level import for `UdpTrackerExecutor`** in torrent_session.zig
- **Named the `SupportLevel` enum** in requirements.zig (was anonymous)
- **Updated probe.zig**: uses named `SupportLevel`, renamed `version_text` -> `build_info`
- **Converted `freeSummary` to `Summary.deinit` method** (idiomatic Zig)

### src/net/ (6 changes)
- **Replaced local `addressEqual`** in metadata_fetch.zig with shared version
- **Replaced `CompactPeer` address comparison** in utp_manager.zig (eliminated cross-module PEX dependency)
- **Removed dead `findByRecvId`** in utp_manager.zig
- **Removed `DecodeResult` wrapper** in extensions.zig (returned `ExtensionHandshake` directly)
- **Removed unused `allocator` parameter** from `decodeExtensionHandshake`
- **Removed dead `NoTrackers`** from `FetchError` in metadata_fetch.zig
- Added ownership doc comment to `Piece` struct in peer_wire.zig

### Additional fixes during build verification
- Fixed pre-existing `Ip6Address.init` missing argument in dht/persistence.zig
- Fixed `[*:0]const u8` type coercion in state_db.zig inline for
- Fixed `{any}` format specifier for Ip6Address in persistence.zig
- Updated test files for `decodeExtensionHandshake` signature change and `max_retries` change

## Intentionally Skipped (25 issues)

These were assessed as too risky, too complex, or insufficiently valuable for automated changes:

### Architectural refactors (high risk)
- **Decompose `main.zig`** into named init phases -- 530-line single function, but touching it risks breaking the startup sequence
- **Split `app.zig`** by audience (daemon vs tools) -- needs build.zig target changes
- **Consolidate queue enforcement** -- three implementations with subtle behavioral differences; needs careful manual analysis
- **Extract shared bencode scanner** for net/ modules -- touches protocol-sensitive parsing code

### Protocol-sensitive changes
- **Split `Query.target` into `target`/`info_hash`** in krpc.zig -- protocol compatibility risk
- **Replace handshake reimplementation** in metadata_fetch.zig with peer_wire calls -- subtle behavior differences
- **Fix `buildPexMessage` side-effect mixing** -- touches PEX state machine
- **Fix `web_seed.zig` torrent_name** for multi-file URLs -- potential correctness change needs BEP 19 review

### Moderate-complexity refactors
- **`SyncState`/`PeerSyncState` dedup** -- ring-buffer pattern is similar but snapshot types differ
- **`handleSetPreferences` dual code path** -- JSON vs form-encoded branches must stay in sync
- **`serializeTorrentJson` partial_seed branching** -- format strings too large to safely merge
- **`handleTorrents` dispatch table** -- 30+ endpoints in if-else chain
- **`doGet`/`doPost` dedup** in ctl/main.zig -- moderate effort, low usage
- **`TrackerExecutor`/`UdpTrackerExecutor` shared DNS** -- structural similarity but different protocols
- **Event loop pending-send extraction** -- 200+ lines but tightly coupled to CQE dispatch
- **Move `HugePageCache`** from storage/ to io/ -- needs import path changes across subsystems

### Low-value changes
- **Peer struct field grouping** into nested structs -- massive refactor touching dozens of files
- **Stats struct grouping** -- touches RPC serialization format
- **Various "add a comment" suggestions** -- documentation, not code changes
- **`UtpSocket.allocator` optionality** -- minor, always set through manager
- **Lookup.nextToQuery wrapper removal** -- trivial indirection
- **Candidate.token BoundedArray** -- minor representation change
- **`announceWorker` anytype -> concrete type** -- low risk but low value
- **`resumeTorrent` start-then-check pattern** -- needs careful thread-safety analysis

## Key Code References
- Shared address comparison: `src/net/address.zig:6`
- U768 bigint extraction: `src/crypto/bigint.zig`
- Tracker shared types: `src/tracker/types.zig`
- State DB rename: `src/storage/state_db.zig` (was resume.zig)
- Bitfield.clear: `src/bitfield.zig:44`
- PeerMode rename: `src/io/types.zig:64`
- SupportLevel enum: `src/runtime/requirements.zig`
