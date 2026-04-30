# 2026-04-30 — Close upward dependency: tracker executors moved from `src/daemon/` to `src/tracker/`

## What changed

External review C1 flagged a layer violation: `src/io/event_loop.zig`
imported `TrackerExecutor` and `UdpTrackerExecutor` directly from
`src/daemon/`, creating an upward dependency from io-uring infrastructure
to higher-layer session orchestration.

Fix: relocated both files into `src/tracker/` and pointed every importer
at the new paths.

- `src/daemon/tracker_executor.zig`     → `src/tracker/executor.zig`
- `src/daemon/udp_tracker_executor.zig` → `src/tracker/udp_executor.zig`

Updates:
- `src/daemon/root.zig` drops the executor re-exports.
- `src/tracker/root.zig` adds them.
- `src/io/event_loop.zig` imports from `../tracker/...` instead of
  `../daemon/...`, and the executor fields gained a layering comment
  noting the dependency direction.
- `src/daemon/session_manager.zig`, `src/daemon/torrent_session.zig`,
  and `src/perf/workloads.zig` updated to the new paths.
- `src/io/backend.zig` doc-comment list updated to reflect the new
  homes.
- The intra-file import inside `udp_executor.zig` switched from
  `../tracker/udp.zig` to `udp.zig` (sibling).

## Why Option A (move) over Option B (inject through an interface)

Coupling inventory measured against `src/io/event_loop.zig`:

| Site                   | Shape                                        |
|------------------------|----------------------------------------------|
| line 287, 290 (was)    | `?*TrackerExecutor` / `?*UdpTrackerExecutor` field |
| line 653-654           | `self.<field> = null;` on deinit             |
| line 1689              | `udp_tracker_executor.tick();` per tick      |

Both executor source files import only from `src/io/`, `src/tracker/`,
and `src/runtime/` — never from `src/daemon/`. Their placement under
`src/daemon/` was organizational, not a real dependency.

That's a 1-method, 2-pointer coupling shape with no `src/daemon/` →
executor data flow inside the executors themselves. An interface +
vtable in `src/io/` would have introduced ceremony (a vtable struct,
a wrapper, two implementations) for a single `tick()` call and a
nullable pointer field. Moving the files was the smallest change
that fixes the layering, and the destination module is the
already-existing `src/tracker/` (which holds `announce.zig`,
`scrape.zig`, `udp.zig`, `types.zig`).

Pattern #14 (count actual coupling points before deciding) and
Pattern #15 (use the existing module shape) both pointed Option A.

## Verification

```
$ grep -rn '@import.*../daemon/' src/io/
(empty)
```

```
$ nix develop --command zig build test
…
Build Summary: 122/124 steps succeeded; 1 failed; 1731/1747 tests passed; 15 skipped; 1 failed
```

The single failing test (`sim_smart_ban_phase12_eventloop_test.test.phase
2B: steady-state honest-co-located-peer (gated on Task #23)`) was
already failing on `6e5ef33` (parent commit) and is unrelated — it's
explicitly gated on Task #23.

`zig fmt .` reported no diff. The build is clean.

## What was learned

1. **Investigate the dependency direction inside the file before
   choosing a refactor approach.** The executors were *named* daemon
   things and *placed* under `src/daemon/` but their import graph
   only reached down into `src/io/` / `src/tracker/`. That's a
   strong signal the placement was wrong, not that the architecture
   needed an interface.

2. **A nullable pointer + one method call doesn't justify a vtable.**
   The natural Zig pattern for "I need to talk to a thing that lives
   in another subsystem" is an explicit field with the concrete type,
   as long as the dependency direction is downward. The architectural
   issue here was direction, not coupling shape.

3. **`git mv` plus `sed -i` for inline `@import("…")` strings was
   sufficient** — Zig's import machinery is purely path-based, no
   build-system glue needed beyond updating the two `root.zig`
   re-export files.

## Remaining issues / follow-up

None blocking. Two minor doc-comment references inside `src/io/dns.zig`
and `src/io/peer_policy.zig` still mention `TrackerExecutor` /
`UdpTrackerExecutor` in prose — that's expected and accurate (they
describe behavior, not imports), so no change needed.

## Key code references

- `src/tracker/executor.zig` (HTTP tracker executor — thin wrapper
  around `HttpExecutor`)
- `src/tracker/udp_executor.zig:32` `UdpTrackerExecutorOf(comptime IO)`
  generic; `:740` `UdpTrackerExecutor = UdpTrackerExecutorOf(RealIO)`
  alias
- `src/io/event_loop.zig:286-297` field declarations + new layering
  comment
- `src/io/event_loop.zig:660-661` deinit nulling
- `src/io/event_loop.zig:1696` `tick()` site
- `src/daemon/session_manager.zig:14-15` import
- `src/daemon/session_manager.zig:709-731` `ensureTrackerExecutor` /
  `ensureUdpTrackerExecutor` (construction + handoff to EventLoop)
- `src/daemon/torrent_session.zig:18-19, 1649, 1794` imports +
  inline-import call sites
- `src/perf/workloads.zig:23, 1241-1311` perf bench using the
  HTTP executor
- `src/tracker/root.zig`, `src/daemon/root.zig` re-export changes
