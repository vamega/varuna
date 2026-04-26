# build.zig Test-Step Audit (Task #6) — 2026-04-26

Originally scoped (per migration-engineer's earlier finding): "sweep build.zig
for `addTest` calls that follow the pattern of attaching only to a focused
step but not to main `test`." This report has the audit results plus a deeper
finding on source-side test discoverability that was surfaced during Track A.

## Audit results — `addTest` calls

Six `addTest` artifacts were attached only to focused per-step targets, never
to the main `test` step. Five wired in cleanly; one stays gated.

| addTest binding | Status before | Status after |
|---|---|---|
| `torrent_session_tests` (`tests/torrent_session_test.zig`) | only `test-torrent-session` | **Stays gated** — known intermittent Zig cache failure (`manifest_create Unexpected`); see STATUS.md "Known Issues". Comment in build.zig flags it explicitly. |
| `bind_device_tests` (`tests/bind_device_test.zig`) | only `test-bind-device` | wired into `test_step` (+6 tests) |
| `safety_tests` (`tests/safety_test.zig`) | only `test-safety` | wired into `test_step` (+10 tests) |
| `transfer_tests` (`tests/transfer_integration_test.zig`) | only `test-transfer` | wired into `test_step` (+1 test) |
| `utp_bs_tests` (`tests/utp_bytestream_test.zig`) | only `test-utp` | wired into `test_step` (+3 tests) |
| `recheck_tests` (`tests/recheck_test.zig`) | only `test-recheck` | wired into `test_step` (+4 tests) |

All other `addTest` calls (sim_*, smart_ban, multi_source, api, transport,
adversarial, private_tracker, udp_tracker, io_parity, el_health, sim_swarm,
piece_hash_lifecycle, mod_tests, daemon_tests) were already attached to
`test_step`.

**Net: +24 tests under `zig build test`.** Stable 262/262 across 5 back-to-back
runs.

## Discoverability of source-side `test "..."` blocks (deeper finding)

This was surfaced during Track A when source-level tests in `src/torrent/session.zig`
weren't being executed despite the file being reachable via `pub const session
= @import("session.zig");` from `src/torrent/root.zig` (which is reachable
from `src/root.zig`, which is `varuna_mod`'s `root_source_file`).

**Empirically verified**: an intentionally-failing
`try std.testing.expect(false)` test added to `src/torrent/session.zig` does
NOT cause `zig build test` to fail. The same is true for `src/crypto/rc4.zig`
(despite `src/crypto/root.zig` having a `test { _ = ... }` block).

**Root cause**: in Zig 0.15.2, `addTest(.{ .root_module = m })` discovers test
blocks via the root_source_file's reachability — but `pub const x = @import(...)`
does NOT pull a file's test blocks into the test runner. Only files reached
from a test-context import (typically `test { _ = @import("foo.zig"); }`)
participate. The `test { _ = ... }` block in `src/crypto/root.zig` looked
correct but turned out to be decorative — confirmed empirically via failing
test injection.

**Why this hasn't caused observable failures**: most subsystem-level test
blocks in `src/` have bit-rotted because they haven't been run since they
were originally written. Adding a top-level `test { _ = app; _ = config;
_ = crypto; _ = torrent; ... }` to `src/root.zig` to force discovery exposes
**32+ compile errors** across:

- `src/app.zig` — `Io.GenericWriter.interface` API drift (Zig std 0.15)
- `src/config.zig` — `fs.Dir.close` signature change
- `src/crypto/mse.zig` — `posix.socketpair` removed
- `src/crypto/sha1.zig` — switch exhaustiveness
- `src/torrent/bencode.zig` — discarded error set
- `src/torrent/blocks.zig`, `src/torrent/file_priority.zig`,
  `src/torrent/layout.zig` — `[]File` vs `*const [N]File` slice coercion
  (Zig 0.15 tightened); also `Metainfo.comment` field added but old test
  literals don't include it
- `src/torrent/piece_tracker.zig` — discarded `bool` return value

The bit-rot scope (~9 files × 32+ errors) is far beyond the "~30 min quick
scoped pass" the task envisioned. Each file would need a small fix (struct
literal additions, slice syntax updates, switch cases) which is mechanical
but requires running each test and verifying expected behavior post-fix.

**Recommendation**: file as a follow-up "src-tests bit-rot cleanup" task,
not folded into Task #6's housekeeping scope. The wins:
1. Subsystem-level invariants get test coverage close to the code they
   pin (the canonical "tests live next to the code" shape).
2. Future similar drift will be caught when tests don't compile, not
   silently when they stop running.

## Test count progression

| Milestone | Test count |
|---|---|
| Pre-Track-A (current main, `507c6bd`) | 223/223 |
| After Track A (piece hash lifecycle + 15 dedicated tests) | 238/238 |
| After Task #6 (5 unwired test files brought into `test_step`) | 262/262 |

## Files touched

- `build.zig` — five `test_step.dependOn(...)` additions for
  `bind_device_tests`, `safety_tests`, `transfer_tests`, `utp_bs_tests`,
  `recheck_tests`. Comment on `torrent_session_tests` documenting why it
  stays gated.

## Out of scope (filed mentally as follow-ups)

- src-tests bit-rot cleanup (described above; ~9 files, maybe 1-2 hours
  of mechanical fixes once one sample file is done).
- A `comptime { _ = @import("foo.zig"); }` sweep in subsystem `root.zig`
  files once the bit-rot is addressed.
- Re-evaluate `torrent_session_tests` wiring once the upstream Zig
  cache-toolchain issue resolves.
