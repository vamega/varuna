# Memory safety fixes

Date: 2026-05-05

## What changed and why

- Fixed the confirmed memory-safety audit findings in the validation worktree.
- Converted the repro suite into passing regression coverage, added focused
  `test-memory-*` targets, and made `test-memory-safety` part of the main
  `zig build test` target.
- Added teardown coverage for event-loop move jobs so pending completion
  userdata is drained before `MoveJob.destroy`.

## What was learned

The bugs were not isolated to one subsystem. The common failure mode was
returning from an error path while another owner still expected memory to stay
valid: parser errdefers freeing uninitialized values, async submitters dropping
stack completion arrays after partial submit, and seed/move-job paths releasing
buffers while CQEs were still outstanding.

## Remaining issues or follow-up

- No confirmed issue from this audit remains open on this branch.
- The move-job deinit fallback intentionally leaks a still-running event-loop
  job after a bounded drain instead of freeing pending-IO userdata. That should
  be revisited when relocation shutdown gets an explicit scheduler budget.

## Key code references

- `src/io/seed_handler.zig:320`
- `src/io/event_loop.zig:191`
- `src/daemon/session_manager.zig:180`
- `src/storage/move_job.zig:351`
- `src/storage/writer.zig:461`
- `src/torrent/bencode.zig:32`
- `src/torrent/metainfo.zig:211`
- `src/rpc/server.zig:424`
- `src/io/http_parse.zig:146`
- `src/io/http_executor.zig:1242`
- `src/tracker/udp_executor.zig:109`
- `tests/memory_safety_validation_test.zig:146`
