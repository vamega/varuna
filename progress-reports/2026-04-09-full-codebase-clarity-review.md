# Full Codebase Clarity & Abstraction Review

**Date:** 2026-04-09
**Scope:** All 10 subsystems reviewed by independent agents for code clarity, abstraction level, and module cohesion. Not a security, performance, or style review.

## Executive Summary

The codebase is well-structured overall. Module boundaries are generally sound, naming is mostly clear, and the layered architecture is intuitive. The most impactful issues are cross-cutting: duplicated utility functions (especially address comparison), inconsistent naming conventions, monolithic files that mix abstraction levels, and stringly-typed values where enums would be safer.

**Findings by severity across all subsystems:**

| Severity | Count | Description |
|----------|-------|-------------|
| High     | 25    | Actively confusing, misleading, or architecturally wrong |
| Medium   | 44    | Could be meaningfully clearer |
| Low      | 38    | Minor naming or organization nits |

---

## Cross-Cutting Themes

### 1. Duplicated `addressEql` / `addressEqual` (6 copies, 3 different semantics)

The most pervasive issue. Found in:
- `src/dht/lookup.zig:264` -- IPv4 only (accesses `.in.sa` unconditionally)
- `src/dht/dht.zig:857` -- via PEX CompactPeer (handles both families)
- `src/io/dht_handler.zig:91` -- IPv4 only
- `src/io/protocol.zig:514` -- via sockaddr cast
- `src/net/metadata_fetch.zig:527` -- manual IPv4/IPv6 dispatch
- `src/net/utp_manager.zig:236` -- via PEX CompactPeer (cross-module dependency)

The IPv4-only versions silently produce wrong results for IPv6 peers, which contradicts BEP 32 support added throughout the DHT subsystem.

**Fix:** Single `addressEql` in a shared location (e.g., `src/net/address.zig` or `src/io/types.zig`), handling both address families.

### 2. Duplicated Bencode Parsers (3+ independent implementations)

- `src/torrent/bencode.zig` -- canonical allocating parser
- `src/net/extensions.zig:191-277` and `src/net/ut_metadata.zig:220-306` -- nearly identical zero-allocation `Parser` structs with different error types
- `src/dht/krpc.zig` -- another zero-allocation parser, justified for KRPC but still duplicates core logic
- `src/net/ut_metadata.zig:158-218` -- *third* bencode walker (`findDictEnd`/`skipBencodeValue`) in the same file

**Fix:** Extract a shared lightweight bencode scanner that doesn't allocate. Parameterize error types.

### 3. `_mod` Import Suffix Inconsistency

Some files use `const layout_mod = @import("layout.zig")` while neighboring files use `const layout = @import("layout.zig")`. Instances: `layout_mod` (torrent/file_priority.zig, torrent/merkle_cache.zig), `token_mod`, `lookup_mod`, `bootstrap_mod` (dht/dht.zig), `json_mod` (rpc/sync.zig, rpc/compat.zig). No actual name conflicts in most cases.

**Fix:** Use plain names consistently. Rename local variables if they conflict.

### 4. `expectPositiveU64` Accepts Zero

Found in both `src/torrent/metainfo.zig:385` and `src/tracker/announce.zig:379`. Name says "positive" but the check is `< 0`, allowing zero through. Misleads readers about the function's contract.

**Fix:** Rename to `expectNonNegativeU64` or `expectU64`.

### 5. Stringly-Typed Values Where Enums Would Be Safer

- `src/crypto/mse.zig:59-61` -- crypto methods as raw `u32` constants, no distinction between single method and bitmask
- `src/storage/resume.zig:939` -- `TrackerOverride.action` is `[]const u8` ("add"/"remove"/"edit")
- `src/config.zig:64` -- `encryption` stored as string, re-parsed at every use site
- `src/torrent/metainfo.zig:27` -- `creation_date: i64 = -1` sentinel instead of `?i64 = null`

**Fix:** Use enums and optionals. Parse once at the boundary.

### 6. Monolithic Files Mixing Abstraction Levels

| File | Lines | Issue |
|------|-------|-------|
| `src/main.zig` | ~530 | Single `main()` function with inline DHT init, SQLite setup, event loop, etc. |
| `src/crypto/mse.zig` | ~2080 | Embeds U768 bigint library, socket I/O helpers, two handshake state machines |
| `src/io/event_loop.zig` | ~2010 | Type definition + lifecycle + torrent mgmt + peer mgmt + run loop + send tracking |
| `src/daemon/torrent_session.zig` | ~1800 | Contains `TrackerOverrides` data structure, 50+ field `Stats` struct, DB access |
| `src/storage/resume.zig` | ~1134 | Named "resume" but 70% is categories, tags, bans, IP filters, queue positions |

### 7. Dead Code

| Location | What |
|----------|------|
| `src/tracker/announce.zig:53` | `fetch()` using `std.http.Client`, zero callers |
| `src/tracker/multi_announce.zig:190` | `announceParallelWithRing`, pass-through alias with misleading name |
| `src/net/utp_manager.zig:227` | `findByRecvId`, superseded by `findByRecvIdRemote` |
| `src/storage/manifest.zig:74` | `joinValidatedPath`, never called |
| `src/dht/krpc.zig:69` | `Response.values` field, never populated by parser |
| `src/daemon/queue_manager.zig:204` | `enforceQueue` and `shouldBeActive`, replaced by `session_manager.runQueueEnforcementLocked` |
| `src/rpc/handlers.zig` | `withCors` no-op branch that captures and discards `existing` headers |
| `src/storage/verify.zig:255` | `pieces_skipped` counter, incremented but never read |
| `src/net/pex.zig:17` | `pex_interval_secs`, exported but unused within module |

---

## Per-Subsystem High-Severity Findings

### src/daemon/ (4 high)

1. **`isDownloading` is a tautology** (`queue_manager.zig:299`): After the first check eliminates `.seeding`, the middle branch is dead code and the function reduces to `state != .seeding`.

2. **`resume_session` naming collision** (`torrent_session.zig:414`): Only snake_case function in the codebase; collides with "resume" in the persistence sense. Rename to `unpause`.

3. **Start-then-check pattern in `resumeTorrent`** (`session_manager.zig:487`): Temporarily sets state to `.paused`, starts the torrent (spawning a thread), then retroactively re-pauses if queue says no.

4. **Triple queue enforcement duplication**: `shouldBeActive`, `enforceQueue` (both in queue_manager.zig), and `runQueueEnforcementLocked` (session_manager.zig:764) all implement the same limit arithmetic differently.

### src/io/ (4 high)

1. **`TorrentIdType` and `TorrentId`** (`types.zig:16-17`): Two names for the same `u32`. Pick one.

2. **`Hasher.init` exists only to return `error.UseCreateInstead`** (`hasher.zig:121`): Delete it.

3. **`PeerMode.seed` means "we serve this peer"** (`types.zig:64`): Misleading. Rename to `.inbound`/`.outbound`.

4. **Duplicated `addressEql`** across `dht_handler.zig` and `protocol.zig` (see cross-cutting #1).

### src/torrent/ (3 high)

1. **`pieceCountFromFiles` silently falls back to v1 method** (`metainfo.zig:48`): When `file_tree_v2` is null, computes from `totalSize()` instead of erroring. Masks bugs in v2 callers.

2. **`expectPositiveU64` naming** (`metainfo.zig:385`): Accepts zero despite name (see cross-cutting #4).

3. **`clearInProgress` reaches into Bitfield internals** (`piece_tracker.zig:404`): Manually manipulates `.bits` and `.count` instead of using the public API. Add a `clear` method to `Bitfield`.

### src/storage/ (4 high)

1. **`resume.zig` name is misleading** -- 70% of the file is categories, tags, bans, IP filters, queue positions. Rename to `persistence.zig` or `state_db.zig`.

2. **Circular dependency** (`resume.zig:1112`): Imports `QueueEntry` from `src/daemon/queue_manager.zig`. Storage should not depend on daemon layer.

3. **Dead branch in `verify.zig:129`**: `file.length == 0` ternary can never be true because line 126 already `continue`d past zero-length files.

4. **Written-but-never-read sentinel in `verify.zig:78`**: `expected_hash_v2` set to all-zeros as "sentinel for Merkle verification" but the actual dispatch uses `v2_file_piece_count > 1`, not the sentinel value.

### src/net/ (4 high)

1. **Duplicated bencode `Parser`** across `extensions.zig:191` and `ut_metadata.zig:220` (see cross-cutting #2).

2. **`metadata_fetch.zig` manually re-implements the BitTorrent handshake** (lines 322-328) instead of using `peer_wire.serializeHandshake`.

3. **uTP manager imports PEX's `CompactPeer` for address comparison** (`utp_manager.zig:236`): Cross-module dependency leak (see cross-cutting #1).

4. **`Piece` struct has redundant `block` and `payload` fields** (`peer_wire.zig:35-40`): Both point into the same allocation with no ownership documentation.

### src/tracker/ (4 high)

1. **`announce.zig` is misnamed**: It's the types module + HTTP client + URL encoding. Both `scrape.zig` and `udp.zig` import shared types from "announce."

2. **`appendQueryBytes` and `appendQueryString`** (`announce.zig:285-324`): Identical implementations with different names.

3. **`announceParallelWithRing` is dead misleading code** (`multi_announce.zig:190`): Name promises ring integration, body is a pass-through.

4. **`ScrapeResponse.results` is never populated** (`udp.zig:190`): Struct exists only as a namespace for static methods.

### src/dht/ (4 high)

1. **Three divergent `addressEql` implementations** (see cross-cutting #1). The `lookup.zig` version is IPv4-only.

2. **`Query.target` conflates `target` and `info_hash`** (`krpc.zig:49`): Two different protocol fields parsed into one optional, losing which was actually present.

3. **`classifyNode` is a static method on `KBucket` that doesn't use `KBucket`** (`routing_table.zig:42`): Operates purely on `NodeInfo`. Move to `node_id.zig`.

4. **`encodeQuery` uses string dispatch despite `Method` enum existing** (`krpc.zig:392`): Accepts `[]const u8` method name and uses `std.mem.eql` chains instead of `switch` on the enum.

### src/rpc/ (3 high)

1. **`withCors` silently discards existing headers** (`handlers.zig:29`): Captures `existing` headers, discards them with `_ = existing`, assigns the field back to itself. No-op that looks like it does something.

2. **`extractParam` mutates `const` input via `@constCast`** (`handlers.zig:1619`): URL-decodes in-place, corrupting the body buffer. Type signature lies about side effects.

3. **`SyncState` and `PeerSyncState` are near-identical** (`sync.zig:10-341`): Same ring-buffer snapshot pattern duplicated with slightly different snapshot types.

### src/crypto/ (4 high)

1. **`PeerCrypto` duplicates `HandshakeResult`** (`mse.zig:813`): Nearly identical fields and methods. `peerCryptoFromResult` should be a method.

2. **`processReq2` mixes three responsibilities in 83 lines** (`mse.zig:1442`): Hash identification + cipher setup + elaborate leftover-buffer management.

3. **Inconsistent field names for crypto method**: `method` on `PeerCrypto`, `crypto_method` on `HandshakeResult` and both handshake structs.

4. **`hasShaNi()` returns true for AArch64 SHA extensions** (`sha1.zig:128`): Name implies x86-only. Rename to `hasHwAccel()`.

### src/runtime/ + entrypoints (4 high)

1. **`Summary.support` type uses opaque `@TypeOf` expression** (`probe.zig:12`): Computes type at comptime instead of naming the enum.

2. **`main.zig` is a 530-line single function** mixing argument parsing, config loading, DHT init with raw SQLite C calls, session manager setup, API server, and the main tick loop.

3. **Resume DB path resolution uses confusing `@ptrCast`/`_ = z` pattern** (`main.zig:74-93`): Duplicated for DHT DB path too.

4. **`app.zig` conflates startup banner and `varuna-tools` CLI dispatch**: Two unrelated binaries share one ambiguously-named file.

---

## Recommended Priority Order

**Batch 1 -- High impact, low effort (cross-cutting fixes):**
1. Consolidate `addressEql` into a single shared function
2. Rename `expectPositiveU64` -> `expectU64` everywhere
3. Remove confirmed dead code (listed above)
4. Fix `_mod` import inconsistency

**Batch 2 -- High impact, moderate effort (architectural):**
5. Rename `resume.zig` -> `state_db.zig` or `persistence.zig`, break circular dep
6. Extract shared types from `tracker/announce.zig` into `tracker/types.zig`
7. Extract `U768` from `mse.zig` into `crypto/bigint.zig`
8. Decompose `main.zig` into named initialization phases
9. Rename `PeerMode.seed`/`.download` -> `.inbound`/`.outbound`

**Batch 3 -- Medium impact, improves maintainability:**
10. Extract shared bencode scanner for `net/extensions.zig` and `net/ut_metadata.zig`
11. Consolidate queue enforcement into single path in `queue_manager.zig`
12. Fix `extractParam` `@constCast` mutation in `rpc/handlers.zig`
13. Use enums for crypto methods, tracker override actions, config encryption mode
14. Split `app.zig` by audience (daemon banner vs tools CLI)
15. Add `Bitfield.clear()` method, stop reaching into internals
