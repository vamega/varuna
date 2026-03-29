# 2026-03-29: Four Hardening Fixes

## What was done and why

Applied four hardening fixes identified during a corruption investigation. The
original fixes could not be cherry-picked due to merge conflicts, so they were
reimplemented fresh on the current codebase.

### Fix 1: timeout_pending tracking (src/io/event_loop.zig)

`submitTimeout()` could be called multiple times before the previous timeout CQE
completed, accumulating SQEs in the ring. Added a `timeout_pending: bool` field
that gates submission and is cleared when a timeout CQE arrives in `dispatch()`.

- Key changes: lines ~217 (field), ~660 (guard + set), ~795 (clear in dispatch)

### Fix 2: Write error checking in handleDiskWrite (src/io/event_loop.zig)

`handleDiskWrite()` did not check `cqe.res` for errors. A failed disk write
(disk full, I/O error) would still mark the piece complete. Now checks for
`cqe.res < 0`, logs the error, releases the piece back to the piece tracker
for re-download, and frees the buffer.

- Key changes: lines ~1117-1131

### Fix 3: Endgame duplicate write skip (src/io/event_loop.zig)

In endgame mode, two peers can complete the same piece. Both pass hash
verification and both create PendingWrite entries in `processHashResults()`.
The second write collides on the HashMap key, causing buffer tracking issues.
Now checks `pending_writes.contains(key)` before creating a new entry; if the
piece is already being written, the duplicate buffer is freed and skipped.

- Key changes: lines ~1903-1916

### Fix 4: Tools binary allocator swap (src/tools/main.zig)

Zig's GPA debug allocator fills freed memory with 0xAA. A latent use-after-free
in the io_uring buffer lifecycle means the kernel sometimes reads 0xAA from a
freed buffer. Switched `src/tools/main.zig` from `GeneralPurposeAllocator` to
`std.heap.c_allocator` with a detailed TODO comment documenting the suspected
UAF locations (freePendingSend, removePeer, processHashResults duplicate
handling) for future investigation.

## What was learned

- io_uring timeout SQEs persist in the ring until they complete or are cancelled.
  Submitting multiple timeouts without tracking wastes ring slots and can cause
  unexpected wakeups.
- HashMap `put` silently overwrites existing entries. In the endgame duplicate
  case this means the first PendingWrite's buffer pointer is lost, causing a
  memory leak and incorrect spans_remaining tracking.
- GPA's 0xAA poison is actually useful for surfacing UAF bugs that would
  otherwise be silent in production (c_allocator/release builds).

## Remaining issues

- The underlying use-after-free in io_uring buffer lifecycle is NOT fixed, only
  masked by switching to c_allocator. The three suspected locations need
  investigation with careful lifetime analysis of buffers vs. in-flight SQEs.
- The daemon binary (src/main.zig) still uses its own allocator and may exhibit
  the same UAF under GPA. Consider a similar investigation there.
