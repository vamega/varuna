# IO Directory Ops Contract Slice

## What changed and why

- Added IO-contract operation/result variants and method docs for `openat`, `mkdirat`, `renameat`, and `unlinkat` so future directory-walking state machines do not need raw `posix.*` calls.
- Implemented RealIO support with runtime-probed native io_uring SQEs when available, plus synchronous `posix.*` fallbacks for kernels that do not advertise the op.
- Implemented deterministic SimIO virtual namespace behavior for the four ops, including per-op fault knobs that surface `error.InputOutput` without mutating namespace state.
- Added synchronous POSIX implementations to epoll/kqueue dev backends so the contract remains compile-safe across alternate backends.
- Added a RealIO/SimIO parity test covering fd-relative mkdir, create-open, rename, open, unlink, and rmdir behavior.

## What was learned

- Zig 0.15.2 exposes `IoUring.openat`, `mkdirat`, `renameat`, and `unlinkat` helpers cleanly, so no custom SQE encoding was needed for this slice.
- Async RealIO paths need sentinel-terminated path slices because the kernel reads path pointers after submission; the contract now makes that lifetime rule explicit.
- `renameat` flags are only fully meaningful on the Linux `renameat2`/io_uring path. Sync POSIX fallback backends return `error.OperationNotSupported` for nonzero flags.

## Remaining issues or follow-up

- MoveJob is still thread-based. The v2 rewrite needs directory enumeration (`getdents` or equivalent), metadata/stat coverage (`statx`/`fstatat` shape), and `rmdir` coverage or a documented `unlinkat(..., AT.REMOVEDIR)` policy before it can avoid raw directory syscalls.
- The MoveJob scheduler policy is still open: global cap, per-device partitioning, FIFO, and size-aware ordering have different operator tradeoffs.
- SimIO's virtual namespace is intentionally minimal; it models path existence/type and fd-relative lookup, not full file content by path across close/reopen.

## Key code references

- `src/io/io_interface.zig:82` and `src/io/io_interface.zig:179`: directory op/result contract and method docs.
- `src/io/ring.zig:166`: runtime feature flags for the four directory SQEs.
- `src/io/real_io.zig:325`: RealIO feature-gated SQE submission and fallback implementations.
- `src/io/sim_io.zig:495` and `src/io/sim_io.zig:1378`: virtual namespace, fd path table, and fault knobs.
- `src/io/epoll_posix_io.zig:767`, `src/io/epoll_mmap_io.zig:638`, `src/io/kqueue_posix_io.zig:804`, `src/io/kqueue_mmap_io.zig:661`: alternate backend synchronous implementations.
- `tests/io_backend_parity_test.zig:288`: RealIO/SimIO parity coverage for the new directory ops.
- `src/storage/move_job.zig:11`: comment updated to mark this as groundwork, not the MoveJob v2 rewrite.
