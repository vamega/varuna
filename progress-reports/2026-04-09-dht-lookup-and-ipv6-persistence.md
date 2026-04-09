# 2026-04-09: DHT Lookup And IPv6 Persistence Corrections

## What was done and why

Fixed the DHT edge cases that could stall lookups, accept spoofed replies, and corrupt persisted IPv6 routing data.

- `src/dht/lookup.zig:178` adds `markPending()` so the engine can return candidates from `.queried` back to `.pending` when it fails to reserve a pending-query slot.
- `src/dht/dht.zig:102` now seeds persisted nodes with their stored `last_seen` timestamp instead of treating them as freshly seen on every startup.
- `src/dht/dht.zig:459` now matches inbound responses by both transaction ID and sender address. This closes the obvious spoofing/misattribution hole where any sender could satisfy a pending transaction ID.
- `src/dht/dht.zig:599` and `src/dht/dht.zig:632` now requeue candidates when `pending[]` is full instead of leaving them stuck in `.queried` forever.
- `src/dht/persistence.zig:226` now formats IPv6 node addresses correctly during persistence instead of reading IPv6 sockets through the IPv4 formatting path.

## What was learned

- The DHT lookup state machine assumes "mark queried" and "actually sent the query" are one atomic step. Once the pending table can reject work, those states must be separated or lookups can deadlock themselves.
- Persisted routing-table freshness is operationally important. Treating all saved nodes as newly seen biases bucket quality and makes cold-start routing tables look healthier than they really are.

## Remaining issues / follow-up

- Persisted nodes are still loaded as `ever_responded = true`; that remains a pragmatic assumption from save time, not a fresh runtime observation.
- This pass did not add outbound-query rate limiting or KRPC fuzz coverage.

## Code references

- `src/dht/lookup.zig:178`
- `src/dht/dht.zig:102`
- `src/dht/dht.zig:459`
- `src/dht/dht.zig:599`
- `src/dht/dht.zig:632`
- `src/dht/persistence.zig:226`
