# Remove Obsolete Smart-Ban Swarm Scaffold

## What Changed

- Deleted `tests/sim_smart_ban_swarm_test.zig`, the hand-rolled downloader scaffold that predated `EventLoopOf(SimIO)`.
- Removed the `test-sim-smart-ban-swarm` build target from `build.zig`.
- Updated current status/setup docs to point at `tests/sim_smart_ban_eventloop_test.zig` as the smart-ban swarm integration reference.

## What Was Learned

- The old swarm test still passed, but its header and build comments described future work that has already landed.
- The EventLoop integration test now covers the meaningful production path: `EventLoopOf(SimIO)`, production piece assignment, `BanList`, `PieceTracker`, and disk-backed piece writes.

## Remaining Issues

- Historical progress reports still mention the deleted scaffold; those were left intact as dated records.

## Key Code References

- `build.zig:768` - smart-ban EventLoop target is now the only swarm-shaped smart-ban integration target.
- `tests/sim_smart_ban_eventloop_test.zig:402` - 8-seed clean EventLoop integration coverage.
- `tests/sim_smart_ban_eventloop_test.zig:427` - 32-seed BUGGIFY safety coverage.
- `docs/sim-test-setup.md:262` - current docs now name the EventLoop test as the reference.
