# BEP 52 — DHT v2 announce/lookup + peer-provided hash storage

Date: 2026-04-29
Branch: `worktree-bep52-dht`
Scope: external-reviewer items **R4** (DHT v2 announce/lookup) and **R5**
(BEP 52 hashes-message integration).

## What changed

### R4 — DHT v2 announce/lookup for hybrid torrents

`src/dht/dht.zig:264, 253, 305` — `requestPeers`, `forceRequery`,
`announcePeer` now accept an optional second `[20]u8` parameter for the
truncated v2 info-hash (`info_hash_v2[0..20]`):

```zig
pub fn requestPeers(self: *DhtEngine, info_hash: [20]u8, info_hash_v2_truncated: ?[20]u8) void
pub fn forceRequery(self: *DhtEngine, info_hash: [20]u8, info_hash_v2_truncated: ?[20]u8) void
pub fn announcePeer(self: *DhtEngine, info_hash: [20]u8, info_hash_v2_truncated: ?[20]u8, port: u16) !void
```

Internally these fan out: each non-null hash is registered as its own
search slot in `pending_searches`, lookups run independently, and each
hash is announced separately.

Per BEP 52, the DHT key for a v2 torrent is `SHA-256(info)[0..20]` —
DHT mainline only supports 20-byte node IDs / target keys. Hybrid
torrents now announce + search against **both** hashes so v1-only
peers and v2-only peers both find us.

Caller plumbing:
* `src/main.zig:296` — magnet-link DHT registration site.
* `src/daemon/torrent_session.zig:683, 1453` — integrate-into-event-loop
  forceRequery and seed-mode announce sites.
* New `TorrentSession.dhtV2HashTruncated()` helper centralises the
  `[0..20]` truncation so callers don't sprinkle slicing logic around.

Inbound DHT peer results route correctly without further changes:
`registerTorrentHashes` already inserts both v1 and v2 truncated hashes
into the lookup map, so peers discovered via the v2 search are matched
back to the same torrent in `findTorrentIdByInfoHash`.

Error handling: if v1's `getPeers` fails (e.g. `error.NoNodes`) but v2
succeeds, `announcePeer` still returns `void` — we don't punish the
caller for one of two announces failing to start. If both fail, the v1
error is surfaced.

### R5 — Verify + store BEP 52 `hashes` messages

Before: `src/io/protocol.zig` `handleHashesResponse` decoded the message,
verified the *structure* of the proof, and dropped the result with a
"deferred" comment. The verified leaves were unreachable.

After:
* New `src/torrent/leaf_hashes.zig` module — `LeafHashStore` keyed by
  global piece index, plus `verifyAndStoreHashesResponse` that walks
  the peer's proof up to the file's authoritative `pieces_root`.
* Verification supports `base_layer == 0` with power-of-two-aligned
  ranges (the canonical case — most v2 clients request the entire
  padded leaf layer). Higher layers are accepted but logged + dropped.
* Padded zero positions past `file_piece_count` are silently skipped
  during store (still verified — they have to be `merkle.zero_hash`
  or the proof would not chain up).
* Conflicting re-stores (a different leaf for an already-stored piece)
  are warned + rejected.
* `TorrentContext.leaf_hashes: ?*LeafHashStore` — lazily allocated on
  the first valid response, freed in `EventLoop.removeTorrent`.

Follow-up (explicitly out of scope for this commit): consult the
`LeafHashStore` from `peer_policy.completePieceDownload` to actually
validate v2 pieces incrementally instead of waiting for whole-file
completion. R5 here is the wire-up + storage half; the
download-validation half is decoupled and lands separately.

### Tests

* DHT (`src/dht/dht.zig`):
  * `requestPeers registers both v1 and v2 hashes for hybrid torrents`
  * `requestPeers v1-only (null v2) registers only one hash`
  * `forceRequery toggles search-done flag for both hashes`
  * `announcePeer fans out to v1 and v2 hashes`

* Leaf hashes (`src/torrent/leaf_hashes.zig`):
  * Init/get/count
  * Stores full leaf layer
  * Rejects wrong root
  * Verifies partial range with proof (8-leaf tree, range `[0..2)`)
  * Rejects conflicting second store
  * Rejects non-power-of-two length
  * Skips padded positions past `file_piece_count`
  * End-to-end round-trip: encode hashes message → decode → verify + store

## Commits

```
5b4bfa9 test: BEP 52 hashes message round-trip smoke test
079259a test: BEP 52 DHT API hybrid-torrent coverage
4fe5160 torrent: store peer-verified BEP 52 leaf hashes per piece (R5)
3716cc4 dht: announce/lookup against v2 hash for hybrid torrents (R4)
```

## Test count delta

`zig build test`: ~1551 → ~1563 tests passing (+12 new, all pass; 15
skipped; same flaky `recheck_test.zig` AsyncRecheck pieces flake under
parallel scheduling regardless of branch — unrelated to R4/R5).

## What was learned

1. The DHT engine already had the abstractions to fan out cleanly —
   `pending_searches` is a flat list of `[20]u8`, so announcing both
   hashes is just two registrations. The trickiest part of R4 was
   landing the API change without breaking the existing pure-v1 call
   sites; an optional second parameter (Option A from the spec)
   minimised churn.

2. R5 verification has a subtle requirement: the proof in the message
   is a *single* chain from the subtree root (covering the requested
   range) up to the file root, **not** per-leaf. To verify, fold the
   received range pairwise into a subtree root, then walk up using
   the proof. This is only well-defined when the range is
   power-of-two-aligned at `base_layer`. The canonical full-leaf-layer
   request hits that constraint trivially.

3. Padding interacts with proof verification. A 3-piece file's leaf
   layer is padded to 4 with `merkle.zero_hash`; the proof chains up
   *through* the padding. We accept the padded entries during
   verification but only store entries with `local_idx <
   file_piece_count`.

4. The recheck test suite has pre-existing flakiness on tick budgets:
   `tests/recheck_test.zig` line 619 / 705 / 472 occasionally times
   out under parallel scheduling. Not caused by these changes
   (verified by running on the R4-only commit; same flake pattern
   independent of R5). Worth filing separately.

## Remaining issues / follow-up

* **Wire `LeafHashStore` into piece-completion** — the next R5 follow-up.
  `peer_policy.completePieceDownload` currently uses
  `sess.layout.pieceHash(piece_index)` which only works for v1/hybrid;
  pure-v2 multi-piece torrents return
  `error.DeferredMerkleVerificationRequired` (per `storage/verify.zig:180`).
  Once the hot path consults `LeafHashStore.get(piece_index)` for v2
  torrents, multi-piece pure-v2 downloads can verify pieces
  incrementally instead of post-completion file-tree rebuild.

* **Higher-layer hashes responses** — currently dropped with a debug
  log. Follow-up: store internal subtree roots so we can verify finer
  ranges or build local trees from peer-provided structure.

* **Smart-ban hook on hash verification failure** — the spec asked for
  smart-banning a peer whose proof fails to chain. The current
  `handleHashesResponse` only logs on failure; the smart-ban
  attribution path runs through piece-completion, so the natural place
  to add this is in the same follow-up that wires
  `LeafHashStore` into the piece-completion hot path.

* **Pre-existing recheck-test flakiness** — `tests/recheck_test.zig`
  AsyncRecheck tests time out under parallel scheduling on some seeds.
  Reproduces on R4-only and on `main`. Worth a separate ticket; not in
  scope here.

## Key code references

* `src/dht/dht.zig:264-321` — extended DHT client API.
* `src/main.zig:294-307` — magnet-path call site with v2 plumbing.
* `src/daemon/torrent_session.zig:683-689, 1452-1457, 928-936` — DHT
  call sites and the `dhtV2HashTruncated` helper.
* `src/torrent/leaf_hashes.zig` — new module (LeafHashStore + verification).
* `src/io/protocol.zig:966-1058` — rewritten `handleHashesResponse`.
* `src/io/types.zig:222-225` — `TorrentContext.leaf_hashes` field.
* `src/io/event_loop.zig:982-987` — leaf-hash store cleanup in
  `removeTorrent`.

## Coordination notes

The parallel `dht-correctness-engineer` is touching server-side response
handlers in `src/dht/dht.zig` (`respondFindNode`, `respondGetPeers`,
`respondAnnouncePeer`). These commits only touch client-side methods
(`requestPeers`, `forceRequery`, `announcePeer`) and an existing test
addition. Expected merge: trivial three-way merge.

Both engineers add a STATUS milestone entry — text conflicts may surface
but are easy to resolve (simple concatenation).
