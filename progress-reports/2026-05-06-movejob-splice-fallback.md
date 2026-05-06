# MoveJob Copy Session Fallback

## What changed and why

- Replaced public syscall-shaped copy operations with a semantic IO contract: `open_copy_file_session`, `copy_file_chunk`, and `close_copy_file_session`.
- MoveJob now tries `renameat` per file first and only opens a lazy, per-job copy session after `EXDEV`. The fallback copies 4 MiB chunks, reports progress per completed chunk, treats `0` before the manifest length as EOF, and closes the copy session on success, failure, and cancellation.
- RealIO owns the private pipe/splice state behind `copy_file_chunk`: it prefers `IORING_OP_PIPE` when available, falls back to `pipe2(O_CLOEXEC|O_NONBLOCK)` for setup, uses `IORING_OP_SPLICE` internally for file-to-file chunks, and closes pipe fds with `IORING_OP_CLOSE`.
- POSIX and mmap readiness backends route `copy_file_chunk`, `fchown`, and `fchmod` through backend-owned file-op pools so callers do not block the event-loop thread.
- MoveJob preserves owner and permission/special-bit metadata for copied files and created directories. Metadata failures are fatal. Failed in-progress copy fallback files now close open fds and unlink the just-created destination while the source is still present.

## What was learned

- In this relocation flow, same-filesystem efficient copies are already handled by the preceding `renameat` fast path. The cross-filesystem fallback should prefer the operation RealIO can drive from io_uring.
- `copy_file_range` on a backend-owned threadpool may still be worth measuring later, but it should come back only with profiling evidence. The current design leaves that choice inside each backend instead of exposing `copy_file_range` in the public IO interface.
- `splice` is still useful as a RealIO implementation detail, but exposing it in the IO interface would push backend-specific pipe lifetime concerns into MoveJob and future callers.

## Remaining issues or follow-up

- Consider `copy_file_range` on a backend threadpool only if profiling finds a concrete reason.
- Investigate whether timestamp, xattr, and ACL preservation are needed for relocation fidelity.
- Migrate remaining older RealIO synchronous fallback paths onto the ready-completion queue so fallback callbacks do not fire inline.
- `remove_delete_files` still needs its own event-loop delete job.
- Peer `getpeername` and per-peer socket option setup remain separate IO-contract cleanup candidates.

## Key code references

- `src/io/io_interface.zig:626` - public copy-session IO contract surface.
- `src/io/real_io.zig:628` - RealIO copy-session open path with `IORING_OP_PIPE` / `pipe2` fallback.
- `src/io/real_io.zig:655` - RealIO `copy_file_chunk` entry point.
- `src/io/real_io.zig:716` - private splice state machine completion handling.
- `src/io/posix_file_pool.zig:477` - POSIX pool-backed `copy_file_chunk`, with internal `copy_file_range` and read/write fallback.
- `src/io/kqueue_mmap_io.zig:1169` - mmap dev backend uses the same pool-backed copy-session contract instead of returning unsupported.
- `src/storage/move_job.zig:807` - MoveJob chunk submission and future `copy_file_range` threadpool note.
- `src/storage/move_job.zig:1769` - cleanup regression for directory metadata fds.
- `src/storage/move_job.zig:1791` - cleanup regression for failed copy fallback destination files.
- `STATUS.md:306` - updated MoveJob status and future copy_file_range note

## Verification

- `nix run nixpkgs#zig_0_15 -- build test-move-job test-io-parity test-sim-io-durability --summary failures --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `nix run nixpkgs#zig_0_15 -- build test --summary failures --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `git diff --check`
