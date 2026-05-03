# Backend Swarm 1 GiB Validation

## What changed and why

- Re-ran the ReleaseFast live swarm matrix with a 1 GiB marked payload across `io_uring`, `epoll_posix`, and `epoll_mmap`.
- Updated `perf/README.md` with the current 1 GiB validation snapshot.

## What was learned

- The current tree no longer reproduces the previous 1 GiB epoll readiness-backend stalls.
- All three Linux backends completed the marked-payload transfer and `cmp` validation:
  - `io_uring`: 43.088s, 23.765 MiB/s
  - `epoll_posix`: 41.367s, 24.754 MiB/s
  - `epoll_mmap`: 44.494s, 23.014 MiB/s
- These are single-run loopback smoke results; they validate large-transfer progress, not definitive backend throughput ranking.

## Remaining issues or follow-up

- No Stage 1 code fix was needed.
- Future backend throughput work should use multiple runs before drawing performance conclusions.

## Key references

- `perf/README.md:83`
- `perf/output/backend-swarm-stage1-1g-20260503/summary.tsv`
