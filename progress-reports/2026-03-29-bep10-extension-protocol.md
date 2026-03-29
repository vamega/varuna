# BEP 10 Extension Protocol

## What was done

Implemented BEP 10 (Extension Protocol) negotiation for the varuna BitTorrent daemon. This is a prerequisite for MSE encryption, ut_metadata (magnet links), and PEX.

### Changes

1. **New file `src/net/extensions.zig`**: Constants, encode/decode for extension handshakes, reserved bit helpers, wire frame serialization. Includes 10 tests covering roundtrip encode/decode, edge cases, and frame formatting.

2. **Modified `src/net/peer_wire.zig`**: `serializeHandshake()` now sets bit 20 (byte 5, bit 4) in the reserved field to advertise BEP 10 support. Added `msg_extension` constant (ID 20). Updated handshake test to expect the extension bit.

3. **Modified `src/io/event_loop.zig`**:
   - Added `extensions_supported` and `extension_ids` fields to `Peer` struct.
   - Added `extension_handshake_send` and `inbound_extension_handshake_send` peer states.
   - Outbound handshakes (both `handleConnect` and inbound response) set the BEP 10 reserved bit.
   - After receiving a peer's handshake, checks the reserved bit. If both sides support extensions, sends our extension handshake (advertising ut_metadata=1, ut_pex=2, listen port, client="varuna") before proceeding with interested/bitfield/unchoke.
   - `processMessage()` handles message ID 20: sub-ID 0 parses the peer's extension map and stores it; sub-ID > 0 logs and ignores (stub for future handlers).
   - Extracted `sendInterestedAndGoActive()` and `sendInboundBitfieldOrUnchoke()` helpers to reduce duplication.

4. **Updated `src/net/root.zig`**: Added `extensions` module export.
5. **Updated `STATUS.md`**: Moved BEP 10 to Done.

### Handshake flow

Outbound peer: connect -> send handshake (with BEP 10 bit) -> recv handshake -> if peer supports BEP 10: send extension handshake -> send interested -> active

Inbound peer: recv handshake -> send handshake (with BEP 10 bit) -> if peer supports BEP 10: send extension handshake -> send bitfield -> send unchoke -> active

## What was learned

- The BEP 10 extension bit is at reserved[5] & 0x10, which is bit 20 counting from the MSB of byte 0 (i.e., byte 5, bit 4 from LSB within that byte).
- The extension handshake is sent as a normal message (ID 20, sub-ID 0) with bencoded payload. It must be sent after the BT handshake but before or alongside other messages.
- The event loop's `send_pending` flag means only one send can be in-flight per peer at a time, so the extension handshake must be a separate state in the state machine.
- The `handshake_buf` in the event loop stores the raw 68-byte handshake including reserved bytes at offsets [20..28] relative to the buffer start.

## Remaining work

- **ut_metadata (BEP 9)**: actual metadata exchange handlers (currently just advertised).
- **ut_pex (BEP 11)**: peer exchange handlers (currently just advertised).
- **MSE encryption (BEP 6)**: message stream encryption, which depends on BEP 10 being in place.

## Code references

- `src/net/extensions.zig` (entire file): BEP 10 constants, encode/decode, tests
- `src/net/peer_wire.zig:46`: reserved bit set in serializeHandshake
- `src/io/event_loop.zig:63-65`: new PeerState values
- `src/io/event_loop.zig:117-118`: new Peer fields
- `src/io/event_loop.zig:1296-1322`: extension message handling in processMessage
- `src/io/event_loop.zig:2109-2161`: submitExtensionHandshake, sendInterestedAndGoActive, sendInboundBitfieldOrUnchoke helpers
