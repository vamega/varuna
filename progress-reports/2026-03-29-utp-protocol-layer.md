# uTP Protocol Layer (BEP 29)

## What was done

Implemented the core uTP (Micro Transport Protocol) protocol layer across three new files:

- **`src/net/ledbat.zig`** -- LEDBAT (RFC 6817) delay-based congestion control. Tracks base delay (minimum one-way delay) with a rotating history, computes congestion window adjustments based on queuing delay relative to the 100ms target. Supports slow start, congestion avoidance, loss response, and RTO timeout collapse.

- **`src/net/utp.zig`** -- Core uTP protocol implementation. Includes:
  - 20-byte BEP 29 packet header encoding/decoding (big-endian, all 5 packet types)
  - Selective ACK extension (bitmask-based gap filling)
  - `UtpSocket` struct: full connection state machine (IDLE, SYN_SENT, SYN_RECV, CONNECTED, FIN_SENT, CLOSED, RESET)
  - Three-way handshake: SYN with random connection_id, SYN-ACK, state transition
  - Packet processing for all types: ST_DATA, ST_FIN, ST_STATE, ST_RESET, ST_SYN
  - RTT estimation with Karn's algorithm (skip retransmitted packets) and RFC 6298 smoothing
  - Receive reorder buffer (64 entries) for out-of-order delivery
  - Send window management integrating LEDBAT cwnd and peer advertised window
  - 16-bit wrapping sequence number arithmetic

- **`src/net/utp_manager.zig`** -- Connection multiplexer. Routes incoming UDP datagrams to the correct UtpSocket by connection_id. Handles SYN packets to create inbound connections with an accept queue. Provides connect/accept/close/reset API. Sends RESET for unknown connection_ids.

## What was learned

- BEP 29 connection_id assignment is asymmetric: the initiator sends SYN with `connection_id = R` (its recv_id), and uses `R+1` as send_id. The responder swaps these. This means the manager must look up by `recv_id` for routing non-SYN packets, and by `connection_id + 1` for duplicate SYN detection.

- LEDBAT's "off-target" calculation needs careful signed arithmetic. The gain formula `(off_target / target) * (bytes_acked / cwnd) * mss` involves both positive and negative values and must avoid integer overflow on the positive side and underflow on the negative side.

- Wrapping 16-bit sequence number comparison (used throughout uTP) maps cleanly to Zig's `-%` wrapping subtraction combined with `@bitCast` to `i16`. The sign of the result tells you the circular ordering.

## Remaining work

- **Event loop integration**: Register a UDP socket with io_uring (`IORING_OP_RECVMSG` / `IORING_OP_SENDMSG`), add `utp_recv`/`utp_send` OpType variants, wire UtpManager into the event loop tick.
- **Outbound retransmission**: The `out_buf` array is defined but not yet populated with actual payload data on send. Full retransmission requires buffering sent data and resending on RTO or triple dup-ACK.
- **Timer integration**: The event loop needs a periodic timer to call `checkTimeouts()` on the UtpManager.
- **Peer coexistence**: PeerState in event_loop.zig needs a transport enum (TCP vs uTP) so both transport types can serve the same torrent session.

## Code references

- `src/net/ledbat.zig:1` -- LEDBAT congestion control
- `src/net/utp.zig:1` -- Header codec, UtpSocket state machine
- `src/net/utp.zig:136` -- seqLessThan/seqDiff wrapping arithmetic
- `src/net/utp_manager.zig:1` -- UtpManager multiplexer
- `src/net/root.zig` -- Module exports updated
