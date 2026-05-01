# Backend Swarm Perf Harness

## What changed

- Added `zig build perf-swarm-backends`, a separate build step from `test-swarm-backends`.
- Extended `scripts/backend_swarm_matrix.sh` with `SWARM_MATRIX_MODE=perf`, `RUNS`, perf-specific defaults, absolute output/work paths, throughput calculation, and per-run log pointers.
- Documented the workflow in `perf/README.md` and closed the stale STATUS follow-up that said cross-backend live-swarm perf was unmeasured.

## What was learned

The validation matrix already had the right process boundary: it owns backend iteration, unique ports, work directories, and log preservation. Keeping perf mode in that script avoids duplicating tracker/seeder/downloader setup and keeps failures diagnosable through the same per-backend `run.log` files.

The first live smoke exposed a harness bug rather than a daemon/backend issue: a relative `OUT_DIR` produced relative `WORK_DIR` paths, and those paths were written into daemon configs that are read after `demo_swarm.sh` changes cwd into each daemon directory. The matrix now canonicalizes `OUT_DIR` before computing work directories, so both default absolute paths and documented relative overrides are safe.

Interpret the summary as a loopback live-swarm comparison, not a pure event-loop microbenchmark. `throughput_mib_s` is computed from `payload_bytes / transfer_seconds`, where `transfer_seconds` starts when the downloader torrent is added and stops when completed progress is observed. Small payloads are noisy because daemon startup and one-second progress polling dominate.

The first three-backend smoke used a 4 MiB payload and one run per backend. All three completed:

| Backend | Transfer seconds | Throughput MiB/s |
| --- | ---: | ---: |
| `io_uring` | 5.139 | 0.778 |
| `epoll_posix` | 3.075 | 1.301 |
| `epoll_mmap` | 5.117 | 0.782 |

These numbers are a harness smoke, not a backend ranking. A credible comparison should use larger payloads and multiple runs.

## How to run

```bash
zig build -Doptimize=ReleaseFast perf-swarm-backends
BACKENDS="io_uring epoll_posix epoll_mmap" PAYLOAD_BYTES=67108864 RUNS=3 TIMEOUT=240 zig build -Doptimize=ReleaseFast perf-swarm-backends
```

The output summary is written to `perf/output/backend-swarm-perf-*/summary.tsv` with:

```text
run	backend	status	elapsed_seconds	transfer_seconds	payload_bytes	throughput_mib_s	work_dir	log
```

## Remaining issues or follow-up

- Use larger payloads and `RUNS>1` before making backend performance claims from the numbers.
- A focused `EventLoopOf(IO)` socket/timer microbenchmark would still be useful if we need to isolate backend overhead from torrent protocol and RPC setup.
- macOS `kqueue_*` comparisons still need a Darwin host.

## Code references

- `build.zig:1330`
- `scripts/backend_swarm_matrix.sh:6`
- `scripts/backend_swarm_matrix.sh:30`
- `scripts/backend_swarm_matrix.sh:64`
- `scripts/backend_swarm_matrix.sh:106`
- `perf/README.md:42`
- `STATUS.md:34`
