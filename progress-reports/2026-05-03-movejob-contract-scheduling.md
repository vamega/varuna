# MoveJob Contract Scheduling Follow-Up

## What Changed

- Added `close` to the IO contract and implemented it across RealIO, SimIO, epoll, kqueue, and the POSIX file pool so file/directory fd lifecycle has the same submission surface as other IO ops.
- Replaced MoveJob event-loop `posix.close` cleanup with backend-owned fd cleanup and documented the scheduling policy: one MoveJob tick per active job per daemon loop pass, with each job tick submitting at most one IO op.
- Extended SimIO's virtual namespace with path-backed file content so `openat` fds share durable/pending bytes, `copy_file_range` copies actual bytes across EXDEV fallback, `fsync` makes the destination survive `crash()`, and `unlinkat` removes source path content only after the safe point.
- Added focused MoveJob coverage for forced `renameat` EXDEV fallback, destination durability after copy, source preservation when destination fsync fails, and the multiple-job scheduling policy.

## What Was Learned

- SimIO's fd-only content map was enough for recheck tests but not for MoveJob: relocation opens fresh fds by path, so content must be keyed by virtual path and shared by every fd opened for that path.
- The simple round-robin policy is already present in the daemon shape: `SessionManager.tickMoveJobs` iterates active jobs once, and MoveJob's state machine naturally advances one completion/submission at a time.

## Remaining Issues

- MoveJob still uses a synchronous backend close helper for event-loop cleanup rather than waiting on close CQEs in the relocation state machine. The fd lifecycle is now routed through the IO abstraction, but a future cleanup can make close completions first-class if close failure reporting becomes important.
- `copy_file_range` in RealIO remains synchronous-inline because Linux has no native io_uring opcode for it; the existing MoveJob chunking limits the stall but does not eliminate it.

## Key Code References

- `src/io/io_interface.zig:80` - `close` operation/result contract.
- `src/io/real_io.zig:248` - RealIO `close` submission/fallback.
- `src/io/sim_io.zig:558` - path-backed SimIO file state for openat fds.
- `src/storage/move_job.zig:45` - documented MoveJob scheduling policy.
- `src/storage/move_job.zig:1691` - EXDEV copy fallback integration test.
- `src/daemon/session_manager.zig:1164` - one tick per active MoveJob per daemon loop pass.
