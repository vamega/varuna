# Manifest-Scoped Relocation

## What changed

- Added manifest-scoped `MoveJob` construction so relocation can operate on the torrent's file list instead of the whole save root.
- Updated `SessionManager.startMoveJob` to pass the loaded torrent manifest into `MoveJob` when available.
- Added a regression test proving a move leaves unrelated sibling files under the old save root untouched.

This closes the biggest safety gap in the existing relocation path: a torrent whose save path is shared with other data no longer moves the entire directory when the torrent manifest is loaded.

## What was learned

The current thread-backed `MoveJob` API had enough ownership boundaries to add manifest-scoped files without destabilizing callers. This is still a stepping stone: the move implementation remains blocking/thread-backed for this slice, but production moves for loaded sessions now have the right file scope before the event-loop rewrite lands.

## Remaining issues

- Convert `MoveJob` execution from worker-thread filesystem calls to the event-loop IO contract.
- Add directory durability coverage for destination parents and final metadata.
- Decide how to handle relocation requests for unloaded sessions; today those still fall back to the legacy whole-root job because no loaded manifest is available.

## Key references

- `src/storage/move_job.zig:103` - public manifest file descriptor and owned file storage.
- `src/storage/move_job.zig:167` - `MoveJob.createForFiles` validates and owns manifest-relative paths.
- `src/storage/move_job.zig:314` - manifest jobs bypass whole-root rename/copy and relocate only listed files.
- `src/storage/move_job.zig:914` - regression coverage for shared-save-root safety.
- `src/daemon/session_manager.zig:1029` - production move jobs are built from the loaded torrent manifest when available.
