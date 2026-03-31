# uTP Outbound Connections

## What was done

Implemented outbound uTP connections, completing the uTP transport layer so
Varuna can both accept and initiate uTP peer connections.

### Changes

**UtpSocket (`src/net/utp.zig`)**:
- Added `allocator` field and `deinit()` method for owned buffer cleanup.
- `OutPacket` now owns a heap-allocated copy of the full datagram (`packet_buf`)
  for retransmission, replacing the old borrowed `data: []const u8` slice.
- `connect()` now stores the SYN in the outbound buffer for retransmission.
- Added `bufferSentPacket()` public API for callers to register sent packets.
- `bytesInFlight()` now tracks actual payload sizes instead of estimating
  with unacked_count * MSS.
- `handleTimeout()` marks the oldest unacked packet for retransmit (was no-op).
- Added `collectRetransmits()` to gather packets needing re-send, updating
  timestamps in headers before retransmission.
- `processAck()` frees owned buffers when packets are acknowledged, and
  triggers fast retransmit on triple duplicate ACK.
- Added `RetransmitEntry` type.
- Added `max_payload` constant.

**UtpManager (`src/net/utp_manager.zig`)**:
- `connect()` and `handleSyn()` now set `allocator` on new sockets.
- `freeSlot()` calls `socket.deinit()` to free outbound buffers.
- Added `collectRetransmits()` to gather retransmits across all connections.
- Added `RetransmitResult` type.

**Event loop (`src/io/event_loop.zig`)**:
- Added `addUtpPeer()` method for initiating outbound uTP connections.
  Handles connection limits, half-open tracking, SYN sending.
- Fixed `UtpQueuedPacket` buffer size from `Header.size` (20 bytes) to
  1500 bytes. The old size silently truncated data packets to header-only
  when queued behind another send.

**uTP handler (`src/io/utp_handler.zig`)**:
- Added `checkOutboundUtpConnect()`: detects when a uTP socket transitions
  to connected after SYN-ACK and starts the peer wire handshake.
- Added `processUtpOutboundHandshake()`: validates the peer's handshake
  response, sends BEP 10 extension handshake if supported.
- Added `sendUtpInterestedAndGoActive()`: sends interested message and
  transitions to active download mode.
- Updated `handleUtpSendComplete()` to handle outbound flow states
  (extension_handshake_send, active_recv_*).
- Updated `deliverUtpData()` to handle `handshake_recv` state for outbound
  peers receiving the peer's handshake response.
- `utpSendData()` now calls `bufferSentPacket()` to store packets for
  retransmission.
- `utpTick()` now collects and retransmits timed-out packets instead of
  only closing connections.
- Fixed `utpSendPacket()` queue truncation bug (was truncating to 20 bytes).

### Tests added (13 new tests)

In `src/net/utp.zig`:
- `connect stores SYN in outbound buffer for retransmission`
- `outbound data packet is buffered for retransmission`
- `timeout marks oldest unacked packet for retransmission`
- `acked packets are freed from outbound buffer`
- `triple duplicate ACK triggers fast retransmit`
- `three-way handshake with retransmission buffer`
- `bytesInFlight tracks actual payload sizes`

In `src/net/utp_manager.zig`:
- `manager connect sets allocator on socket`
- `manager handshake with retransmission and data exchange`
- `manager collectRetransmits returns timed-out packets`
- `manager freeSlot cleans up outbound buffers`

## What was learned

- The existing `UtpQueuedPacket` had a data truncation bug: its buffer was
  sized to `Header.size` (20 bytes), so any data packet queued while a send
  was in flight lost its payload. This would have caused silent data corruption
  for uTP peers under load.

- uTP retransmission requires owned copies of sent datagrams because the
  original send buffers are reused immediately. The `OutPacket` struct was
  redesigned to own heap-allocated copies that are freed on ACK or connection
  teardown.

- The outbound uTP handshake flow mirrors TCP but is event-driven differently:
  TCP uses io_uring connect CQE -> send CQE -> recv CQE chain, while uTP
  uses packet-driven state transitions (SYN-ACK arrival triggers handshake
  send, data delivery drives handshake recv).

## Remaining work

- The outbound flow is wired but not yet called from the announce/peer
  discovery path. The `addUtpPeer()` method is available; callers (tracker
  announce, PEX) need to decide TCP vs uTP based on peer flags or preference.
- Selective ACK-based retransmission (resend specific gaps, not just oldest).
- uTP path MTU discovery.

## Key code references

- `src/net/utp.zig:248` - `connect()` with outbuf storage
- `src/net/utp.zig:466` - `bufferSentPacket()` public API
- `src/net/utp.zig:508` - `handleTimeout()` with retransmit marking
- `src/net/utp.zig:530` - `collectRetransmits()`
- `src/io/event_loop.zig:626` - `addUtpPeer()`
- `src/io/utp_handler.zig:167` - `checkOutboundUtpConnect()`
- `src/io/utp_handler.zig:210` - `processUtpOutboundHandshake()`
