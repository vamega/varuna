# MoveJob Event-Loop Relocation

## What changed

- Added a manifest-scoped event-loop `MoveJob` runner that submits relocation work through the IO contract.
- Wired production move requests to `MoveJob.startOnEventLoop`; loaded sessions use their manifest and unloaded sessions parse a temporary seeding-only manifest instead of falling back to whole-root moves.
- Added `SessionManager.tickMoveJobs` / `hasActiveMoveJobs` and ticked active move jobs from the daemon main loop.
- Added focused build coverage with `zig build test-move-job`.

## What was learned

The IO contract was sufficient for a safe first MoveJob v2: `mkdirat`, `renameat`, `openat`, `copy_file_range`, `fsync`, and `unlinkat` cover the manifest-file state machine. The remaining awkward part is fd lifecycle: the contract still lacks a regular-file close operation, so the runner closes file and directory fds with `posix.close` after IO completions.

## Remaining issues

- Add an IO contract `close`/`closeat` primitive if the project wants fd lifecycle to be modeled and injectable alongside the rest of file I/O.
- Add explicit cross-filesystem integration coverage; the current focused event-loop test covers the same-filesystem `renameat` path.
- Consider bounded scheduling across multiple simultaneous move jobs. The current policy advances each active job at most one submitted operation per daemon loop pass.

## Key references

- `src/storage/move_job.zig:104` - event-loop runner and relocation stages.
- `src/storage/move_job.zig:315` - `startOnEventLoop` entry point.
- `src/storage/move_job.zig:343` - event-loop tick/dispatch path.
- `src/storage/move_job.zig:423` - completion handling, including `EXDEV` copy fallback and parent-directory fsync.
- `src/daemon/session_manager.zig:1030` - production move jobs require the shared event loop and build manifest-scoped inputs.
- `src/daemon/session_manager.zig:1149` - active move-job polling and event-loop tick integration.
- `src/main.zig:427` - daemon main loop keeps ticking while move jobs are active.
- `build.zig:242` - focused `test-move-job` build target.
