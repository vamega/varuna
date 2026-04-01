# 2026-04-01: Peer listener `accept_multishot`

## What was done and why

- Added `peer_accept_burst` to `varuna-perf` so inbound listener changes can be measured against the real shared `EventLoop` accept path instead of synthetic accept-only loops.
- Switched the shared peer listener from one-shot `accept` to `accept_multishot`.
- Updated `handleAccept()` so it only re-arms accept when the kernel drops `IORING_CQE_F_MORE` or returns an error that terminates the multishot stream.

## What was learned

- The peer listener path is cheap enough that the benefit is workload-dependent. On this host the improvement shows up when inbound connections arrive more serially, but a denser 8-thread loopback burst is basically noise.
- That is still relevant for the expected deployment shape: mostly idle seeding torrents that occasionally receive inbound peers are closer to the low-concurrency case than to a synthetic local accept flood.
- The new benchmark also exposed a practical limit of this loopback setup: very high connection counts can exhaust ephemeral ports and return `error.AddressNotAvailable`, so comparison runs need bounded iteration counts.

## Measured results

ReleaseFast on the local loopback harness:

- `peer_accept_burst --iterations=4000 --clients=1`
  one-shot baseline: `727995472 ns`, `739372927 ns`
  multishot: `699668951 ns`, `715792574 ns`, `657787147 ns`
- `peer_accept_burst --iterations=4000 --clients=8`
  one-shot baseline: `150735516 ns`, `158715184 ns`
  multishot: `151998395 ns`, `164377673 ns`

Interpretation:

- The direct A/B sequential case improved by about `5.8%`.
- The 8-thread burst did not show a convincing win, so the change should be understood as a small listener-efficiency improvement, not a major throughput change.

## Remaining issues / follow-up

- uTP `recvmsg_multishot` and zero-copy seed sends remain open and will need their own workload-driven passes.
- If future swarm traces show inbound connection bursts are usually highly concurrent, the practical value of this listener change may be limited relative to bigger wins elsewhere.

## Code references

- Listener submission: `src/io/event_loop.zig:1439`
- Listener completion handling: `src/io/peer_handler.zig:19`
- Benchmark workload: `src/perf/workloads.zig:158`
