# Stage 2 Zero-Alloc Plan — Control-Plane Bump Arena

**Date:** 2026-04-26
**Track:** B (`runtime-engineer`)
**Scope:** RPC, tracker, (DHT deferred)
**Branch:** `worktree-runtime-engineer-stage2`

## What changed

### `src/rpc/scratch.zig` — new module

Two complementary bump arenas, both bounded:

* `RequestArena` — single fixed-size slab. `alloc` bumps within the slab;
  `error.OutOfMemory` past the cap. Used in places where the workload is
  bounded by protocol (tracker announce parse stack arena, DHT tick
  scratch when wired in).
* `TieredArena` — small fixed slab as the fast path, with automatic
  spill to the parent allocator for any allocation chain that overflows
  the slab. `reset()` returns the slab bump pointer to zero AND walks
  the spill chain to free spilled allocations in a single sweep. Hard
  cap enforced on the cumulative used bytes (slab + spill); past the
  cap, `error.OutOfMemory`.

The split exists because /sync/maindata for high torrent counts has a
much larger transient peak (~21 MB at 10K torrents) than its typical
response (a few KB). A single fixed-size slab forces a tradeoff between
"big enough for sync_delta" and "small enough to pre-allocate per slot."
The tiered design lets us pre-allocate a small slab (256 KiB × 64 =
16 MiB across all slots) and let exceptional requests transparently
spill to the parent allocator within a hard cap.

### `src/rpc/server.zig` — per-slot tiered arena wired into ApiServer

* `ApiClient` gains an optional `request_arena: ?TieredArena`.
* Pre-allocated at server init for all 64 slots.
* `processBufferedRequest` resets the arena before invoking the handler
  — guaranteed safe at this entry point because `handleSend` calls
  `releaseClientResponse` on send-complete *before* re-entering.
* `releaseOwnedResponseBody` skips the parent free when the response
  body lives in arena memory. Same for `owned_extra_headers`.
* `closeClient` retains the arena across slot reuse (mirrors the
  existing `recv_buf` retention pattern).
* `deinit` frees all per-slot arenas.

Bounds:

* `request_arena_slab` = 256 KiB (zero-alloc fast path)
* `request_arena_capacity` = 64 MiB (hard cap for the cumulative slab+spill)
* Active-slot worst-case = 64 × 64 MiB = 4 GiB at full saturation;
  in practice qBittorrent UIs hold 1–3 connections, so the typical
  working set is 64–192 MiB.

### `src/daemon/torrent_session.zig` — per-announce stack arena for tracker

`announceComplete` and `magnetHttpAnnounceComplete` now parse the
bencoded tracker response into a 64 KiB stack-allocated
`FixedBufferAllocator` instead of `self.allocator`. No heap churn during
announce parsing; oversized responses fail this announce attempt and
the tracker is retried later (safe and bounded).

### Bench harness

`src/perf/workloads.zig` `runSyncDelta` now wraps the per-iteration
allocator in a `RequestArena` mirroring production `/sync/maindata`
through `ApiServer`. This makes the bench representative of the
production allocation profile after Stage 2.

## What was learned

1. **Pre-allocate-at-init beats lazy-init** for `0 alloc` on benches.
   With lazy-init, the first request per slot triggers an arena alloc;
   for an 8-client static-handler bench that's an unavoidable 8 allocs.
   Pre-allocation moves those into server init (counted before bench
   reset). Cost: 16 MiB pinned per server even when idle. Tradeoff
   accepted: 16 MiB is small relative to typical varuna RAM footprint.

2. **A single-slab FBA is too rigid for `/sync/maindata`-class workloads.**
   Sync_delta for 10K torrents has a transient peak (HashMaps, stats
   array, JSON growth) of ~21 MB. Sizing the slab at 32 MB to fit that
   makes 64-slot×slab = 2 GiB upfront, which is unacceptable. A tiered
   design (small slab, transparent spill to parent) gives the fast-path
   zero-alloc behaviour for typical responses and a bounded spill for
   exceptional ones.

3. **Range-checking the response body to detect arena memory** is the
   minimal-friction way to keep the existing `Response.owned_body`
   semantics working. Handlers don't change; the server just learns to
   skip the parent free when the slice came from arena. This is what
   lets the migration touch only the server, not 25 handler call sites.

4. **The `freeSpill` walk uses LIFO ordering** because that's what
   `std.ArrayList` growth produces (alloc-new → copy → free-old). Free
   on the public `Allocator.free` path is a no-op in this arena (we
   keep the old slot allocated until reset); reset reclaims all spilled
   allocations together. Trade-off: peak transient memory is slightly
   higher than strictly necessary, but the cap bounds it and reset
   sweeps it cleanly.

5. **`std.heap.FixedBufferAllocator` for the slab fast path,
   `Allocator.rawAlloc/rawFree` for the spill chain** — composing them
   under a single `std.mem.Allocator` vtable avoided having to teach
   ArrayList about a custom allocator surface. The vtable reads
   slab-vs-spill via `slabContains` range check on each free/resize.

6. **Rebase verification surfaces real production gaps; budget for it
   as part of the work, not as overhead.** This session converged on
   that pattern across three independent findings:
   - The `api_get_burst` 8000-alloc regression (Task #4) read like a
     handler-side allocation problem at task creation. Only the
     post-rebase verification on actual `main` (HEAD `507c6bd`)
     surfaced the real source: the io_interface migration's
     `allocator.create(ClientOp)` per recv/send. The companion fix
     (embed `recv_op`/`send_op` in `ApiClient`, Pattern #1) was
     necessary; the arena work alone would not have closed Task #4.
   - The `tick_sparse_torrents` 1.4× regression (Task #5) was
     hypothesised at ticket time as `EventLoopOf(IO)` generic-dispatch
     overhead. Empirical profiling (`tick-iso` diagnostic harness)
     showed instead it was an O(piece_count) bitfield AND-loop in
     `wantedCompletedCountLocked` called per-tick-per-torrent — a
     pre-existing algorithmic cost that became visible only when the
     surrounding tick work shifted under it. The fix (an incrementally
     maintained `wanted_completed_count` cache on `PieceTracker`)
     made the bench 3× faster than the *original* 2026-04-16 baseline.
   - Storage-engineer's adjacent Track A surfaced two production bugs
     while re-enabling source-side test discovery (Task #9), and
     surfaced a Phase 1 × Phase 2 race during their own rebase.

   Pattern: **the rebase is the canary, not the fix.** Single-branch
   tests cannot see cross-branch interactions. Either the work
   premise was wrong (Task #5's hypothesis), or the work scope was
   incomplete (Task #4's arena-only would have shipped a still-leaky
   `api_get_burst`). Budget time for "rebase, re-measure, re-verify"
   as a *first-class step*, not as overhead — it's where the
   highest-value findings of the session emerged.

7. **Profile-driven diagnosis beats hypothesis-driven diagnosis when
   the hypothesis is plausible-but-untested.** Task #5's regression
   was hypothesised at ticket-creation time as `EventLoopOf(IO)`
   generic-dispatch overhead, with the suggested fix being either
   "inline-hint a specific dispatch site, or restructure to amortise
   the parameterisation cost." That hypothesis would have been wrong
   on both diagnosis and fix.

   Building a 95-line `tick-iso` diagnostic harness (one-shot, threw
   it away after the fix) broke the bench's wall time into per-
   function components: `checkPex` per-iter 5588 ns, `checkPartial`
   30372 ns, `isPartialSeed only` 35098 ns, `iter+getTC only` 853
   ns. The first three numbers said "isPartialSeed dominates"; the
   fourth confirmed the iteration shape itself is fine. That
   converted speculation ("dispatch overhead") into a definitive
   measurement ("the O(piece_count) AND-loop is the entire cost"),
   which then targeted the fix precisely.

   Generalised pattern: **perf regressions in big migrations may be
   coincident, not causal**. The migration changed the noise floor
   enough to make a pre-existing algorithmic cost visible. Build a
   per-function diagnostic before assuming the migration is the
   cause — the alternative is a fix in the wrong place that doesn't
   actually move the bench.

## Bench deltas

Baseline runs against `main` HEAD `507c6bd` (Phase 2 merge), which is
the post-IO-abstraction-migration baseline that introduced the
`api_get_burst` 8000-alloc regression noted in STATUS.md as Task #4.

| Bench | Baseline | After Stage 2 | Delta |
|---|---|---|---|
| **`api_get_burst --iterations=4000 --clients=8`** | **8000 allocs / 1.98 MB / 6.5e7–7.0e7 ns** | **0 allocs / 0 B / 6.12e7 ns** | **−8000 allocs (−100%)** |
| `api_upload_burst --iterations=1000 --clients=8 --body-bytes=65536` | 8 allocs / 525 KB live | 8 allocs / 525 KB live / 2.86e7 ns | unchanged |
| **`sync_delta --iterations=200 --torrents=10000`** | **4,229,925 allocs / 4.27 GB / 31.3s** | **222,970 allocs / 449 MB / 3.13s** | **−19× allocs, −9.5× bytes, −10× wall** |
| `sync_stats_live --iterations=1 --torrents=10000` | 8 allocs / 4.5 MB peak | 8 allocs / 4.5 MB peak / 3.67e6 ns | unchanged |

The two headlines:

1. **`api_get_burst` back to 0 allocs / 0 bytes.** Closes Task #4. The
   8000-alloc regression turned out to be 2 heap-allocated `ClientOp`
   trackers per request × 4000 iterations — *not* handler-side
   allocations. The arena work alone wouldn't have closed it; the
   companion fix is to embed the `recv_op` and `send_op` `ClientOp`
   structs directly in `ApiClient` (Pattern #1 in `STYLE.md`: Single
   Completion per long-lived slot for serial state machines). Each
   slot has at most one in-flight recv and one in-flight send at any
   time, so static storage suffices.

2. **`sync_delta` 19× alloc reduction, 10× wall reduction.** The
   `/sync/maindata` path now flows through the per-slot `TieredArena`.
   Remaining 222K allocs are `SyncState` snapshot HashMap creation
   (persistent state, not per-request transient).

## Test count delta

* Baseline: 223/223 (post-Phase-2 main, HEAD `507c6bd`)
* After: 230/230 (+7 — new `tests/rpc_arena_test.zig` integration tests)
* Direct `zig test src/rpc/scratch.zig`: 8/8 (unit tests for both arenas)
* No leaks under the GPA leak-detector across the suite.

## Remaining issues / follow-up

* **DHT tick-scoped arena deferred.** The DHT alloc churn is small
  in steady state (1–2 allocs per 5 sec tick). The wiring is non-
  trivial because `peers_copy` is allocated in `completeLookup`
  (called from `tick`) and freed in `dht_handler.zig` (called *after*
  tick). A correct change requires reset-at-start-of-next-tick which
  imposes cross-module lifetime reasoning. Filed as a follow-up if it
  becomes a hotspot.

* **PEX message build still uses parent allocator** for transient
  ArrayLists (added_v4, added_v6, dropped_v4, etc.). The team-lead's
  brief implied this was already pre-allocated, but it isn't. PEX
  fires every ~60s per peer; with 100 peers that's ~10K allocs/min —
  small but non-zero. Could plumb a per-peer scratch buffer.

* **Extension handshake encoding still allocates.** Per-handshake the
  cost is ~3 small slices (m-dict + entries + bencode output). Could
  be converted to a stack-buffer writer. Not on a hot path.

* **`SyncState` snapshot HashMap is the dominant remaining alloc
  source for sync_delta.** Each `storeSnapshot` allocates a fresh
  `AutoHashMap` with the parent allocator. Could be pooled across
  snapshots.

## Watch-items closed by this work

* **Task #4: api_get_burst alloc count regression (8000 allocs / 1.98 MB).**
  Resolved: 0 allocs / 0 bytes confirmed by `api_get_burst` after the
  ClientOp embed fix (commit `48752d5`). The pre-allocated per-slot
  arena handles handler-side allocations; the embedded
  `recv_op`/`send_op` close the per-op heap-create.

## File changes

```
src/rpc/scratch.zig         (new) — RequestArena + TieredArena
src/rpc/root.zig            +scratch export
src/rpc/server.zig          per-slot arena lifecycle + embedded ClientOps
src/daemon/torrent_session.zig — stack arena for tracker parse
src/perf/workloads.zig      — sync_delta uses arena (production-mirror)
tests/rpc_arena_test.zig    (new) — algorithm + integration + safety tests
build.zig                   +test-rpc-arena step
```

## Commit chain (rebased onto HEAD `507c6bd`)

* `aa909e0 rpc: per-slot bump arena for response building (Stage 2 zero-alloc)`
* `ff9cd0b tracker: per-announce stack arena for response parse (Stage 2 zero-alloc)`
* `c50fe45 docs: STATUS milestone + progress report for Stage 2 zero-alloc`
* `48752d5 rpc: embed per-slot recv/send ClientOp; closes Task #4 8000-alloc regression`
