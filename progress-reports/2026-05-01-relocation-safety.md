# Relocation Safety Fixes

## What changed and why

- `MoveJob.start` now restores `.created` and clears the completion callback fields if thread spawn fails, so callers can retry or destroy the job instead of leaving a permanently running job with no worker.
- Cross-filesystem file copies now propagate destination `fsync` errors. The source file is only unlinked after a successful copy and successful destination fsync, so delayed ENOSPC/EIO does not delete the only durable copy.
- `SessionManager.torrent_move_jobs` now uses `[40]u8` keys by value instead of borrowed `[]const u8` keys into `TorrentSession.info_hash_hex`, removing the dangling-key lifetime hazard after sessions are destroyed.

## What was learned

- `MoveJob` already owned its source and destination path strings, so the job-key lifetime issue was isolated to `SessionManager.torrent_move_jobs`.
- The current relocation worker still walks `session.save_path` as the source root. That is larger than the torrent manifest and can move unrelated files when multiple torrents share a save path.
- On this aarch64 host, the build-level suite is blocked by existing non-relocation compile issues before it can isolate this change: `src/io/tls.zig` imports OpenSSL headers even with `-Dtls=none`, and `src/storage/sqlite3.zig` rejects the current `SQLITE_TRANSIENT` pointer cast under Zig 0.15.2.

## Remaining issues or follow-up

- Drive relocation from the torrent manifest file list instead of moving the whole save root. Relevant starting points: `src/daemon/session_manager.zig:1009`, `src/storage/move_job.zig:246`, `src/storage/manifest.zig:54`.
- Add directory fsync coverage around created destination files/directories and source unlink/rmdir when the platform supports it.
- Add a build.zig focused target for `src/storage/move_job.zig` once relocation becomes a repeated hotspot; direct `zig test src/storage/move_job.zig` was used here only as supplemental verification because build-level tests are blocked by unrelated compile failures.

## Key code references

- `src/storage/move_job.zig:172`
- `src/storage/move_job.zig:396`
- `src/storage/move_job.zig:688`
- `src/storage/move_job.zig:716`
- `src/daemon/session_manager.zig:80`
- `src/daemon/session_manager.zig:1026`
- `src/daemon/session_manager.zig:1080`
- `src/daemon/session_manager.zig:2039`

## Verification

- `nix shell nixpkgs#zig_0_15 --command zig test src/storage/move_job.zig` - passed, 9/9 tests.
- `nix shell nixpkgs#zig_0_15 --command zig build test -Dtls=none -Dcrypto=stdlib --search-prefix /nix/store/hkapr9yav6nx45h1gizasd80gkqv3rqd-sqlite-3.50.2` - failed before full completion due existing compile blockers in `src/io/tls.zig` and `src/storage/sqlite3.zig`; partial result: 434/443 tests passed, 9 skipped, 18 failed compile steps.
