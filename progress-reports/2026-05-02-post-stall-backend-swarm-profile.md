# Post-Stall Backend Swarm Throughput Profile

## What Changed And Why

- Ran post-stall live swarm measurements with marked payload fixtures after the sparse-payload false-complete and tracker self-peer fixes.
- Fixed `scripts/backend_swarm_matrix.sh` so multi-backend runs do not reuse one prebuilt daemon binary when `SKIP_BUILD=1`; the script now forces per-backend rebuilds for multi-backend matrices.
- Added the measured snapshot to `perf/README.md` for future comparison.

## What Was Measured

Commands used `nix shell nixpkgs#zig_0_15 nixpkgs#opentracker --command bash scripts/backend_swarm_matrix.sh` with `ZIG_BUILD_EXTRA_ARGS="-Doptimize=ReleaseFast --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2"`.

| Payload | Backend | Status | Transfer seconds | Throughput MiB/s | Output |
|---------|---------|--------|------------------|------------------|--------|
| 256 MiB | `io_uring` | pass | 23.933 | 10.697 | `perf/output/backend-swarm-poststall-256m-20260502-200904/run-1/io_uring/` |
| 256 MiB | `epoll_posix` | pass | 18.886 | 13.555 | `perf/output/backend-swarm-poststall-256m-20260502-200904/run-1/epoll_posix/` |
| 256 MiB | `epoll_mmap` | pass | 28.273 | 9.055 | `perf/output/backend-swarm-poststall-256m-20260502-200904/run-1/epoll_mmap/` |
| 1 GiB | `io_uring` | pass | 42.728 | 23.966 | `perf/output/backend-swarm-poststall-1g-20260502-202455/run-1/io_uring/` |
| 1 GiB | `epoll_posix` | fail | N/A | N/A | `perf/output/backend-swarm-poststall-1g-20260502-202455/run-1/epoll_posix/` |
| 1 GiB | `epoll_mmap` | fail | N/A | N/A | `perf/output/backend-swarm-poststall-1g-epoll-mmap-20260502-203421/run-1/epoll_mmap/` |

## What Was Learned

- The 256 MiB matrix is a valid all-backend post-stall throughput baseline; each run started with the downloader recheck at `0` valid pieces and completed `cmp` verification.
- The 1 GiB `io_uring` result completed and showed higher throughput than its 256 MiB run, so small-payload startup and polling overhead still skews short runs.
- Both 1 GiB readiness backends timed out after MSE handshake: `epoll_posix` stopped at progress `0.0039`, and `epoll_mmap` stopped at progress `0.0586`.
- The next likely bottleneck is request/piece progress after MSE handshake in the epoll-backed live swarm path, not tracker discovery or the sparse-payload artifact.

## Remaining Issues Or Follow-Up

- Run a focused readiness-backend large-transfer trace around peer request issuance, piece writes, and readiness rearming. The daemon logs are too sparse to tell whether the seeder stops sending, the downloader stops requesting, or completions stop being drained.
- Consider a non-ReleaseFast or instrumentation build for 512 MiB and 1 GiB epoll runs to locate the stall boundary before changing backend internals.
- Avoid treating `zig build perf-swarm-backends` results from before this branch as cross-backend-valid if they used `SKIP_BUILD=1`; labels may have reused the same daemon binary.

## Key Code References

- `scripts/backend_swarm_matrix.sh:63` - backend-count validation used for safe multi-backend rebuild behavior.
- `scripts/backend_swarm_matrix.sh:89` - `SKIP_BUILD=1` override for multi-backend matrices.
- `perf/README.md:69` - post-stall live swarm snapshot and interpretation.
