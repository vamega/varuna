# Torrent Registry, Peer-Churn, And `/sync` Cache Pass

## What was done

I replaced the remaining cross-product torrent/peer scans with dense membership lists in the shared event loop, then added O(1) peer-list bookkeeping for idle and active peer queues. `TorrentContext` now owns `peer_slots`, the event loop tracks `torrents_with_peers`, and peers keep their own list indices so removal is a swap-remove instead of a linear search ([event_loop.zig](/home/vmadiath/projects/varuna-uringopt/src/io/event_loop.zig#L150), [event_loop.zig](/home/vmadiath/projects/varuna-uringopt/src/io/event_loop.zig#L231), [event_loop.zig](/home/vmadiath/projects/varuna-uringopt/src/io/event_loop.zig#L912), [event_loop.zig](/home/vmadiath/projects/varuna-uringopt/src/io/event_loop.zig#L1477)).

I also cached category and tag JSON in the daemon stores and switched `/api/v2/sync/maindata` to append those cached slices directly instead of rebuilding them every poll ([categories.zig](/home/vmadiath/projects/varuna-uringopt/src/daemon/categories.zig#L11), [sync.zig](/home/vmadiath/projects/varuna-uringopt/src/rpc/sync.zig#L139)).

The perf harness gained focused workloads for the affected paths: `tick_sparse_torrents`, `peer_churn`, and the existing `sync_delta` path now expose the relevant registry behavior under `src/perf/workloads.zig` ([workloads.zig](/home/vmadiath/projects/varuna-uringopt/src/perf/workloads.zig#L55), [workloads.zig](/home/vmadiath/projects/varuna-uringopt/src/perf/workloads.zig#L1240), [workloads.zig](/home/vmadiath/projects/varuna-uringopt/src/perf/workloads.zig#L1319)).

## What was learned

The biggest cost in the sparse torrent case was not allocator churn; it was repeated traversal over inactive torrents and unrelated peers. Once the benchmark exercised the real attach path, the registry change produced a very large win.

The peer-churn case confirmed that the list-membership scans were pure overhead. Keeping the peer's current index alongside the slot makes the queue maintenance cheap enough that the benchmark dropped from seconds to milliseconds.

During integration I fixed the swap-remove bookkeeping so moved entries get their new index rather than the removed entry's old value, and I added a regression test for torrent-peer, idle-peer, and active-peer index maintenance ([event_loop.zig](/home/vmadiath/projects/varuna-uringopt/src/io/event_loop.zig#L1865)).

The `/sync` category/tag cache was worthwhile, but it was not the main bottleneck. The benchmark moved only modestly because snapshot materialization and torrent stats still dominate the poll path.

## Remaining work

The follow-up worktree at `/home/vmadiath/projects/varuna-remaining` is initialized for the remaining items, especially seed plaintext scatter/gather and uTP outbound queueing. If those paths still show up hot under measurement, they should be benchmarked before any production change.

The `/sync` path still has room for a denser hot-summary registry if admin polling remains expensive at higher torrent counts.

## Measured deltas

- `tick_sparse_torrents --iterations=500 --torrents=10000 --peers=512 --scale=20`: `2.80e9 ns` -> `1.09e7 ns`, `0` allocs before and after.
- `peer_churn --iterations=5000 --peers=4096 --scale=128`: `1.13e9 ns` -> `3.81e6 ns`, `0` allocs before and after.
- `sync_delta --iterations=200 --torrents=10000`: `3.26e10 ns` -> `3.21e10 ns`, alloc calls `4,229,117` -> `4,228,317`.
