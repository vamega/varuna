# BlockingOpPool Syscall Fallbacks

## What Changed

- Generalized `src/io/posix_file_pool.zig` from a regular-file pool into a backend-owned `BlockingOpPool`. It now handles namespace, metadata, socket setup, detached fd teardown, mmap setup/flush/resize/close, and file-copy work while keeping historical `PosixFilePool` / `FileOp` aliases for compatibility.
- Moved EpollPosixIO, EpollMmapIO, KqueuePosixIO, and KqueueMmapIO `socket`, `bind`, `listen`, `setsockopt`, `openat`, `mkdirat`, `renameat`, `unlinkat`, `statx`, and `getdents` submissions onto the pool. Mmap backends also pool-route explicit `fsync`, `close`, `fallocate`, `truncate`, and lazy mapping setup work; read/write still use the mmap strategy after mappings exist.
- Added a RealIO fallback pool. RealIO still prefers native io_uring ops when `FeatureSupport` says they exist, but unsupported `socket`, `close`, `truncate`, namespace/metadata ops, ownership/permission ops, and socket setup fallbacks now run on the pool.
- Added a RealIO eventfd wake path polled by io_uring, so pool completions can wake `tick(1)` without relying on a userspace queue becoming visible after `io_uring_enter` goes to sleep.

## What Was Learned

- A ring-visible wakeup is required for RealIO's fallback pool. Otherwise `tick(1)` can sleep in `io_uring_enter` while the worker result is already sitting in the pool's completed queue.
- Internal wake CQEs must not count as user-visible progress. `RealIO.tick` now loops until it observes a user callback, which avoids returning from `tick(1)` on a stale eventfd poll CQE left by an earlier pool completion.
- The mmap backends still have page-fault risk by design, but lazy mapping syscalls and explicit IO-contract syscall operations no longer run inline on the event-loop thread.

## Remaining Issues

- Mmap backend read/write still copy on the event-loop thread; page faults remain the documented limitation to revisit only if the mmap strategy survives profiling.
- `remove_delete_files` still needs an event-loop delete job.
- Peer `getpeername` and per-peer socket option setup remain separate IO-contract cleanup candidates.
- `RealIO.close_copy_file_session` still assumes `IORING_OP_CLOSE` for pipe cleanup, matching the current kernel floor expectation.

## Key References

- `src/io/posix_file_pool.zig:107` - `BlockingOp` variants now include namespace, metadata, socket setup, detached close, mmap setup/flush/resize/close, and copy work.
- `src/io/posix_file_pool.zig:183` - `BlockingOpPool` primary worker-pool type.
- `src/io/real_io.zig:154` - RealIO creates the fallback eventfd and pool.
- `src/io/real_io.zig:204` - `tick` waits for user-visible completions, not internal wake CQEs.
- `src/io/real_io.zig:335` - eventfd poll rearm / drain path for pool completions.
- `src/io/real_io.zig:470` - `close` and adjacent unsupported ring fallbacks submit to the pool.
- `src/io/real_io.zig:814` - `socket` falls back to the pool when `IORING_OP_SOCKET` is unavailable.
- `src/io/epoll_posix_io.zig:756` - socket setup and fd-relative filesystem ops submit to the pool.
- `src/io/epoll_mmap_io.zig:873` - mmap read/write submit missing/stale mapping setup to the pool; `fsync`/`close`/`fallocate`/`truncate` submit explicit syscalls to the pool.
