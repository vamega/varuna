# Demo Swarm Integration Testing & Bug Fixes

**Date:** 2026-04-10
**Build:** `zig build` passes, `zig build test` passes, `zig build test-torrent-session` passes.

## Bugs Found and Fixed

### 1. Deadlock in integrateIntoEventLoop (fixed in 3db9024)
`integrateIntoEventLoop` held `self.mutex` while calling `startRecheck`. When all pieces were known-complete (resume fast path), the recheck completed synchronously and `onRecheckComplete` tried to re-acquire `self.mutex` → deadlock.

**Fix:** Release mutex before starting async operations. Snapshot state under lock, then start recheck/metadata-fetch after unlock.

### 2. Memory leak in AsyncRecheck (fixed in 3db9024)
`handleHashResult` set `slot.buf = null` thinking the hasher took ownership, but the hasher returns the buffer pointer without freeing it. The buffer was leaked.

**Fix:** `defer self.allocator.free(piece_buf)` in `handleHashResult`.

### 3. Hasher submitVerify race condition (fixed in 3db9024)
After `submitVerify`, recheck.zig locked the hasher mutex and modified the last job's `is_recheck`/`hash_type` fields. But a hasher worker thread could dequeue the job between the submit and the lock, causing the wrong job to be modified.

**Fix:** New `submitVerifyEx` method sets all fields atomically within the same lock as the append.

### 4. background_init_done visibility (fixed in 3db9024)
`background_init_done` was a plain `bool` written by the background thread and read by the main thread. No memory ordering guarantee → main thread might never see the write.

**Fix:** Changed to `std.atomic.Value(bool)` with acquire/release ordering.

### 5. Event loop not ticking during recheck (fixed in 3db9024)
Main loop only called `tick()` when `peer_count > 0 or listen_fd >= 0 or udp_fd >= 0`. During recheck with no peers, the event loop slept instead of processing io_uring CQEs.

**Fix:** Also tick when `recheck != null or metadata_fetch != null or timer_pending`.

### 6. Shared resume DB cross-contamination (fixed in 3db9024)
Both seed and download daemons in demo_swarm.sh used the default resume DB at `~/.local/share/varuna/resume.db`. The seeder's completed pieces were loaded by the downloader, causing it to skip verification.

**Fix:** Per-daemon `resume_db` paths in demo_swarm.sh configs.

### 7. TrackerExecutor tryStartJob dangling pointer (fixed in 3db9024)
`parseUrl(job.urlSlice())` created slices into the by-value `job` parameter's stack memory. After `tryStartJob` returned, `slot.parsed.path` was a dangling pointer.

**Fix:** Copy job to slot first, then parse from `slot.job.urlSlice()`.

### 8. Announce scheduling before torrent registration (fixed in 3db9024)
`onRecheckComplete` called `scheduleReannounce` but the torrent wasn't registered in the event loop yet (`addTorrentWithKey` hadn't been called).

**Fix:** Moved announce scheduling to `addPeersToEventLoop`, which runs after torrent registration.

### 9. TrackerExecutor completeSlot use-after-free (fixed in f48dfd8)
`completeSlot` called `slot.reset()` (freeing `recv_buf`) before invoking the completion callback. The callback's `result.body` slice pointed into the freed buffer → garbled data → bencode parse failure.

**Fix:** Copy body to owned allocation before reset, pass copy to callback.

## Current State

The tracker announce path works end-to-end:
- Async recheck correctly identifies 0/1 pieces for downloader, 1/1 for seeder
- TrackerExecutor HTTP announce returns 200 OK with peers
- Both daemons discover each other via tracker
- MSE handshakes complete successfully on both sides
- Extension handshakes (BEP 10) complete

**Remaining issue:** SEGV occurs after both peers complete extension handshakes, during the subsequent peer wire exchange (BITFIELD/INTERESTED/REQUEST). The crash is a raw SIGSEGV with no Zig stack trace, suggesting a pointer dereference in non-safety-checked code (io_uring buffer handling or MSE decrypt path). A single plain-text handshake does not crash the seeder — the crash is specific to the two-peer simultaneous connection scenario.

## Key Code References
- Deadlock fix: `src/daemon/torrent_session.zig:445` (integrateIntoEventLoop)
- Hasher race fix: `src/io/hasher.zig:151` (submitVerifyEx)
- Recheck leak fix: `src/io/recheck.zig:196` (handleHashResult)
- Tick condition fix: `src/main.zig:460`
- Dangling pointer fix: `src/daemon/tracker_executor.zig:349` (tryStartJob)
- UAF fix: `src/daemon/tracker_executor.zig:816` (completeSlot)
