# Peer mode vs swarm role — fixing the large-20m-64k flake

## What changed

Three related bugs in the peer state machine all stemmed from conflating
`peer.mode` (which side opened the TCP connection) with the peer's role in
the swarm (who is the leecher, who is the seeder):

1. **REQUEST handler refused to serve outbound-mode peers.**
   `protocol.zig` `id=6` (REQUEST) gated on `peer.mode == .inbound`. When
   a seeder dialed out to a leecher (because the tracker handed it the
   leecher's address), its peer record for the leecher had
   `mode=outbound`, and the seeder silently dropped every REQUEST it
   received. The leecher's pipeline emptied with no PIECE responses and
   the download stalled until timeout.

2. **INTERESTED auto-unchoke was gated on `mode == .inbound`.**
   Same misconception: we'd wait up to `unchoke_interval_secs` (10 s)
   for the next `recalculateUnchokes` tick to unchoke an outbound-mode
   peer that had just declared interest. In the loopback test this
   hurt tail latency but didn't stall; in production it was an unneeded
   delay in the first-piece path.

3. **Outbound peers never sent BITFIELD.**
   `handleSend .extension_handshake_send` jumped directly to
   `sendInterestedAndGoActive`, so an outbound peer never advertised its
   pieces. When the seeder initiated the connection, the remote side
   never learned the seeder had any pieces, so `maybeSendInterested`
   (see below) had nothing to interest it in, and the swarm deadlocked.

4. **Inbound peers never declared interest.**
   The inbound state flow ended at
   `active_recv_header` after BITFIELD+UNCHOKE, with `am_interested`
   never set. When the downloader received the connection (as inbound)
   from a seeder, it read the seeder's BITFIELD but had no code path
   to turn that into an INTERESTED message, so the seeder never
   unchoked it.

## Fixes

- `src/io/types.zig`: new `outbound_bitfield_send` state between
  `extension_handshake_send` and `active_recv_*`.
- `src/io/protocol.zig`:
  - Added `sendOutboundBitfieldThenInterested` (mirrors
    `sendInboundBitfieldOrUnchoke` but without the unchoke).
  - Added `maybeSendInterested` (called from the BITFIELD and HAVE
    handlers; sends INTERESTED once, only when `am_interested=false`
    and the peer advertises at least one piece not in our
    `complete_pieces`).
  - Dropped the `peer.mode == .inbound` gate from the REQUEST handler
    (`id=6`) and from the INTERESTED auto-unchoke handler (`id=2`).
- `src/io/peer_handler.zig`: `.extension_handshake_send` send-completion
  now routes through `sendOutboundBitfieldThenInterested`, with a
  matching `.outbound_bitfield_send` case that then sends INTERESTED and
  enters `active_recv`.

## Why this only surfaced on large-20m-64k

The bugs trigger when a seeder dials an outbound connection to a
leecher, i.e. when the seeder's outbound wins the race against the
leecher's own outbound. The window is short and depends on:

- how long recheck takes on each side (larger payloads = longer recheck
  on the seeder, shifting the order of the first tracker announce),
- tracker response ordering,
- TCP SYN/SYN-ACK timing on loopback.

The 20 MiB / 64 KiB shape (320 pieces) seems to fall in the window where
the seeder lands its outbound connection first often enough to flake
~1 in 3-4 runs. Smaller torrents either race the other way or complete
inside the pre-existing 10 s unchoke window.

In production all four bugs are still real: any cross-dial — e.g. a
DHT peer list hands us a seeder's address while another seeder
reciprocally dials us — would hit the same stall.

## Verification

- `bash /tmp/repro_fast.sh`: 15 consecutive clean runs (before: flaked
  every 3-4 runs on large-20m-64k).
- `zig build test`: passes.

## Residual

- The kernel still emits occasional `user_data=0` CQEs during these
  transfers — filtered by `OpType.invalid` in dispatch (commit
  `7b537fd`). Root cause still unknown, but the symptom is benign.
- The `is_seeding` calculation in `recalculateUnchokes` treats the
  presence of any outbound-mode peer as "not seeding," which sorts
  interested peers by download speed rather than upload speed. Probably
  wants fixing alongside this, but only affects sort order, not
  correctness.

## Key references

- `src/io/protocol.zig:77-95` — INTERESTED handler (auto-unchoke fix)
- `src/io/protocol.zig:119-170` — BITFIELD/HAVE → maybeSendInterested
- `src/io/protocol.zig:155-173` — REQUEST handler (mode gate removed)
- `src/io/protocol.zig:690-730` — maybeSendInterested + sendOutboundBitfieldThenInterested
- `src/io/peer_handler.zig:377-392` — outbound state transitions
- `src/io/types.zig:101` — new `outbound_bitfield_send` state
