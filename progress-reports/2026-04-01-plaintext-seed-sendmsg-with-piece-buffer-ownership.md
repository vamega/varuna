## What was done and why

I productionized the plaintext seed upload win from the earlier syscall feasibility pass.

The key changes were:

- added refcounted seed `PieceBuffer` ownership in `src/io/event_loop.zig`
- changed `src/io/seed_handler.zig` so pending reads, the cached piece, deferred cache release, and queued responses all refer to `PieceBuffer` objects instead of raw borrowed slices
- extended tracked peer sends so a `PendingSend` can own either a contiguous buffer or a stable vectored-send state
- switched plaintext seed uploads to `io_uring` `sendmsg` with header iovecs plus direct references into the piece buffer
- kept the old contiguous copy path for encrypted peers, because MSE still needs one contiguous buffer to encrypt in place

Relevant code references:

- `src/io/event_loop.zig:260` — tracked send storage now supports owned and vectored sends
- `src/io/event_loop.zig:328` — queued seed responses now point at `PieceBuffer`
- `src/io/event_loop.zig:1536` — partial-send handling now resubmits vectored sends too
- `src/io/seed_handler.zig:64` — vectored plaintext batch state builder
- `src/io/seed_handler.zig:143` — plaintext `sendmsg` submit path
- `src/io/seed_handler.zig:191` — batched plaintext seed flush now prefers `sendmsg`
- `src/io/peer_handler.zig:206` — send completion now recomputes `send_pending` from tracked sends

## What was learned

- The ownership problem was real. A safe production `sendmsg` path needed the piece pages to outlive the socket CQE, not just the queueing tick.
- The production-path benchmark win is large enough to justify the complexity:
  - `seed_plaintext_burst --iterations=500 --scale=8`
  - before: `27.9 ms` to `30.4 ms`, `501` allocs, `65.6 MB` transient bytes
  - after: `12.5 ms` to `13.0 ms`, `1001` allocs, `276 KB` transient bytes
- The first version of the tracked vectored-send state used four allocations per batch. Packing the state into one backing allocation cut that prototype from `2001` alloc calls down to `1001`.
- This path is a bandwidth / copy reduction win, not yet a pure allocation-call-count win. The hot improvement is that payload bytes stop being recopied into fresh batch buffers.

## Remaining issues and follow-up work

- The remaining seed-path allocation target is the small tracked send state. Pooling or inline reuse would likely bring alloc-call count below the old copy path.
- `sendmsg_zc` is still optional future work. The new ownership model is a prerequisite, but zero-copy completion notifications would add CQE bookkeeping and should only be tried if real swarm profiles say plaintext seeding is still hot.
- `splice` / `sendfile` remain poor fits for the current peer upload path because framing still needs a separate header send and file-to-socket transfer still does not help encrypted peers.
