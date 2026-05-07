# Close And Mmap Setup Offload

## What Changed

- Moved backend `closeSocket` steady-state teardown off the event-loop thread. RealIO submits detached `IORING_OP_CLOSE` when available and otherwise uses the backend `BlockingOpPool`; epoll/kqueue readiness backends submit detached pool close work after removing readiness bookkeeping.
- Added internal `mmap_setup` work to `BlockingOpPool` so mmap backends run lazy `fstat`/`mmap`/`madvise`, plus stale-mapping `munmap`, on worker threads. The public IO contract is unchanged: read/write still complete as read/write.
- Updated mmap backend docs and status notes so the remaining mmap limitation is page-faulting `memcpy`, not lazy mapping syscalls.

## What Was Learned

- Mmap setup can stay internal to the backend: the worker writes its result into completion backend state, and the backend converts that into the original read/write result when the pool completion is drained.
- `closeSocket` remains fire-and-forget by API shape, so detached close work has no public completion. The normal path is worker/ring-routed; overflow fallbacks still close the fd rather than leaking it.

## Remaining Issues

- Mmap read/write can still page fault on the event-loop thread.
- Backend deinit still performs control-fd cleanup synchronously.
- `remove_delete_files`, peer `getpeername`, and per-peer socket-option setup remain separate daemon cleanup candidates.

## Key References

- `src/io/posix_file_pool.zig:104` - internal mmap setup result/op plus detached pool submission.
- `src/io/real_io.zig:191` - RealIO detached close path.
- `src/io/epoll_mmap_io.zig:878` - read/write submit missing or stale mapping setup to the pool.
- `src/io/kqueue_mmap_io.zig:1021` - kqueue mmap read/write mapping setup path.
