# uTP Packet Pool Milestone

## What changed and why

- Added reusable byte-size config parsing for integer bytes and binary suffix
  strings, including the uTP packet-pool config fields and validation.
- Added `UtpSettings` with libtorrent-compatible defaults and wired it through
  daemon config, `EventLoop`, `UtpManager`, `UtpSocket`, and LEDBAT so target
  delay and timeout values now have a configurable path.
- Added a standalone `UtpPacketPool` with 64/128/256/512-byte small bins,
  manager-supplied MTU slot size, preallocation, coarse growth, free/reuse, and
  basic pressure counters. The pool remains independent of `utp.zig` to avoid
  an import cycle.
- Made `UtpManager` own/deinit a packet pool and optionally preallocate it at
  UDP listener startup when uTP is enabled. Runtime transport reconciliation now
  also preallocates the pool if a DHT-only UDP listener is later used for uTP.
- Converted retained outbound SYN/DATA/FIN packets from inline datagram storage
  to `UtpPacketHandle` ownership. ACK, SACK, socket teardown, and manager slot
  teardown return handles to the pool; compaction only moves metadata for still
  owned handles.
- Moved DATA sequence advancement to successful `bufferSentPacket` retention so
  packet-pool exhaustion reports a packetization error without leaking a handle
  or creating an unsent sequence gap.
- Replaced the established-connection max-RTO close path with configured
  SYN/FIN/DATA resend-limit handling while preserving the separate
  unconfirmed-connect timeout/fallback path.

## What was learned

- `test-utp` imports the root module deeply enough to compile the new source-side
  tests once `src/net/root.zig` pulls in `utp_packet_pool.zig`.
- Keeping `UtpManager.init()` non-preallocating avoids large default test
  allocations while `initWithSettings(..., preallocate_pool=true)` covers daemon
  startup.
- Direct `UtpSocket` tests need an explicit test packet pool now that retained
  outbound datagrams no longer live inline inside `OutPacket`.
- `createDataPacket` must not be the state-commit point: allocation pressure is
  only known when the full datagram is retained, so `bufferSentPacket` is the
  correct place to advance the DATA sequence and send timestamp.

## Remaining issues or follow-up

- Pool pressure currently propagates as packetization/backpressure errors. More
  nuanced per-socket pressure policy and telemetry can still be added once real
  swarm behavior shows which sockets should be favored under pressure.
- FIN ACK completion still follows the pre-existing state model; this milestone
  only made FIN retained/retransmittable and bounded by the configured resend
  limit.
- Real-swarm telemetry should validate the current small/MTU split and growth
  chunk defaults.

## Key references

- `src/config.zig:35` - reusable byte-size parser.
- `src/config.zig:317` - network uTP packet-pool and timeout defaults.
- `src/net/utp_settings.zig:3` - `UtpSettings` defaults and millisecond helpers.
- `src/net/ledbat.zig:42` - configurable LEDBAT target delay.
- `src/net/utp_packet_pool.zig:3` - standalone pool config with caller-supplied
  MTU slot size.
- `src/net/utp.zig:207` - `OutPacket` pool-handle ownership.
- `src/net/utp.zig:581` - FIN creation now retains the FIN packet.
- `src/net/utp.zig:667` - configured resend-limit timeout decision.
- `src/net/utp.zig:878` - pool-backed outbound packet retention.
- `src/net/utp_manager.zig:36` - manager-owned settings and packet pool.
- `src/net/utp_manager.zig:66` - late packet-pool preallocation helper.
- `src/io/utp_handler.zig:1101` - resend-limit timeout close/reset path.
- `src/io/event_loop.zig:1896` - runtime transport reconciliation preallocates
  the pool when uTP is enabled after UDP startup.
- `src/main.zig:183` - daemon config to uTP settings wiring.
