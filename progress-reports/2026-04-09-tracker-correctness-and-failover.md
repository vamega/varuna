# 2026-04-09: Tracker Correctness And Failover

## What was done and why

Fixed the remaining correctness gap in parallel announces and UDP retry validation.

- `src/tracker/multi_announce.zig:33` now returns as soon as the first tracker response with peers wins instead of joining every worker thread before returning. The old behavior called itself "first successful response wins" but still blocked on all workers.
- `src/tracker/multi_announce.zig:61` now allocates the worker thread array to the full tracker URL count, so URLs past index 7 are no longer silently ignored.
- `src/tracker/udp.zig:500` now tracks the live announce transaction ID across stale-connection recovery. When the cached UDP connection ID is invalidated and a fresh connect is performed, the retry announce gets a fresh txid and the final response is validated against that fresh txid.

## What was learned

- "First success wins" is not just a selection policy; it is also a completion policy. Returning the winner after all joins still creates tracker-tail latency for the caller.
- UDP tracker retry paths are easy to get subtly wrong because connection ID refresh and transaction ID refresh are coupled. Reusing the original txid after rebuilding the request makes valid retry responses look forged.

## Remaining issues / follow-up

- `announceWorker` still only accepts winning responses that contain peers. If a tracker legitimately returns zero peers but otherwise succeeds, the caller still treats that as failure. That remains a separate follow-up item.
- The background cleanup thread deliberately frees losing responses after the caller returns. If this code is revisited, preserve that ownership split.

## Code references

- `src/tracker/multi_announce.zig:33`
- `src/tracker/multi_announce.zig:90`
- `src/tracker/multi_announce.zig:128`
- `src/tracker/udp.zig:500`
- `src/tracker/udp.zig:539`
