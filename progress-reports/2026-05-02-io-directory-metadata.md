# IO Directory Metadata Contract Slice

## What changed and why

- Extended the IO contract with `statx` and `getdents` operation/result variants so directory-walking state machines can ask for metadata and enumerate children through the shared backend interface.
- Added RealIO support for native `IORING_OP_STATX` when probed, with a synchronous Linux fallback. Added a Linux `getdents64`-shaped RealIO contract operation for directory enumeration.
- Added deterministic SimIO support for metadata lookup and directory enumeration over the virtual namespace, including fault knobs for future MoveJob and PieceStore.init BUGGIFY coverage.
- Added epoll/kqueue backend implementations so alternate runtime backends keep the same contract shape.
- Expanded backend parity coverage to stat a created file and enumerate its parent directory after rename.

## What was learned

- Zig 0.15.2 exposes `statx` through `std.os.linux.IoUring`, so metadata lookup can be submitted natively on supported kernels.
- Zig 0.15.2 does not expose a stable io_uring `getdents` helper/op. The shared contract therefore returns packed Linux `dirent64` records, with RealIO using `getdents64` directly and non-Linux/dev backends synthesizing the same layout.
- The Linux-shaped record format is enough for MoveJob/PieceStore callers to share one parser across RealIO, SimIO, epoll, and kqueue.

## Remaining issues or follow-up

- MoveJob is still the thread-based v1. The next step is an event-loop-owned state machine that uses these directory ops plus the existing copy/splice primitives.
- The MoveJob scheduler policy still needs a decision before that rewrite: global cap, per-device partitioning, FIFO, or size-aware scheduling.
- If Zig or the kernel exposes a stable io_uring directory enumeration op later, RealIO can swap the synchronous `getdents64` call for native SQE submission without changing caller code.

## Key code references

- `src/io/io_interface.zig:221`: `statx` / `getdents` contract docs and Linux-shaped helper utilities.
- `src/io/real_io.zig:452`: RealIO `statx` SQE submission and `getdents64` fallback operation.
- `src/io/sim_io.zig:1533`: SimIO virtual namespace metadata and directory enumeration.
- `src/io/ring.zig:170`: runtime probe flag for `IORING_OP_STATX`.
- `tests/io_backend_parity_test.zig:154`: parity coverage for statx and directory enumeration.
- `STATUS.md:306`: remaining MoveJob blockers after this contract slice.
