# uTP Inbound State Machine Fix — Extension Handshake Stall

**Date:** 2026-04-15

## The Bug

uTP data transfer was broken end-to-end despite the seq_nr off-by-one fix.
The demo_swarm with `enable_utp = true` connected, completed BT + extension
handshakes, but never transferred piece data (progress stayed at 0%).

## Root Cause

In `utp_handler.zig`, the inbound peer (seeder) state machine stalled after
sending the BEP 10 extension handshake. The `handleUtpSendComplete` function
for the `.inbound_handshake_send` case set the state to
`.inbound_extension_handshake_send` and called `submitUtpExtensionHandshake`,
but did NOT call `handleUtpSendComplete` to advance the state machine.

The peer stayed in `.inbound_extension_handshake_send` forever. When the
downloader's extension handshake, INTERESTED message, and REQUEST messages
arrived, `deliverUtpData`'s switch statement hit the `else => {}` catch-all
and **silently dropped all incoming data**.

The outbound path (line 421) correctly called `handleUtpSendComplete` after
`submitUtpExtensionHandshake`. The inbound path was missing this call.

## Fix

One line: added `handleUtpSendComplete(self, peer_slot);` after the successful
`submitUtpExtensionHandshake` in the `.inbound_handshake_send` case. This drives
the state machine forward through BITFIELD → UNCHOKE → `active_recv_header`,
matching the outbound flow pattern.

## Verification

- `zig build test-utp`: all 3 byte stream tests pass
- `demo_swarm.sh` with `enable_utp = true`: passes (progress=1.0)
- 3x stability runs: all pass

## Key Code Reference

- Fix: `src/io/utp_handler.zig:535` — added `handleUtpSendComplete(self, peer_slot);`
- Root cause: asymmetry between outbound (line 421, had the call) and inbound (line 528, missing)
