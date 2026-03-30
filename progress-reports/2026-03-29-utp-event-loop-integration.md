# uTP Event Loop Integration

## What was done

Wired the existing uTP protocol layer (UtpSocket, UtpManager, LEDBAT) into the
io_uring event loop so the daemon can accept inbound uTP peer connections.

### Changes

**`src/io/event_loop.zig`** -- main integration point:
- Added `utp_recv = 11` and `utp_send = 12` OpType variants for io_uring CQE dispatch.
- Added `Transport` enum (`tcp`, `utp`) and `utp_slot` field to `Peer` struct.
- Added UDP socket fields: `udp_fd`, `utp_manager`, persistent recv/send buffers, msghdr structs, send queue.
- `startUtpListener()`: creates UDP socket (SOCK_DGRAM), binds to daemon port, initializes UtpManager, submits first RECVMSG.
- `submitUtpRecv()` / `submitUtpSend()`: io_uring RECVMSG/SENDMSG SQE helpers using persistent msghdr buffers.
- `handleUtpRecv()`: CQE handler that dispatches datagrams to UtpManager.processPacket(), sends response packets, accepts new connections, delivers data.
- `handleUtpSend()`: CQE handler that drains the outbound packet queue.
- `acceptUtpConnection()`: creates Peer entries for accepted uTP connections (analogous to handleAccept for TCP).
- `deliverUtpData()`: bridges uTP ordered byte stream into the peer wire protocol state machine (handshake recv, header recv, body recv).
- `processUtpInboundHandshake()`: handles BitTorrent handshake over uTP, matches info_hash to registered torrents.
- `handleUtpSendComplete()`: drives the uTP peer through the inbound state machine (handshake -> extension handshake -> bitfield -> unchoke -> active).
- `utpTick()`: periodic timeout processing -- checks all uTP connections for RTO expiry, closes stale ones.
- `cleanupPeer()`: extended to reset uTP slots on peer removal.
- Send queue (`utp_send_queue`): since only one SENDMSG SQE can be in flight at a time, packets are queued and drained on completion.

**`src/net/utp.zig`**:
- Made `makeAck()` public (needed by UtpManager for duplicate SYN handling).

**`src/net/ledbat.zig`**:
- Fixed Zig 0.15 signed integer division: replaced `/` with `@divTrunc` for `i64` operands.

**`STATUS.md`**: updated uTP status from "event loop integration pending" to done.

### Design decisions

- **Single UDP socket**: one SOCK_DGRAM fd handles all uTP connections, multiplexed by UtpManager.
- **Persistent msghdr buffers**: recv and send msghdr structs are stored in EventLoop (not stack-allocated) so they remain valid while io_uring processes the SQE.
- **Send queue**: only one SENDMSG can be in flight at a time (single send buffer). Additional packets queue in an ArrayList and drain on CQE completion.
- **Inbound only (v1)**: only inbound uTP connections are handled. Outbound uTP connect is deferred.
- **No TCP fd for uTP peers**: uTP peers have `fd = -1` and `transport = .utp`. Data flows through the UtpSocket byte stream, not io_uring recv SQEs.
- **Synchronous state machine advance**: since uTP sends don't produce per-peer CQEs, `handleUtpSendComplete` is called immediately after queuing the send, driving the handshake state machine forward without waiting for CQE dispatch.

## What was learned

- Zig's `linux.IoUring.recvmsg()` takes `*posix.msghdr` (mutable) while `sendmsg()` takes `*const posix.msghdr_const`. The msghdr must outlive the SQE -- storing it as a struct field is essential.
- `std.net.Address` cannot be formatted with `{}` in Zig 0.15 -- must use `{any}` to avoid ambiguous format string errors.
- Zig 0.15 requires `@divTrunc` for signed integer division -- plain `/` is a compile error for `i64`.
- The uTP protocol reuses connection_id for routing, so the UtpManager's `findByRecvId` linear scan works for moderate connection counts but may need a hash map at scale.

## Remaining work

- **Outbound uTP connections**: `addPeerForTorrent` currently always creates TCP connections. Need a variant that initiates uTP handshakes.
- **uTP peer send path**: piece responses and other messages for uTP peers currently use `utpSendData` which creates individual DATA packets. Large messages (piece blocks) may need fragmentation across multiple uTP packets.
- **Partial data delivery**: `deliverUtpData` handles one chunk at a time. If a uTP packet delivers data that spans multiple peer wire messages, the recursive call handles it, but this should be verified under load.
- **Integration testing**: need an end-to-end test with a uTP peer connecting and downloading a piece.

## Key file references

- `src/io/event_loop.zig`: lines ~220 (Transport enum), ~640 (startUtpListener), ~700 (submitUtpRecv/Send), ~960 (handleUtpRecv), ~1050 (acceptUtpConnection), ~1090 (deliverUtpData), ~1260 (utpTick)
- `src/net/utp.zig:522` (makeAck now pub)
- `src/net/ledbat.zig:115-116` (divTrunc fix)
