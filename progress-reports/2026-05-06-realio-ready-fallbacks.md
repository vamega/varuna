# RealIO Fallback Callback Timing

## What Changed

- Moved the remaining RealIO fallback callback paths out of submit-time delivery. This intermediate step made `close`, `truncate`, `openat`, `mkdirat`, `renameat`, `unlinkat`, `statx`, `getdents`, `bind`, `listen`, and `setsockopt` obey the same "callback from `tick`" rule as ring CQEs.
- Added a RealIO regression that forces all feature flags off and asserts each fallback does not fire inline before the next `tick`.
- Updated `STATUS.md` so the MoveJob follow-up no longer points at stale inline fallback callbacks.
- Follow-up landed the same day in `progress-reports/2026-05-06-blocking-op-pool-syscalls.md`: the fallback syscalls themselves now run on the backend-owned blocking-op pool instead of on the submission thread.

## What Was Learned

- The existing completion dispatch path was the right shared shape for immediate-but-not-inline results. Keeping `.rearm` behavior centralized avoids operation-local callback loops.
- This first step fixed callback timing, not syscall placement. The same-day follow-up moved the syscall placement too: unsupported RealIO ring fallbacks now run on the backend-owned blocking-op pool and wake the ring through eventfd.

## Remaining Issues

- Mmap backend page faults can still block the event-loop thread. This is
  documented as an mmap-backend limitation for now; the first cleanup target
  is syscall blocking, not page-faulting `memcpy`.
- Readiness backend namespace/metadata/socket setup syscalls were moved to the
  backend-owned blocking-op pool in
  `progress-reports/2026-05-06-blocking-op-pool-syscalls.md`.
- `remove_delete_files` still needs an event-loop delete job.
- Peer `getpeername` and per-peer socket option setup remain separate IO-contract cleanup candidates.

## Key References

- `src/io/real_io.zig:161` - RealIO now owns the fallback blocking-op pool and wake eventfd.
- `src/io/real_io.zig:335` - pool wake eventfd rearm / drain path.
- `src/io/real_io.zig:470` - unsupported close/truncate and directory fallbacks submit to the pool.
- `src/io/real_io.zig:814` - socket fallback submits to the pool when the ring op is unavailable.
- `src/io/real_io.zig:1150` - fallback callback timing regression.
- `STATUS.md:306` - MoveJob status updated with the ready-fallback cleanup.
