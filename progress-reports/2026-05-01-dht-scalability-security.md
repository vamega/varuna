# DHT Scalability And Token Binding

**Date:** 2026-05-01

## What changed and why

- Replaced the fixed 16-entry DHT auto-search slate with an allocator-backed registry capped at 4096 hashes. Capacity and allocation failures now emit warnings instead of silently ignoring later public torrents.
- Bound DHT announce tokens to the full IPv6 address. IPv4 still uses the 4-byte address; IPv6 now uses all 16 bytes so same-/32 peers cannot replay each other's token.
- Updated DHT tests that inspected the registry internals and added focused regressions for same-prefix IPv6 token separation and registering more than the old 16-hash cap.

## What was learned

`TokenManager` already hashes arbitrary byte slices; the bug was the DHT engine's address adapter truncating IPv6 senders to four bytes. The search-registry cap was similarly local to `DhtEngine`: the public `requestPeers` API returned `void`, so silent failure came from the private fixed array path.

## Remaining issues or follow-up

- The DHT/uTP outbound UDP queues are still unbounded and still drain via front removal; this was intentionally left for separate queue/backpressure work.
- Full `zig build test` did not complete on this aarch64 host because of existing non-DHT build blockers: BoringSSL inline asm rejected with `fmov s4, %w[val]`, and `src/storage/sqlite3.zig` rejects the `SQLITE_TRANSIENT` pointer constant as unaligned.

## Key references

- `src/dht/dht.zig:20` - dynamic DHT search registry cap.
- `src/dht/dht.zig:279` - allocator-backed search registry storage.
- `src/dht/dht.zig:491` - visible capacity/allocation handling for search registration.
- `src/dht/dht.zig:695` - get_peers token generation using full address bytes.
- `src/dht/dht.zig:763` - announce_peer token validation using full address bytes.
- `src/dht/dht.zig:1189` - IPv4/IPv6 address-to-token byte adapter.
- `tests/dht_krpc_buggify_test.zig:1128` - search registry beyond-16 regression.
- `tests/dht_krpc_buggify_test.zig:1405` - same-/32 IPv6 token replay regression.
