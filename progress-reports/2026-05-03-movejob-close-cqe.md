# MoveJob Close CQE Follow-Up

## What Changed

- Replaced MoveJob event-loop file and directory fd cleanup with first-class `io.close` stages. Source, destination, and parent-directory fds now advance only after `.close` completions.
- Added failure cleanup stages so cancel/error paths submit close operations through the IO contract instead of calling the synchronous `closeSocket` helper.
- Added SimIO fault coverage for EXDEV copy fallback where a file close returns `InputOutput`; the job now fails before unlinking the source.

## What Was Learned

- The existing state machine already had the right one-completion/one-submission cadence; close just needed explicit stages between destination fsync and source unlink, and after directory fsync.
- Close failures are relocation decisions, not best-effort cleanup details: in the copy fallback they must stop before source unlink so the original bytes remain available.

## Remaining Issues

- SimIO's close fault knob reports a close error before removing the synthetic fd from its internal maps. MoveJob treats a delivered close CQE as the fd lifecycle boundary, which matches the daemon-facing ownership model, but SimIO close-error fd semantics may deserve a separate backend-contract cleanup.
- `copy_file_range` in RealIO remains synchronous-inline because Linux has no native io_uring opcode for it.

## Key Code References

- `src/storage/move_job.zig:118` - event-loop stages now include file, directory, and cleanup close states.
- `src/storage/move_job.zig:494` - destination fsync now transitions to source/destination close CQEs before source unlink.
- `src/storage/move_job.zig:537` - directory fsync now waits on a directory close CQE before advancing to the next parent sync.
- `src/storage/move_job.zig:752` - shared `io.close` submission helper used by normal and cleanup paths.
- `src/storage/move_job.zig:806` - failure/cancel cleanup starts asynchronous close-state cleanup instead of synchronous fd cleanup.
- `src/storage/move_job.zig:1880` - close-failure EXDEV fallback regression test keeps the source path intact.
