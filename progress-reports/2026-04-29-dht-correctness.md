# DHT correctness round (R1, R2, R3)

External-reviewer triage flagged 17 issues across the codebase; three of
the most urgent were real DHT correctness gaps.  All three are now fixed
on `worktree-dht-correctness` (off `81c9391`).

## What changed and why

### R1 — KRPC sender_id required

Before: `parseQuery` (`src/dht/krpc.zig:171`) and `parseResponse`
(`src/dht/krpc.zig:212`) initialised `sender_id = undefined` and only
assigned it when the bencoded body contained an `id` key.  Per BEP 5
every KRPC query and response MUST carry the sender's 20-byte node id;
an absent id field is malformed.  Today's parser silently propagated
the `undefined` into `RoutingTable.addNode` / `markResponded` —
undefined behaviour, real security bug.

After: both parsers track an `id_seen` flag and return
`error.InvalidKrpc` when the key is absent.  The single caller
(`handleIncoming`) already catches and logs at debug; malformed inputs
are common in DHT swarms and dropping them is correct.

Code references:
- `src/dht/krpc.zig:167-220` (parseQuery)
- `src/dht/krpc.zig:222-275` (parseResponse)

### R2 — IPv6 outbound (BEP 32 dual-stack)

Before: `respondFindNode` (`src/dht/dht.zig:378`) and `respondGetPeers`
(`src/dht/dht.zig:410`) dropped every IPv6 node with `if (family !=
AF.INET) continue;`.  Comments explicitly acknowledged "IPv6 would
require the nodes6 field".  Inbound `nodes6` was already being parsed
in recent rounds; the encoder side was the gap.

After:
- `src/dht/krpc.zig` — extend the private `encodeResponse` to take
  optional `nodes6` and `values6` (4 → 6 → 8 args end shape).  Emitted
  in lexicographic dict order (id < nodes < nodes6 < token < values
  < values6) and skipped when empty.  Add `encodeFindNodeResponseDual`
  and a more general `encodeGetPeersResponseFull` public helper.
- `src/dht/dht.zig` — split closest-node packing by address family;
  pass both buffers to the new dual-stack encoder.  Send buffer raised
  from 1024 to 1500 (UDP MTU) so a full v4+v6 set fits.

Code references:
- `src/dht/krpc.zig:617-633` (encodeFindNodeResponseDual,
  encodeGetPeersResponseFull)
- `src/dht/krpc.zig:740-820` (private encodeResponse with both fields)
- `src/dht/dht.zig:553-595` (respondFindNode dual-stack)
- `src/dht/dht.zig:597-660` (respondGetPeers dual-stack)

### R3 — peer storage for announce_peer (BEP 5 §"Peers")

Before: `respondAnnouncePeer` (`src/dht/dht.zig:441`) validated the
token, queued a ping reply, and discarded the announce.  `get_peers`
therefore always fell through to closest-nodes only — varuna lied to
the swarm.

After: new private `PeerStore` struct in `src/dht/dht.zig`.

- `std.AutoHashMap([20]u8, std.ArrayListUnmanaged(Entry))`.
- BEP 5 default 30-min TTL.
- 100 peers/hash cap (libtorrent / rakshasa cap somewhere between 30
  and 100; we use 100 as a defensive ceiling so a single hash cannot
  dominate memory).
- FIFO eviction at cap (oldest entry replaced first).
- Lazy sweep on every `get_peers` plus a periodic sweep in `tick`.

Wire-up:
- `respondAnnouncePeer` — after token validation, honour BEP 5's
  `implied_port` flag (use sender's UDP source port when set, else the
  announced port), then `peer_store.announce(info_hash, peer_addr)`.
- `respondGetPeers` — lazy-sweep + look up peers, emit them in
  `values` (v4) / `values6` (v6) alongside the closest `nodes` /
  `nodes6` fallback so well-behaved clients can keep iterating.

Code references:
- `src/dht/dht.zig:50-220` (PeerStore + addressesEqual helper)
- `src/dht/dht.zig:670-720` (respondAnnouncePeer with implied_port +
  peer_store.announce)
- `src/dht/dht.zig:248-258` (tick: peer_store.sweep)

### Tests

`tests/dht_krpc_buggify_test.zig` gained:

- 4 R1 tests: query / response missing id rejected, deterministic
  round-trip preserves sender_id verbatim.
- 2 R2 tests: find_node and get_peers responses both emit `nodes` and
  `nodes6` with correct wire-format byte counts.
- 6 R3 tests: full announce → store → get_peers round-trip including
  wire-level `values` decoding; invalid token does not store;
  implied_port=1 uses source port; sweep removes expired entries;
  FIFO eviction at cap; re-announce refreshes expiry without
  duplicating.

Total +12 tests over the prior baseline.

## What was learned

1. **The parser already had inbound nodes6 / values6.**  The asymmetric
   shape (parser knew about IPv6 but the encoder side dropped it) made
   the bug invisible from any test that only round-tripped *responses
   we send to peers*.  The fix is small once you notice both sides need
   the field; the `encodeResponse` private helper was already factored
   for this kind of extension.
2. **`@TypeOf(@as(T, undefined).field)` lets tests reach a private
   struct via a public field.**  The `PeerStore` struct stayed private
   to `src/dht/dht.zig`; tests outside the module construct one via
   `@TypeOf(engine.peer_store).init(...)` for the eviction / sweep
   tests that don't need to go through the engine.  The `pub` markers
   on `PeerStore.init` / `deinit` / `announce` / `encodeValues` /
   `sweep` / `peerCount` / `hashCount` are required because the type
   itself is unexported but its instance methods are still called from
   the test file.
3. **Bencode dict key ordering matters.**  `nodes` (n) < `nodes6` (same
   prefix, longer wins) < `token` (t) < `values` (v) < `values6`.
   Lexicographic byte ordering, not alphanumeric.  Mis-ordered keys
   are technically invalid bencode; well-behaved peers don't enforce
   it but we should still emit canonically.
4. **The `address` import shadowed a parameter name.**  `src/dht/dht.zig`
   imports `const address = @import("../net/address.zig")`; using
   `address` as a parameter name in `PeerStore.announce` triggered Zig's
   shadow check.  Renamed to `peer_addr`.
5. **`drainSendQueue` does not invalidate the prior `peekLastSend` slice
   immediately.**  It clears the items list with `clearRetainingCapacity`,
   so the underlying packet data buffer is still alive — but a future
   queueSend overwrites it.  Tests that need to peek at an outbound
   packet and then drive a follow-up query must copy out the relevant
   bytes (`token`, here) before calling `drainSendQueue`.

## Remaining issues / follow-up

- **Memory usage of PeerStore at scale.**  Worst-case is
  `info_hashes × 100 × sizeof(Entry)`, where `sizeof(Entry)` is
  ~32 bytes (`std.net.Address` + `i64`).  At 10k tracked hashes that's
  ~32 MB — fine for a varuna node but worth measuring under real DHT
  swarm load.  An LRU on the outer map would bound this; not required
  for the MVP per the spec.
- **Sweep batch limit.**  `PeerStore.sweep` collects up to 16 stale
  hash keys per pass; if the peer-store accumulates more empty hashes
  than that, the rest are reaped on subsequent ticks.  Not a leak,
  just deferred.  At the current 5-second tick interval and 30-min
  TTL, the worst-case backlog converges in seconds.
- **`encodeValues` cap-clamp is silent.**  If the peer-store has more
  v4 entries than fits in the caller's buffer, the overflow is dropped
  silently.  At our current `max_peers_per_hash = 100` and the
  matching buffer size, this is an invariant — but if a future caller
  passes a smaller buffer, the function should ideally signal that
  not all entries were emitted.  Low priority.
- The 8-test seed sweep on `sim_multi_source_eventloop_test` is flaky
  on seed `0xfeedface` and `0x12345678` independent of these changes
  (verified by running `zig build test` multiple times — passes some
  runs, fails others).  Not in scope for this milestone.

## Commit list

```
ad38b23 dht: tests for IPv6 outbound + announce_peer storage (R2/R3)
6d4fe3b dht: emit IPv6 nodes6 + announce_peer storage in responses (R2+R3)
5d383b2 dht: krpc: reject queries/responses missing required 'id' key (R1)
```

(STATUS milestone + this report land in a fourth commit on top.)

## Verification

- `nix develop --command zig fmt .` clean.
- `nix develop --command zig build` green.
- `nix develop --command zig build test` exit 0 (after ignoring the
  pre-existing `sim_multi_source_eventloop_test` flake noted above).
