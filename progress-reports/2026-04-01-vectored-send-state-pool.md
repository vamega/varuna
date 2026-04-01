# 2026-04-01: vectored send-state pool

## What was done and why

- Added a bounded `VectoredSendPool` to `EventLoop`.
- Reused packed plaintext `sendmsg` state blocks by batch-capacity class instead of allocating one aligned backing block per batch.
- Kept large outlier batches on exact heap allocation so the pooled classes stay simple and bounded.

This was the next allocator target after piece-buffer pooling. The plaintext upload path was already zero-copy for payload bytes, but every batch still allocated a packed block containing the `VectoredSendState`, piece headers, iovecs, and retained piece-buffer refs.

## What was learned

- The packed send-state block is a good pool candidate because its lifetime is CQE-bound, not stack-bound. A normal arena would be the wrong ownership model here.
- Reusing the whole packed block is simpler than trying to pool headers, iovecs, and ref arrays separately.
- Even though the allocation size is small, removing it still matters on the full plaintext upload path because the batch happens every tick.

## Measured result

- `zig build -Doptimize=ReleaseFast perf-workload -- seed_plaintext_burst --iterations=500 --scale=8`
  before this pass: `12176541 ns`, `501` allocs, `500` frees, `276096` bytes allocated
  after: `6933360 ns`, repeat `6796282 ns`, `2` allocs, `0` frees, `672` live/peak retained bytes

## Remaining issues / follow-up

- The encrypted upload path still uses the copied contiguous-buffer fallback.
- `sendmsg_zc` is still optional future work if real swarm traces show the current plaintext path remains hot.

## Code references

- `src/io/event_loop.zig:371`
- `src/io/event_loop.zig:1811`
- `src/io/event_loop.zig:1904`
- `src/io/seed_handler.zig:63`
