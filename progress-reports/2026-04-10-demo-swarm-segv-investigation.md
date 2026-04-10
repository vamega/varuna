# Demo Swarm SEGV Investigation

**Date:** 2026-04-10
**Status:** In progress — crash identified, root cause narrowed but not yet fixed.

## The Bug

The seeder daemon SEGVs when two MSE-encrypted peers connect simultaneously during the demo_swarm test. The crash occurs after both peers complete MSE handshakes and exchange BEP 10 extension messages.

## What We Know

### Crash characteristics
- Raw SIGSEGV with no Zig stack trace (even with `attachSegfaultHandler`)
- Crashes at varying points: sometimes during MSE handshake, sometimes after BITFIELD/UNCHOKE exchange
- Reproduces in both Debug (GPA) and ReleaseSafe modes
- Does NOT crash when a single plain-text peer connects
- Always involves two simultaneous MSE-encrypted peers (one outbound from tracker announce, one inbound from the remote peer's announce)

### Protocol exchange before crash (from debug logging)
```
slot 0: MSE handshake complete (initiator, RC4)
slot 1: MSE handshake complete (responder, RC4)
slot 0: peer extensions: ut_metadata=1 ut_pex=2
slot 1: peer extensions: ut_metadata=1 ut_pex=2
processMessage: slot=0 id=5  (BITFIELD from peer)
processMessage: slot=1 id=2  (INTERESTED from peer)
processMessage: slot=0 id=1  (UNCHOKE from peer)
[SEGFAULT]
```

### What we ruled out
- **GPA memory poisoning**: crash persists in ReleaseSafe with standard allocator
- **cancelRecheck UAF**: crash persists when recheck is intentionally leaked
- **Recheck handleHashResult self-use-after-free**: fixed (saved allocator locally) but crash unrelated
- **TrackerExecutor completeSlot UAF**: fixed (body copy before reset) — this was the announce 400 bug, separate issue

### Likely root cause
The crash occurs in non-safety-checked code (pointer dereference from io_uring buffer handling, `@ptrCast`, or encrypted buffer manipulation). The varying crash point suggests either:
1. A buffer overwrite in the MSE RC4 encrypt/decrypt path that corrupts adjacent memory
2. An io_uring SQE referencing a buffer that's been freed or reallocated
3. A slot reuse race where a CQE from a previous connection arrives for a new peer in the same slot

### Key files involved
- `src/io/peer_handler.zig` — handleRecv, handleSend, executeMseAction
- `src/io/protocol.zig` — processMessage, submitMessage, sendInboundBitfieldOrUnchoke
- `src/crypto/mse.zig` — MseInitiatorHandshake, MseResponderHandshake, PeerCrypto.decryptBuf

## Bugs Fixed During Investigation

1. **Recheck handleHashResult self-use-after-free** (`src/io/recheck.zig:206`): `defer self.allocator.free(piece_buf)` accessed `self.allocator` after `self` was destroyed by the completion callback chain. Fixed by saving allocator in a local.

2. **Recheck UAF reading freed state** (`src/daemon/torrent_session.zig`): `onRecheckComplete` read `recheck.complete_pieces.count` after `cancelRecheck()` freed the recheck struct. Fixed by snapshotting values before destroy.

3. **TrackerExecutor completeSlot body UAF** (`src/daemon/tracker_executor.zig`): Response body slice pointed into `slot.recv_buf` which was freed by `slot.reset()` before the callback read it. Fixed by copying body to owned allocation.

4. **TrackerExecutor tryStartJob dangling pointer** (`src/daemon/tracker_executor.zig`): `parseUrl` was called on by-value `job` parameter, producing path slices into stack memory. Fixed by parsing from `slot.job` after copy.

## Next Steps

1. Get a core dump and analyze with GDB to identify the exact faulting instruction and memory address
2. Check if the crash is in RC4 decrypt, io_uring buffer access, or protocol parsing
3. If it's a buffer overwrite, add bounds checking canaries around MSE buffers
4. If it's a stale CQE, add generation counters to detect slot reuse
