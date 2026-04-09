# 2026-04-09: Net uTP And PEX Correctness Fixes

## What was done and why

Fixed the protocol-routing issues that could misattribute uTP packets and permanently lose PEX deltas.

- `src/net/utp_manager.zig:70` now routes non-SYN packets by remote address plus `recv_id`, not just `recv_id`. This prevents one remote peer from colliding with another peer that happens to reuse the same connection ID.
- `src/net/utp_manager.zig:248` now emits RESET packets with the real remote address instead of an undefined address, so unknown-connection resets go back to the sender that triggered them.
- `src/net/pex.zig:261` now updates `sent_peers` incrementally from the peers actually emitted in the current message. The old logic eagerly removed all dropped peers from `sent_peers`, even when the `max_dropped_per_message` cap prevented those peers from being reported.

## What was learned

- uTP connection IDs are only unique within the context of the remote endpoint. Treating them as globally unique inside the socket multiplexer is incorrect.
- Delta protocols need bookkeeping based on what was actually serialized, not what the producer wanted to serialize before message size caps were applied.

## Remaining issues / follow-up

- This pass did not yet land the web-seed multi-file path generation fix or the metadata-fetch info-hash validation from the broader Wave 2.3 review.
- `findByRecvId` is now effectively superseded by the remote-aware lookup path. If the manager gets another cleanup pass, remove or narrow the old helper.

## Code references

- `src/net/utp_manager.zig:70`
- `src/net/utp_manager.zig:188`
- `src/net/utp_manager.zig:235`
- `src/net/utp_manager.zig:248`
- `src/net/pex.zig:261`
- `src/net/pex.zig:360`
