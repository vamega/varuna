# Piece Buffer Memory Leak After Hash Verification

**Date:** 2026-03-27
**Status:** Fixed

## The Problem

When a piece finishes downloading, the event loop submits the piece buffer to the SHA-1 hasher threadpool for verification. If the hash is valid, the buffer is then used as the source for an `IORING_OP_WRITE` to disk. The buffer is never freed.

The leak is reported by Zig's GPA (GeneralPurposeAllocator) at shutdown:
```
error(gpa): memory address 0x70d891ec00a0 leaked:
/home/vmadiath/projects/varuna/src/io/event_loop.zig:691:50: in startPieceDownload
    peer.piece_buf = try self.allocator.alloc(u8, piece_size);
```

## The Lifecycle of a Piece Buffer

1. **Allocated** in `startPieceDownload` (`event_loop.zig:691`):
   ```zig
   peer.piece_buf = try self.allocator.alloc(u8, piece_size);
   ```

2. **Filled** as piece message CQEs arrive in `processMessage` (`event_loop.zig:562-576`):
   Block data is `@memcpy`'d into `peer.piece_buf` at the correct offset.

3. **Handed to hasher** in `completePieceDownload` (`event_loop.zig:735-744`):
   ```zig
   h.submitVerify(slot, piece_index, piece_buf, hash);
   peer.piece_buf = null;  // ownership transferred to hasher
   peer.current_piece = null;
   ```
   The peer releases ownership so it can start downloading another piece.

4. **Hashed** on a threadpool worker (`hasher.zig:154-158`):
   The hasher computes SHA-1 and pushes a `Result` containing the piece_buf pointer.

5. **Disk write submitted** in `processHashResults` (`event_loop.zig:766-770`):
   ```zig
   for (plan.spans) |span| {
       const block = result.piece_buf[span.piece_offset..];
       _ = self.ring.write(ud, self.shared_fds[span.file_index], block, span.file_offset);
   }
   ```
   The `IORING_OP_WRITE` SQE references `result.piece_buf` as the source buffer.

6. **LEAK**: The buffer is never freed. It can't be freed in `processHashResults` because the io_uring write SQE still references it. And `handleDiskWrite` doesn't have access to the buffer pointer.

## Why It's Tricky

io_uring writes are asynchronous. When we call `ring.write(...)`, it queues an SQE that the kernel will process later. The kernel reads from our buffer at an unknown future time (could be immediately, could be after several ticks). Freeing the buffer before the CQE arrives would cause a use-after-free in the kernel's page-fault handler.

For multi-span pieces (file spans across multiple files), there are multiple write SQEs referencing different regions of the same buffer. We can only free the buffer after ALL spans have completed.

## Fix Strategy

Track pending writes with their associated buffers. When the last write CQE for a piece arrives, free the buffer.

Approach: maintain a `pending_writes` list in the EventLoop that maps `piece_index -> { buf, spans_remaining }`. Each `handleDiskWrite` CQE decrements `spans_remaining`. When it hits 0, free the buffer.

## Code References

- `startPieceDownload`: `src/io/event_loop.zig:685-700`
- `completePieceDownload`: `src/io/event_loop.zig:720-753`
- `processHashResults`: `src/io/event_loop.zig:757-778`
- `handleDiskWrite`: `src/io/event_loop.zig:484-498`
- `Hasher.workerFn`: `src/io/hasher.zig:147-167`

## Fix Applied

Added `pending_writes: ArrayList(PendingWrite)` to EventLoop where each entry tracks `{ piece_index, buf, spans_remaining }`.

- In `processHashResults`: after submitting write SQEs for a verified piece, create a `PendingWrite` entry with `spans_remaining = plan.spans.len`.
- In `handleDiskWrite`: find the matching `PendingWrite` by piece_index, decrement `spans_remaining`. When it hits 0, call `piece_tracker.completePiece()` and free the buffer.
- In `deinit`: free any remaining pending write buffers (for unclean shutdown).

The fix was verified: `demo_swarm.sh` passes with no `error(gpa)` leak reports.

## Learnings

1. **io_uring buffer lifetime**: Any buffer referenced by an SQE must live until the CQE. This is a fundamental constraint that doesn't exist with synchronous I/O. Need a systematic approach to buffer ownership tracking.

2. **Multi-span writes**: A single piece can span multiple files, generating multiple write SQEs from one buffer. The buffer can only be freed after all SQEs complete.

3. **Ownership transfer chains**: The piece buffer passes through 4 owners (peer -> hasher -> processHashResults -> io_uring kernel). Each handoff needs clear ownership semantics.
