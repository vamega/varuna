# 2026-05-01 Peer Protocol Hardening

## What changed and why

- Added shared peer-wire validation for the BitTorrent handshake prefix and fixed-size message payload lengths so TCP, uTP, and blocking peer-wire parsing use one protocol check.
- TCP and uTP handshake receive paths now reject handshakes with an invalid `pstrlen` or protocol string before matching info hashes.
- TCP and uTP body-completion paths now stop immediately when `processMessage` removes a peer, preventing a freed slot from being re-armed for the next header.
- `processMessage` now removes peers that send malformed fixed-size peer-wire payloads for choke/unchoke/interested/not-interested/have/request/piece/cancel/port.

## What was learned

- `processMessage` intentionally owns some disconnect decisions, so callers that continue receive state after it returns must check whether the slot is still live.
- The blocking peer-wire reader already enforced most fixed-size payload lengths; the event-loop path needed to share that strictness.
- The local aarch64/Nix test environment can run many focused tests, but the full suite is currently blocked by unrelated SQLite pointer-alignment and BoringSSL inline-assembly compile failures.

## Remaining issues or follow-up

- `zig build test` should be rerun in a supported Zig 0.15.2 environment after the existing `src/storage/sqlite3.zig` `SQLITE_TRANSIENT` alignment issue and BoringSSL aarch64 inline asm issue are addressed.
- Consider adding a dedicated `zig build test-peer-protocol` target if peer-wire/event-loop protocol hardening remains a repeated hotspot.

## Key references

- `src/net/peer_wire.zig:97` shared handshake prefix validator
- `src/net/peer_wire.zig:109` shared fixed-size payload length validator
- `src/io/protocol.zig:37` event-loop payload length rejection
- `src/io/peer_handler.zig:709` TCP outbound handshake prefix validation
- `src/io/peer_handler.zig:765` TCP inbound handshake prefix validation
- `src/io/peer_handler.zig:867` TCP body completion stops after peer removal
- `src/io/utp_handler.zig:370` uTP handshake delivery stops after peer removal
- `src/io/utp_handler.zig:444` uTP body delivery stops after peer removal
- `src/io/utp_handler.zig:473` uTP outbound handshake prefix validation
- `src/io/utp_handler.zig:512` uTP inbound handshake prefix validation
