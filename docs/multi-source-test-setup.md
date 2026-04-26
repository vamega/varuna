# Writing sim tests for multi-source piece assembly + smart-ban Phase 1-2

This doc is the API-coordination artifact for **Phase 2A** (multi-source
piece assembly) and **Phase 2B** (smart-ban Phase 1-2 per-block SHA-1
attribution + ban-targeting).

It extends `sim-test-setup.md` (which targeted Phase 0 smart-ban over a
single-source download). Read that first for the EL test surface basics
(`addInboundPeer` / `getPeerView` / `isPieceComplete`); this doc covers
only the new surface.

The plan follows `STYLE.md > Layered Testing Strategy`: each behaviour
lands as three tests (algorithm → integration → safety-under-faults).
The test scaffolds land first, gated behind `if (false)` until
migration-engineer's production code lands; then the gates flip and
the scaffolds light up. Same playbook as the smart-ban EL light-up.

---

## What's already in production

A surprising amount, since the data structures predate this assignment:

- **`DownloadingPiece`** (`src/io/downloading_piece.zig`) — shared
  per-piece block state. Multiple peers can `joinPieceDownload` and
  contribute blocks concurrently. `block_infos[i].peer_slot` records
  which peer delivered each block. `markBlockReceived(block_index,
  peer_slot, ...)` writes both the data and the attribution.
- **Smart-ban Phase 1 + 2 plumbing** (`src/net/smart_ban.zig`) —
  `SmartBan.snapshotAttribution` records per-block peer addresses on
  piece complete; `onPieceFailed` keys per-block SHA-1 + peer; a later
  `onPiecePassed` for the same piece compares per-block hashes and
  returns the list of peers whose blocks didn't match (ban targets).
  `peer_policy.snapshotAttributionForSmartBan` and
  `peer_policy.smartBanCorruptPeers` are the EL-side bridge.
- **`peer_policy.tryFillPipeline`** already calls `joinPieceDownload`
  when another peer is mid-download on the piece this peer is about to
  request — the multi-source state machine fires today.

So the *production* code is largely there. What's missing is:
- A test API to *observe* per-block attribution from outside the EL.
- SimPeer support for partial-availability (per-block serving) and
  deterministic per-block corruption.
- The three layered tests themselves.
- Whatever production gaps the tests surface (likely small).

---

## API surface needed from EventLoop / SimIO

### A1. `getBlockAttribution` (Phase 2A core)

Read-only accessor exposing `DownloadingPiece.block_infos[i].peer_slot`
indexed by piece. Lives next to `getPeerView` / `isPieceComplete` on
`EventLoopOf(IO)`.

```zig
/// Returns a snapshot of per-block peer attribution for the active
/// download of `piece_index` in `torrent_id`. Each entry is the slot
/// that delivered (or, if not yet received, requested) the
/// corresponding block; `attribution_unset` for blocks in `.none`
/// state. Returns null if the torrent has no active DownloadingPiece
/// for this piece (e.g. piece is complete or hasn't been claimed).
///
/// Caller-allocated buffer must be at least `geometry.blockCount(piece_index)`
/// long. Returns the populated slice (a sub-slice of `out`).
pub fn getBlockAttribution(
    self: *Self,
    torrent_id: TorrentId,
    piece_index: u32,
    out: []u16,
) ?[]const u16;

pub const attribution_unset: u16 = std.math.maxInt(u16);
```

The caller-buffer shape avoids heap allocation in the hot test loop and
lets the test hold the snapshot across multiple ticks even after the
underlying DP gets destroyed (e.g. piece completed, attribution copied
into smart-ban records).

**Production side:** ~10 lines of read-only iteration over
`tc.downloading_pieces.get(key).?.block_infos`. Migration-engineer
adds, sim-engineer's tests consume.

### A2. SimPeer per-block availability (Phase 2A scenarios 1-2)

Today's SimPeer advertises a per-piece bitfield and serves any block
requested from any piece in that bitfield. To stage "peer A has only
blocks 0-3 of piece P", the SimPeer needs to gate request-serving by
block index.

Two implementation options; sim-engineer to pick after talking with
migration-engineer:

**Option A (preferred)**: add an optional `block_mask: ?[]const bool`
to SimPeer's init. When set, `processMessage` for id=6 (request)
silently drops requests outside the mask. The downloader's existing
request timeout path re-requests from another peer.

**Option B**: a new `Behavior` variant `partial_blocks: { mask:
[]const bool }`. Same effect but composes with other behaviours less
cleanly (a `corrupt + partial_blocks` peer needs both behaviours
active).

Pick A. `block_mask` is orthogonal to `Behavior` — every behavior
should respect it.

### A3. SimPeer deterministic block corruption (Phase 2B scenarios 1-2)

The existing `Behavior.corrupt: { probability: f32 }` randomly flips
bits in any block at the configured probability. For Phase 2B's
"peer B sends block 5 corrupt" scenario we need deterministic per-block
control:

```zig
/// Corrupt specific blocks deterministically. Each entry is a block
/// index that should be sent with garbled data. Other blocks are sent
/// cleanly. Composes with `block_mask` (a peer can hold blocks 4-7
/// AND corrupt block 5 specifically).
corrupt_blocks: struct { indices: []const u32 },
```

`dispatchPieceResponse` in `sim_peer.zig` checks `req.block_offset /
piece_size` (derive block_index) against `indices`; if hit, garble the
block_dst (`@memset(block_dst, 0xaa)` or similar canonical bad
pattern). Else memcpy the canonical bytes.

### A4. Mid-piece peer disconnect (Phase 2A scenario 2)

The test closes the SimPeer's socketpair fd; the EL discovers the
broken connection via a recv-error and runs `removePeer`, which calls
`releaseBlocksForPeer` to put the peer's outstanding requests back in
the picker's pool.

No new EL surface needed — `el.io.closeSocket(peer.fd)` from the test
side is enough; the sim_smart_ban_eventloop_test drain phase already
uses this pattern.

What we need from SimPeer is a `disconnect()` helper that does the
right teardown: close the seeder-side fd, set state to `.closed`, no
more action processing.

```zig
pub fn disconnect(self: *SimPeer) void {
    if (self.fd >= 0) {
        self.io.closeSocket(self.fd);
        self.fd = -1;
    }
    self.state = .closed;
}
```

### A5. Already-have surface (no new work)

These are reused unchanged from Phase 0:
- `getPeerView(slot) -> ?PeerView` — `is_banned`, `hashfails`,
  `bytes_downloaded` are the post-test assertions.
- `isPieceComplete(torrent_id, piece_index)` — liveness checks.
- `BanList` injection on `EventLoopOf(IO).ban_list` — required for
  smart-ban to actually fire `bl.banIp`.
- `addConnectedPeerWithAddress(fd, tid, addr)` — distinct per-peer
  addresses for clean BanList separation.

### A6. Phase 2B specifically requires `SmartBan` installed

Phase 0 EL tests get by with just `BanList`. Phase 2B does NOT —
without `el.smart_ban = &smart_ban`, the `SmartBan.snapshotAttribution`
/ `onPieceFailed` / `onPiecePassed` chain doesn't fire, and a
disconnect-mid-piece corrupt peer escapes attribution entirely (Phase
0 alone needs 4 hash failures to ban; the peer leaves after 1-2).

```zig
var ban_list = BanList.init(allocator);
defer ban_list.deinit();
var smart_ban = SmartBan.init(allocator);
defer smart_ban.deinit();

var el = try EL_SimIO.initBareWithIO(allocator, sim_io, 1);
defer el.deinit();

el.ban_list = &ban_list;
el.smart_ban = &smart_ban;
```

**Declaration order matters**: `defer` runs LIFO. The EL's
`deinit → drainRemainingCqes` can fire `processHashResults` → smart-
ban hooks → `BanList.banIp` for residual late CQEs. If `smart_ban`
or `ban_list` is declared AFTER `el`, their defer runs FIRST,
freeing them while EL is still draining → UAF panic in the
hashmap header() pointer math (observed in practice). Declare
`ban_list` and `smart_ban` BEFORE `el` so that LIFO defer order
runs `el.deinit` first (while both are still alive), then
`smart_ban.deinit`, then `ban_list.deinit`.

The same pattern is correct for Phase 0 tests — and worth following
uniformly even though Phase 0's `penalizePeerTrust` typically fires
during the main tick loop rather than during teardown drain.

---

## Test files

Three layers per `STYLE.md > Layered Testing Strategy`:

### `tests/sim_multi_source_protocol_test.zig` (algorithm test, Phase 2A)

Bare `DownloadingPiece` + `peer_policy` calls; no EventLoop. Asserts
the multi-source state machine in isolation:

- `markBlockRequested` rejects already-requested blocks → next peer
  picks a different unrequested block.
- `markBlockReceived` records the right `peer_slot` and rejects
  duplicates.
- `releaseBlocksForPeer` returns only requested-not-received blocks.
- `unrequestedCount` / `requestedCountForPeer` track correctly across
  three peer slots.

Locks in the *what* of multi-source assembly without depending on
async hashing or socket plumbing.

### `tests/sim_multi_source_eventloop_test.zig` (integration test, Phase 2A)

Real `EventLoopOf(SimIO)` + 3 SimPeers each with a different
`block_mask`. Asserts the three Phase 2A scenarios:

- Multi-source happy path.
- Mid-piece peer disconnect.
- All sources hold all blocks.

Liveness assertions: pieces verify, every block has the right
`getBlockAttribution`, no duplicate requests went out (observable via
each peer's `bytes_uploaded_to_us`).

Pattern: same as `sim_smart_ban_eventloop_test.zig`'s clean run, with
the new test scenarios as separate `test "..." { ... }` blocks sharing
a `runOneScenario(seed, scenario_config)` helper.

### `tests/sim_smart_ban_phase12_eventloop_test.zig` (integration + safety, Phase 2B)

Builds on the multi-source EL test:

- **Algorithm test** (no faults, 8 seeds): the three Phase 2B
  scenarios. Asserts:
  - Single-corrupt-block: only the offender peer's address ends up in
    `ban_list.isBanned`.
  - Two-peer corruption: both offenders banned, the third peer not.
  - Ambiguous attribution edge case: assert the algorithm's
    documented behaviour (best-effort: penalise still-attributed
    peers; don't penalise re-requested-and-verified blocks).

- **Safety-under-faults test** (BUGGIFY + FaultConfig, 32 seeds):
  same scenarios with randomized faults. Asserts the safety
  invariant: an honest peer is never banned, regardless of fault
  sequence — provable via the same chain as Phase 0
  (`penalizePeerTrust` + `smartBanCorruptPeers` are the only
  `bl.banIp` callers; both only fire on hash mismatch; honest peers
  don't send mismatched data; therefore no fault sequence can frame
  an honest peer).

  Vacuous-pass guard: same shape as the Phase 0 BUGGIFY test —
  require ≥ half the seeds observe an actual ban.

---

## Risks / open questions for migration-engineer

1. **`getBlockAttribution` lifetime**: the underlying `DownloadingPiece`
   is destroyed when the piece completes (handed off to hasher). After
   that, attribution lives in `SmartBan.pending_attributions` until
   `processHashResults` consumes it. The accessor needs to consult
   *both* sources or only return live-DP attribution — TBD which is
   more useful for tests. My instinct: live-DP only; tests snapshot
   during the download window, which is what we want to assert anyway.
2. **Multi-source piece request ordering**: scenario 3 (all sources
   hold all blocks, load distributed evenly) depends on the picker's
   tie-breaking. If the picker assigns all blocks to the first peer
   that asks (greedy), the test needs to specifically request that
   blocks distribute. Worth confirming `tryFillPipeline`'s behaviour:
   when peer A has reserved blocks 0-15 of piece P (entire piece),
   does peer B's tryFillPipeline `joinPieceDownload` see anything
   left to claim? Empirically: yes, because A doesn't claim all blocks
   at once — pipeline_depth caps outstanding requests, and B fills
   the gap. But scenarios that assume even distribution may need
   tuning of `pipeline_depth` or explicit "block this peer until A
   has 4 outstanding" sequencing.
3. **Smart-ban Phase 2 second-pass requirement**: `onPiecePassed` only
   identifies bad peers if there's a *prior* `onPieceFailed` record
   for the same piece. That means the test scenarios have to send the
   bad piece *first*, get a hash fail, then re-request from honest
   peers and observe ban-on-pass. The "single-corrupt-block" scenario
   has to round-trip the piece twice. Plan for that in the test
   harness — the smart-ban scaffold already runs many ticks; just
   need to confirm the second pass actually re-requests from the
   non-corrupt peers.
4. **`block_mask` on SimPeer + bitfield consistency**: if SimPeer
   advertises bitfield = "I have piece P" but only serves blocks 0-3,
   the production picker may get confused (it expects "has piece"
   = "can serve any block"). Real BitTorrent doesn't have per-block
   availability, so we're modelling something that doesn't happen on
   the wire. Workaround: SimPeer drops requests for unsupported
   blocks silently, and the EL's request timeout re-routes to another
   peer. That's an existing path. The mask is a sim-only sleight of
   hand to *force* the picker into multi-source.
5. **SimPeer relaxed serving (Task #23 lesson)**: `SimPeer.serveRequest`
   does **not** enforce its advertised bitfield on the wire — when
   asked for any piece in `piece_data`, it serves it (bounds check
   only). Real peers reject unsolicited piece requests for unadvertised
   pieces. This relaxed serving can magnify production-side picker
   bugs that wouldn't manifest against real peers: e.g. an honest peer
   pulled into a corrupt-only piece's DP via a missing bitfield gate
   will deliver canonical bytes that race against corrupt's bad bytes
   in the shared `dp.buf`, producing a mixed buffer → hash fails →
   `processHashResults` penalises the slot of whoever delivered the
   *last* block (potentially the framed honest peer). Tests that
   depend on production-side bitfield enforcement should ensure that
   enforcement IS exercised on the request path (e.g. picker call
   sites checking `peer.availability.has(piece_index)`), not just on
   the announce path. Surfaced by `tests/sim_smart_ban_eventloop_test.zig`
   when block-stealing was first activated; the bitfield gate at
   `tryJoinExistingPiece` is the load-bearing guard.

---

## Coordination

- I (sim-engineer) draft the test scaffolds with `if (false)` gates
  around the EL-dependent assertions, mirroring how
  `sim_smart_ban_eventloop_test.zig` was scaffolded before Task #14.
- Migration-engineer reviews this doc, agrees on the API names + shape,
  and lands `getBlockAttribution` + the SimPeer `block_mask` /
  `corrupt_blocks` / `disconnect()` extensions.
- I light up the scaffolds: flip the gates, add the assertions, run
  8-seed clean + 32-seed BUGGIFY.
- We re-validate `zig build test` green and the full pattern catalogue
  in `STYLE.md` lands a pattern entry if anything novel surfaces from
  the multi-source state machine.

Phase 2A lands before 2B (the algorithm needs the attribution surface).

Ping migration-engineer when this doc looks right.
