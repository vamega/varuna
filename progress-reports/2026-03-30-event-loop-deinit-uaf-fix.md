# Fix use-after-free in EventLoop.deinit buffer lifecycle

## What was done

Fixed a use-after-free in `EventLoop.deinit()` where heap buffers and the
peers array were freed while the io_uring ring still had pending SQEs
referencing them. Under GPA's debug poison (0xAA fill on free), the kernel
could read/write poisoned memory for any in-flight operations that hadn't
completed yet.

### Root cause

The old `deinit` sequence was:

1. Free pending write/send/read buffers
2. Call `cleanupPeer` on every peer (close fd + free body_buf/piece_buf)
3. Free the peers array (contains inline header_buf, handshake_buf)
4. Call `ring.deinit()`

Between steps 2-3 and step 4, the io_uring kernel side could still have
SQEs in flight that reference the freed buffers. Closing fds (step 2) causes
those operations to be cancelled, but the CQEs for those cancellations were
never drained. The kernel might still be touching buffer memory after it was
freed and poison-filled by GPA.

### Fix: phased deinit

Restructured `deinit` into four phases (`src/io/event_loop.zig:398`):

1. **Close all fds** -- peer fds, listen fd, UDP fd. This causes the kernel
   to cancel pending io_uring operations that reference our buffers, but does
   NOT free any buffers yet.

2. **Drain the ring** -- new `drainRemainingCqes()` helper submits any queued
   SQEs and drains CQEs in batches. After this, the kernel has finished
   touching all buffer memory.

3. **Free all buffers** -- pending writes, pending sends, pending reads, queued
   responses, peer heap buffers (body_buf, piece_buf, availability bitfield),
   and the peers array itself.

4. **Tear down the ring** -- `ring.deinit()` unmaps shared memory.

## What was learned

- io_uring operations are not instantly cancelled when `close(fd)` is called.
  The cancellation completes asynchronously and produces CQEs. If you free
  buffers referenced by SQEs before draining those CQEs, the kernel may
  still be touching the memory.

- GPA's poison fill is essential for detecting these latent bugs. Under
  `c_allocator` (malloc), the memory is typically not immediately reused
  and the freed bytes retain their old values, masking the UAF.

- The `cleanupPeer` function used by `removePeer` during normal operation
  is safe because: (a) only one peer is removed at a time, (b) future
  ticks drain CQEs naturally via `submit_and_wait` + `copy_cqes`, and
  (c) stale-CQE guards handle completions for freed slots.

## Key file references

- `src/io/event_loop.zig:398` -- phased `deinit` implementation
- `src/io/event_loop.zig` (after deinit) -- `drainRemainingCqes` helper
