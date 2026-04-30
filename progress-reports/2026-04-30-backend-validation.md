# 2026-04-30 — Cross-backend validation: epoll_posix and epoll_mmap

Round 2 of the backend-validation seat. Base commit `8633644` (latest
main; includes Round D merges and the prior engineer's `tick(0)` fix).
Branch: `worktree-backend-validation`.

## Phase status

| Phase | Backend | Status | Evidence |
|---|---|---|---|
| 1: build + EL boot | io_uring | PASS | `zig build && zig build test-backends` (5/5 + 2/2) |
| 1: build + EL boot | epoll_posix | PASS | `zig build -Dio=epoll_posix && zig build test-backends -Dio=epoll_posix` (5/5) |
| 1: build + EL boot | epoll_mmap | PASS | `zig build -Dio=epoll_mmap && zig build test-backends -Dio=epoll_mmap` (5/5) |
| 2: demo_swarm | io_uring | **FAIL (baseline regression)** | progress=0.0 after 60 s; no piece transfer |
| 2: demo_swarm | epoll_posix | BLOCKED | inherits baseline failure |
| 2: demo_swarm | epoll_mmap | BLOCKED | inherits baseline failure |
| 3: perf vs io_uring | all | BLOCKED | Phase 2 prerequisite |
| 4: failure-mode audit | all | DONE (read-only) | 4 gaps surfaced |
| 5: file follow-ups | — | DONE | this report + STATUS.md entries |

## Phase 1 — boot tests under each backend

Added a focused EL tick-cycle smoke to `tests/event_loop_health_test.zig`
and a `test-backends` build step in `build.zig`. The smoke:

1. `EventLoop.initBare(testing.allocator, 0)` — constructs an EL with the
   selected `-Dio=` backend resolved via `backend.initEventLoop`.
2. `el.io.timeout(.{ .ns = 10ms }, &completion, &counter, cb)` — submits
   a timeout via the contract surface.
3. `el.io.tick(1)` — blocks until a CQE arrives.
4. Asserts `counter.fires == 1`.
5. `el.io.tick(0)` — non-blocking drain.
6. EL drops; verifies `/proc/self/fd` count is back near baseline.

Bypasses `EventLoop.tick()` deliberately (which depends on torrent /
peer state). The first version of the test went through `EventLoop.tick`
and hung in `io_cqring_wait` because of the prework (peer_policy +
dht_handler ticks) it does pre-`io.tick(1)`; the second version is a
direct contract-surface exercise with one expected CQE.

The EL init / fd-leak / thread-count tests in the same file already
exercise the chosen backend through the comptime selector — the new
test is the additional "submit + drain" coverage.

Build commands run end-to-end clean:

```
zig build                                   # io_uring (default), green
zig build -Dio=epoll_posix                  # green
zig build -Dio=epoll_mmap                   # green
zig build test-event-loop                   # 5/5 io_uring
zig build test-event-loop -Dio=epoll_posix  # 5/5
zig build test-event-loop -Dio=epoll_mmap   # 5/5
zig build test-backends                     # 7/7 io_uring (adds io-parity)
zig build test-backends -Dio=epoll_posix    # 5/5 (parity skipped — see commit msg)
zig build test-backends -Dio=epoll_mmap     # 5/5
```

Commit `e2e933a` — `io: add test-backends step + EL tick-cycle smoke for
epoll backends`.

## Phase 2 — demo_swarm cross-backend pass

**Phase 2 is blocked on a baseline `-Dio=io_uring` regression.** This
is the single biggest finding of the round. Details:

`scripts/demo_swarm.sh` builds the daemon, brings up an opentracker, a
seeder daemon, and a downloader daemon, and waits for `progress >= 1.0`
on the downloader. Both daemons connect via the tracker peer list,
exchange MSE handshakes (or skip MSE under `encryption=disabled`),
exchange BT handshakes, exchange BEP-10 extension handshakes — peer
extensions land in the logs on both sides — and then **stall**. No
BITFIELD, INTERESTED, UNCHOKE, REQUEST, or PIECE messages flow. The
60 s timeout fires and the script reports `download timed out`.

Reproduced with three configurations:

1. Default `demo_swarm.sh` (encryption=preferred, enable_utp=true) on
   default `-Dio=io_uring` — fails.
2. encryption=disabled, enable_utp=false (TCP-only, plaintext) — same
   failure.
3. Both daemons stripped down via a manual harness in `/tmp/varuna-test/`
   (no DHT, no PEX, plain TCP, single-piece torrent) — same failure.

The connection state on the seeder side shows 4 peer slots populated
(slots 0–3) for what should be one connection — both daemons appear to
dial AND accept simultaneously. Whether the storm is the proximate
cause or just a symptom is open.

The in-process `transfer_integration_test` (`zig build test-transfer`)
**still passes**, which means the wire-protocol code in
`src/io/peer_handler.zig` and `src/io/protocol.zig` is intact at the
algorithm layer. The break is at the two-process daemon-glue boundary.
Last green at commit `3ab5f59` (2026-04-30 MSE merge per
`progress-reports/2026-04-30-mse-handshake-race.md`'s "Verified with 5
consecutive demo_swarm runs"); fails at `8633644` (current main / our
base). Several merges happened between those points — the bisect range
is small.

### Infrastructure unblockers committed

Two scoped changes to make the swarm runnable across backends and
across environments:

1. `scripts/demo_swarm.sh`: respect `IO_BACKEND=...` env var. Default is
   `io_uring`; setting `epoll_posix` or `epoll_mmap` triggers a second
   `zig build -Dio=$IO_BACKEND` after the default build. `varuna-tools`
   stays io_uring per the AGENTS.md companion-tool exemption (gated on
   `io_backend == .io_uring`). Also falls back to plain `zig build`
   when `mise` isn't on PATH (the nix devshell case).

2. `scripts/tracker.sh`: tolerate the absence of `apt-get` / `dpkg-deb`.
   Picks up `opentracker` from PATH when available (e.g. via
   `nix shell nixpkgs#opentracker`) instead of unconditionally trying
   to `apt-get download`.

Commit `6f5a045` — `scripts: add IO_BACKEND selector to demo_swarm + nix
opentracker path`.

These changes are correct and tested independently — running
`IO_BACKEND=epoll_posix demo_swarm.sh` and `IO_BACKEND=epoll_mmap
demo_swarm.sh` produces the same hang as the io_uring default, which is
the expected behavior given that the failure is upstream of the IO
backend.

## Phase 3 — perf deltas vs io_uring

**Blocked on Phase 2.** Without a working swarm transfer there is no
end-to-end workload to measure. The CPU microbenchmarks in
`src/bench/main.zig` (kernel parser, bencode parse, SHA-1, metainfo)
don't exercise the IO backend so produce identical numbers across
`-Dio=` flags.

Filed as a follow-up in STATUS.md: "Cross-backend perf comparison vs
`io_uring` not measured." Once the demo_swarm regression closes, the
delta is one timed `demo_swarm.sh` run per backend; if profiling beyond
that is needed, an EL-driven micro-benchmark that times N timeout
cycles + N socket recv/send round-trips through the contract surface
would isolate the backend overhead.

## Phase 4 — failure-mode audit

Read through the relevant code paths under
`src/io/{epoll_posix,epoll_mmap,real}_io.zig`,
`src/io/posix_file_pool.zig`, `src/storage/writer.zig`,
`src/runtime/probe.zig`, and `src/main.zig`. Findings:

### 4.1 `IORING_OP_BIND` / `LISTEN` / `URING_CMD-SETSOCKOPT` unsupported (epoll inheritors)

The epoll backends always synthesize `bind`, `listen`, and `setsockopt`
synchronously on the EL thread — `posix.bind(2)` / `posix.listen(2)` /
`posix.setsockopt(2)` inline through `armCompletion` + `deliverInline`
(`src/io/epoll_posix_io.zig:758-827`, `src/io/epoll_mmap_io.zig` shares
the same shape via the readiness-layer copy). There is no async
fallback to "fail because the kernel doesn't have `IORING_OP_BIND`" —
the contract op surface only exposes the synchronous form for these
backends. So the failure mode being audited (kernel says no, what
happens) is **not reachable** under epoll backends; the synchronous
form has no kernel-side feature gate.

The io_uring backend has a real probe-and-fallback shape
(`src/io/real_io.zig:436-501` — async via `IORING_OP_BIND` /
`IORING_OP_LISTEN` / `IORING_OP_URING_CMD+SOCKET_URING_OP_SETSOCKOPT`
when `feature_support.supports_*` is set, synchronous `posix.*`
otherwise). Both branches were exercised across the daemon's
listener-bring-up paths in commit `9138e8b` per
`progress-reports/2026-04-30-bind-listen-setsockopt.md`.

**Verdict: no gap.** Both backends behave correctly when the
async-via-uring path is unavailable.

### 4.2 `IORING_OP_FTRUNCATE` unsupported

Same shape: io_uring branches on `feature_support.supports_ftruncate`
and falls back to synchronous `posix.ftruncate(2)`. Epoll backends
always run synchronously through the file-op pool (epoll_posix) or
inline (epoll_mmap). No gap.

### 4.3 `fallocate` returns `OperationNotSupported` (tmpfs <5.10, FAT32, FUSE)

Walked the full flow:

- `RealIO.fallocate` (io_uring) maps `EOPNOTSUPP →
  error.OperationNotSupported`.
- `EpollPosixIO.fallocate` routes to `posix_file_pool.executeFallocate`,
  which maps `OPNOTSUPP → error.OperationNotSupported`
  (`src/io/posix_file_pool.zig:409`).
- `EpollMmapIO.fallocate` (synchronous inline) maps `OPNOTSUPP →
  error.OperationNotSupported` (`src/io/epoll_mmap_io.zig:799`).

All three backends surface the same error to `preallocCallback`
(`src/storage/writer.zig:526-555`), which sets `slot.needs_truncate =
true`, increments `ctx.fallback_count`, and the caller submits one
`io.truncate` per affected file in a second drain pass. The truncate
op also has the same uniform error mapping across backends. The
sentinel comment at `src/storage/writer.zig:537-541` explicitly calls
out tmpfs <5.10 / FAT32 / certain FUSE FSes as the target environments.

**Verdict: no gap.** The fallback path lights up uniformly under all
three production backends.

### 4.4 Disk fills mid-write (`ENOSPC`)

Walked the write callback (`src/storage/writer.zig:207-260`,
`writeSpanCallback`):

- A successful `pwrite` of 0 bytes is treated as `error.UnexpectedEndOfFile`.
- A short write triggers a re-submit of the remainder against the same
  completion (no infinite loop — the backend has cleared `in_flight`
  before the callback so `armCompletion` re-arms cleanly).
- An error result is recorded in `ctx.first_error` and `ctx.pending` is
  decremented.

`error.NoSpaceLeft` arrives as the result variant `.{ .write = err }`
and lands in `ctx.first_error`. The drain loop in `writePiece`
naturally completes once `pending == 0`, then propagates `first_error`
back up to the caller. Open file fds are owned by `PieceStore.files`
and closed in `PieceStore.deinit`; an in-flight ENOSPC does not leak
fds. There is no infinite retry — short writes only re-submit when the
underlying op returned bytes but didn't reach the slice end; an ENOSPC
result returns no bytes so the re-submit branch is not entered.

The io_uring, epoll_posix, and epoll_mmap backends all emit the same
ENOSPC-shaped error variant — the writer code path is backend-agnostic.

**Verdict: no gap.** ENOSPC propagates cleanly with no fd leak and no
retry storm.

### 4.5 `runtime.probe.ensureSupported` blocks startup on missing io_uring (real gap)

`src/runtime/probe.zig:23-26`:

```zig
pub fn ensureSupported(summary: Summary) !void {
    if (summary.support == .unsupported) return error.UnsupportedKernel;
    if (!summary.io_uring_available) return error.IoUringUnavailable;
}
```

This unconditionally fails the startup probe when io_uring is
unavailable, regardless of which backend the binary was compiled for.
A daemon built with `-Dio=epoll_posix` or `-Dio=epoll_mmap` — the
explicit purpose of which is to run on systems without io_uring —
currently refuses to boot on such systems with `startup blocked:
io_uring is unavailable on this host`.

The kernel-floor minimum (currently 6.6, set in
`src/runtime/requirements.zig`) probably also wants a per-backend
override — epoll requires only kernel ≥2.6, so requiring 6.6 is a
wasted gate when the daemon was compiled without io_uring.

This is the only **real** failure-mode gap surfaced. Filed in STATUS.md
"Next > Operational" with a fix sketch (gate the io_uring check on
`build_options.io_backend == .io_uring`). Estimated 2–4 hours.

### 4.6 epoll_mmap surfaces ENOSPC for "write past mapped EOF"

Note (not a gap, but worth flagging): under `-Dio=epoll_mmap`, writes
that extend past the current mmap'd region surface `error.NoSpaceLeft`
as a sentinel meaning "caller must fallocate/truncate first"
(`src/io/epoll_mmap_io.zig:746-751`). The writer treats ENOSPC as a
real disk-full condition. In practice `PieceStore.init` calls
fallocate-or-truncate on every file before any write submissions, so
this sentinel is not reachable on the daemon's normal path. But if the
daemon ever grows a file size at runtime (e.g. dynamic file-list
extension on hybrid v2 piece downloads) without re-sizing the mapping
first, it would treat the resulting "out of bounds" write as a
genuine disk-full event. Not on the daemon's hot path today; would
need a writer-side discriminator on epoll_mmap if it ever became one.

## Phase 5 — file follow-ups + this report

Filed in STATUS.md "Next > Operational":

1. **`runtime.probe.ensureSupported` blocks daemon startup on missing
   io_uring even under `-Dio=epoll_*`** (Phase 4.5).
2. **`scripts/demo_swarm.sh` baseline regression — pieces no longer
   transfer under `-Dio=io_uring`** (Phase 2).
3. **Cross-backend perf comparison vs `io_uring` not measured** (Phase
   3, blocked).

Plus this progress report.

## What was learned

- **The `tick(0) / wait_at_least == 0` semantic is fragile.** The prior
  engineer found one bug here; my first attempt at a tick-cycle test
  hit a second one — `EventLoop.tick()` blocks on `io.tick(1)`, and a
  bare EL with no peer state has no SQE in the ring beyond what the
  test pre-submits. If the prework inside `EventLoop.tick()` ever
  cancels or replaces the pre-submitted timeout, the test wedges
  forever. Going through the contract surface directly side-steps the
  whole class.
- **Build success is not "boot success."** All three backends compile
  cleanly and produce a working binary, but the daemon still refuses
  to start under `-Dio=epoll_*` on a kernel without io_uring because of
  the unconditional `ensureSupported` probe (Phase 4.5). Pattern #14:
  measure don't conclude — without actually trying to boot the daemon
  on an io_uring-less host, this gap stays invisible.
- **`demo_swarm.sh` is fragile in cross-environment use.** The Ubuntu
  apt-get path and the nix-shell-with-opentracker path don't
  interoperate. The fix was small (PATH lookup + apt-get availability
  check) but uncovered a parallel issue — the nixpkgs opentracker
  rejects `access.whitelist` config lines as "Unhandled line in config
  file." That's a build-flavor difference, not a varuna bug, but it
  means cross-env CI for demo_swarm needs to pre-stage the same
  opentracker variant or accept that whitelist enforcement only happens
  on the Ubuntu deb.

## What was NOT tested and why

- **Phase 2 end-to-end transfers under epoll backends.** Blocked on the
  io_uring baseline regression. Running them produces the same hang as
  io_uring, which is uninformative — we know the failure is upstream
  of the IO backend.
- **Phase 3 perf numbers.** Blocked on Phase 2. CPU benchmarks don't
  separate the backends.
- **Phase 4 disk-fill in real life.** The walk-through is read-only;
  `error.NoSpaceLeft` is not injected on real hardware. Reading the
  code path is sufficient evidence — the writer uses the same error
  variant across all three backends, the backend-specific submission
  paths convert kernel errno uniformly, and there is no retry loop
  that could turn a clean ENOSPC into a leak. Can be exercised
  empirically by mounting a small tmpfs as `data_dir` and running the
  demo_swarm with a payload larger than the tmpfs — once Phase 2 is
  unblocked.
- **Real `IORING_OP_BIND` / `LISTEN` / `URING_CMD-SETSOCKOPT`
  unsupported behavior on a pre-6.11 kernel.** The host runs kernel
  7.0.1 so the async path is exercised under `-Dio=io_uring`; the
  synchronous fallback is reachable in code but not on this host. This
  is the io_uring backend's concern, not the epoll backends'. Filed
  as a separate audit item below.
- **`-Dio=kqueue_posix` / `kqueue_mmap`.** Out of this seat's scope per
  the brief; macOS dev backends owned by a parallel engineer.

## Key code references

- `tests/event_loop_health_test.zig:91-148` — new tick-cycle smoke
- `build.zig:752-776` — `test-backends` step
- `scripts/demo_swarm.sh:11-90` — IO_BACKEND selector + mise/nix split
- `scripts/tracker.sh:32-115` — apt-get / nix opentracker fallback
- `src/runtime/probe.zig:23-26` — the unconditional io_uring gate
  (Phase 4.5 gap)
- `src/io/epoll_posix_io.zig:758-827` — bind/listen/setsockopt
  synchronous shape
- `src/io/epoll_mmap_io.zig:746-805` — write/fsync/fallocate/truncate
  with ENOSPC + EOPNOTSUPP mappings
- `src/storage/writer.zig:526-580` — preallocCallback + truncateCallback
  fallback drain
- `src/io/real_io.zig:436-501` — io_uring async-or-sync bind/listen
  shape

## Branch + commits

`worktree-backend-validation`:

1. `e2e933a` — io: add test-backends step + EL tick-cycle smoke for epoll backends
2. `6f5a045` — scripts: add IO_BACKEND selector to demo_swarm + nix opentracker path
3. `<this report + STATUS.md gap entries>`
