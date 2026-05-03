# DHT Queue Hardening

## What changed

- Added defensive caps for queued DHT UDP packets and queued peer-result batches so bursty or adversarial traffic cannot grow event-loop handoff memory without bound.
- Changed the event-loop DHT handoff to batch-drain queued sends and peer results instead of repeatedly removing index 0 from `ArrayList`.
- Added explicit regression coverage that DHT announce tokens bind all 16 IPv6 address bytes, plus focused queue-cap tests and a `zig build test-dht` target.

## What was learned

- The old 16-entry DHT search registry issue was already fixed by the dynamic `pending_searches` registry with a 4096-entry defensive cap.
- The BEP 52 DHT lookup hash is already preserved into outbound peer handshakes through `addPeerAutoTransportWithSwarmHash`.
- The remaining current DHT hardening gap was queue behavior: `send_queue` and `peer_results` were uncapped, and `src/io/dht_handler.zig` drained them with front removals.

## Follow-up

- Add low-cardinality counters for dropped DHT packets/results if operational visibility becomes important.
- If strict FIFO observability becomes necessary across DHT queue drains, keep the current batch API but add targeted ordering tests around it.

## Key references

- `src/dht/dht.zig:29` - DHT queue caps.
- `src/dht/dht.zig:600` - batch send queue drain/release helpers.
- `src/dht/dht.zig:616` - batch peer-result drain/release helpers.
- `src/dht/dht.zig:1144` - bounded outbound packet enqueue.
- `src/dht/dht.zig:1159` - bounded peer-result enqueue with owned-peer cleanup.
- `src/io/dht_handler.zig:36` - event-loop batch drain for outbound DHT sends.
- `src/io/dht_handler.zig:50` - event-loop batch drain for DHT peer results.
- `build.zig:255` - focused `test-dht` target.
