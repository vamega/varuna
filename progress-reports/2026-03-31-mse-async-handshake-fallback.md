# MSE Async Handshake State Machine + Auto-Fallback

**Date:** 2026-03-31

## What was done

Completed two remaining MSE (BEP 6) integration items for the daemon event loop:

### 1. Async MSE handshake state machine

The existing blocking `handshakeInitiator`/`handshakeResponder` in `src/crypto/mse.zig` use
synchronous Ring I/O (submit one SQE, wait for CQE). The daemon's single-threaded io_uring
event loop cannot block, so a non-blocking async version was needed.

Added two state machine types:

- `MseInitiatorHandshake` (outbound connections): phases are send_dh_key -> recv_dh_key ->
  send_crypto_req -> recv_vc_scan -> recv_crypto_select -> recv_pad_d -> done.
- `MseResponderHandshake` (inbound connections): phases are recv_dh_key -> send_dh_key ->
  recv_req1_scan -> recv_req2 -> recv_enc_header -> recv_pad_c_ia_len -> recv_ia ->
  send_crypto_resp -> done.

Each `feedSend()` / `feedRecv(n)` call returns an `MseAction` union:
- `.send` -- submit an io_uring send with the given buffer
- `.recv` -- submit an io_uring recv into the given buffer
- `.complete` -- handshake done, extract PeerCrypto
- `.failed` -- handshake failed with specific error

The state machines own their send/recv buffers (stack-allocated, no heap needed),
handle partial recv transparently, and manage their own RC4 cipher state.

### 2. Event loop integration

- Added `PeerState` variants: `mse_handshake_send`, `mse_handshake_recv`,
  `mse_resp_send`, `mse_resp_recv`.
- Added per-peer fields: `mse_initiator`, `mse_responder` (heap-allocated state
  machine pointers), `mse_rejected`, `mse_fallback`.
- `handleConnect` (src/io/peer_handler.zig): after TCP connect completes, checks
  encryption mode and starts MSE initiator handshake when appropriate, or goes
  directly to BT handshake.
- `handleSend`/`handleRecv`: dispatch to MSE state machine when peer is in an
  MSE handshake state.
- `handleAccept` path: on first received byte of inbound connections, detects
  whether the byte looks like MSE (not 0x13) or BT protocol (0x13), and starts
  the MSE responder handshake accordingly.

### 3. Auto-fallback

- **Outbound "preferred" mode**: if MSE handshake fails (send error, recv error, or
  state machine failure), the peer connection is closed and a new plaintext TCP
  connection is established to the same address. The `mse_fallback` flag prevents
  infinite retry loops.
- **Outbound "forced" mode**: MSE failure disconnects the peer (no fallback).
- **Outbound "enabled" mode**: MSE is not initiated (only accepted inbound).
- **Outbound "disabled" mode**: skip MSE entirely.
- **Inbound detection**: first byte heuristic (0x13 = BT, anything else = MSE).
  In "forced" mode, plaintext BT handshakes are rejected.
- **Per-peer tracking**: `mse_rejected` prevents retrying MSE on reconnect to a
  peer that previously failed MSE.

## Key files

- `src/crypto/mse.zig:832-1308` -- `MseInitiatorHandshake`, `MseResponderHandshake`,
  `MseAction`, `looksLikeMse`, and 13 async state machine tests.
- `src/io/event_loop.zig:80-97` -- new PeerState variants.
- `src/io/event_loop.zig:148-153` -- new Peer fields (mse_initiator, mse_responder, etc.).
- `src/io/peer_handler.zig:69-162` -- `handleConnect` rewrite with MSE start.
- `src/io/peer_handler.zig:542-810` -- `executeMseAction`, `handleMseFailure`,
  `attemptMseFallback`, `startMseResponder`, `detectAndHandleInboundMse`.
- `src/io/peer_handler.zig:388-402` -- inbound MSE detection in `handleRecv`.

## What was learned

- The MSE state machine fits naturally into the CQE-driven event loop because each
  MSE protocol phase is either a send or a recv -- the same op types already used for
  BT handshakes. No new OpType values were needed.
- The MseResponderHandshake is more complex than the initiator because it must scan
  for the req1 hash in a stream that includes variable-length padding. The scan buffer
  accumulates data across multiple recv calls.
- Stack-allocated buffers in the state machine structs (1280 bytes send, ~1088 bytes
  scan) are large enough for MSE without heap allocation during the handshake itself.
  The state machine structs themselves are heap-allocated (one per peer in handshake).
- The first-byte heuristic (0x13 vs anything else) is the standard way to detect MSE
  vs plaintext BT. It works because BT handshake always starts with the protocol
  string length byte (19 = 0x13), while MSE starts with a DH public key which is
  random data (probability of leading 0x13 is ~1/256).

## Remaining work

- End-to-end integration test with two event loops performing MSE handshake over
  a socket pair (currently tested with blocking Ring, not async event loop).
- The responder's `startMseResponder` collects known_hashes from torrents into a
  stack array -- if the hash count exceeds 64, some will be missed. This is fine
  for the current max_torrents=64 limit.
