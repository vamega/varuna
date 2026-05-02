# io_uring Swarm Throughput Profile

## What Changed And Why

- Added non-zero per-piece markers to `scripts/demo_swarm.sh` generated `PAYLOAD_BYTES` fixtures. The old sparse all-zero fixture let a freshly preallocated downloader file hash as complete before any payload transfer.
- Added an opt-in `VARUNA_STRACE_DIR` wrapper in `scripts/demo_swarm.sh` so swarm daemons can be launched under filtered `strace` from process start when host ptrace attach is blocked.

## What Was Learned

- Reproduced the reported 1 GiB io_uring result before changing the harness: `22.492s`, `45.527 MiB/s`; repeat: `22.532s`, `45.446 MiB/s`.
- One-run comparisons before the harness fix: `epoll_posix` `16.454s`, `62.234 MiB/s`; `epoll_mmap` `21.048s`, `48.651 MiB/s`.
- The downloader log for the original 1 GiB io_uring run showed `recheck complete: 1024/1024 pieces valid` on the download side, proving the run was not measuring real transfer throughput.
- Filtered `strace` with `VARUNA_STRACE_DIR` on a 256 MiB pre-fix io_uring run showed no direct peer `send*`, `recv*`, `connect`, or `accept4` syscalls in the daemon hot path. Direct `read`/`write` entries were eventfd/config/SQLite/loader activity; active peer/file operations went through `io_uring_enter`.
- After the marker fix, a 16 MiB io_uring sanity run started with downloader recheck `0/1024 pieces valid`, completed, and `cmp` verified the downloaded file matched the seed file.
- A 256 MiB post-fix io_uring run stayed at `progress: 0.0000`, `downloaded: 0`, `num_seeds: 0` for several minutes and was terminated. This is a separate real-transfer follow-up now that the false-complete path is removed.

## Remaining Issues Or Follow-Up

- The original io_uring-vs-epoll gap is not a valid backend conclusion until the swarm harness measures actual non-zero payload transfer at the requested size.
- Next experiment: debug why the post-fix 256 MiB real-transfer run handshakes but does not download, starting from tracker peer visibility and request/bitfield flow between the two daemons.
- If large real transfers are expected to work, add a focused daemon or harness test that asserts a fresh downloader recheck begins with `0` complete pieces for generated perf fixtures.

## Key Code References

- `scripts/demo_swarm.sh:92` - generated payload piece-length helper.
- `scripts/demo_swarm.sh:111` - sparse fixture marker writer.
- `scripts/demo_swarm.sh:123` - optional daemon `strace` launcher.
- `scripts/demo_swarm.sh:154` - marker writer invoked for `PAYLOAD_BYTES`.
