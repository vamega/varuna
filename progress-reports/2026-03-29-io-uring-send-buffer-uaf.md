# Fix use-after-free in io_uring send buffer lifecycle

## What was done

Fixed a use-after-free bug where `freePendingSend` freed ALL tracked send
buffers for a peer slot when any single send CQE completed.  When multiple
tracked sends were in flight for the same peer (e.g. extension handshake +
piece response), the first CQE completion freed every buffer, including those
still referenced by in-flight io_uring SQEs.  The kernel would then read from
freed (GPA-poisoned 0xAA) memory, causing data corruption visible under
`GeneralPurposeAllocator` but masked by `c_allocator`.

### Changes

1. **Split `freePendingSend` into two functions** (`src/io/event_loop.zig:2269-2298`):
   - `freeOnePendingSend(slot)` -- frees the first matching buffer (one per CQE)
   - `freeAllPendingSends(slot)` -- frees all buffers (used during peer removal)

2. **Updated `handleSend`** (`src/io/event_loop.zig:918`) to call
   `freeOnePendingSend` instead of the old `freePendingSend`, so only the
   buffer whose send just completed is freed.

3. **Updated `removePeer`** (`src/io/event_loop.zig:603`) to call
   `freeAllPendingSends(slot)` before closing the fd and resetting the peer.
   Previously, pending send buffers for a removed peer were leaked (never freed)
   unless a future CQE happened to trigger cleanup.

4. **Added stale-CQE guards** to `handleSend`, `handleRecv`, and
   `handleConnect`.  After `removePeer` closes the fd and resets the slot to
   `.free`, io_uring may still deliver CQEs for that (now-dead) socket.
   Without guards, these stale CQEs would call `removePeer` on an
   already-free slot (double close of fd=-1, double-free of null buffers).

5. **Fixed dangling-pointer on SQE submit failure** in `sendPieceBlock` and
   `flushQueuedResponses`.  Both appended a buffer to `pending_sends` and then,
   if `ring.send()` failed, freed the buffer directly -- leaving a dangling
   pointer in `pending_sends`.  Now they call `freeOnePendingSend` instead.

6. **Removed `c_allocator` workaround** in `src/tools/main.zig` -- restored
   `GeneralPurposeAllocator` now that the underlying UAF is fixed.

## What was learned

- io_uring CQEs are per-SQE: each completion corresponds to exactly one
  submitted operation and its buffer.  Freeing all buffers for a slot on a
  single CQE is wrong when multiple sends are queued.

- After `close(fd)`, the kernel still delivers CQEs for in-flight operations
  on that fd (with error results).  The event loop must handle these stale
  CQEs gracefully -- checking whether the slot is still active before acting
  on the completion.

- GPA's 0xAA poison fill is extremely valuable for detecting UAFs that
  `c_allocator` would silently mask.  The corruption was deterministic under
  GPA but invisible under malloc.

## Remaining issues

- The transfer test matrix (`scripts/test_transfer_matrix.sh`) fails with
  `NoReachablePeers` on both the fixed and original code.  This is a
  pre-existing issue unrelated to the UAF -- likely a peer-connect or
  handshake regression.

## Key file references

- `src/io/event_loop.zig:918` -- handleSend with stale-CQE guard
- `src/io/event_loop.zig:603` -- removePeer with freeAllPendingSends
- `src/io/event_loop.zig:2269` -- freeOnePendingSend
- `src/io/event_loop.zig:2284` -- freeAllPendingSends
- `src/tools/main.zig:4` -- GPA restored
