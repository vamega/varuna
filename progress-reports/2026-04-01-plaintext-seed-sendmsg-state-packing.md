## What was done and why

I followed up on the first production plaintext seed `sendmsg` landing by removing the extra tracked-send allocation that it introduced.

The previous implementation already kept piece pages alive correctly and avoided copying payload bytes into a fresh batch buffer, but it still allocated:

- one `VectoredSendState` object
- one backing block for headers, iovecs, and retained piece-buffer refs

per plaintext send batch.

This pass packs the `VectoredSendState` itself into that same backing block, so each plaintext batch now needs only one allocator call for its send state.

Key code references:

- packed send state definition and release: [src/io/event_loop.zig](/home/vmadiath/projects/varuna/src/io/event_loop.zig#L266), [src/io/event_loop.zig](/home/vmadiath/projects/varuna/src/io/event_loop.zig#L1677)
- packed state builder: [src/io/seed_handler.zig](/home/vmadiath/projects/varuna/src/io/seed_handler.zig#L63)
- production plaintext batch submit path: [src/io/seed_handler.zig](/home/vmadiath/projects/varuna/src/io/seed_handler.zig#L141)
- benchmark surface: [src/perf/workloads.zig](/home/vmadiath/projects/varuna/src/perf/workloads.zig#L445)

## What was learned

- The earlier `sendmsg` production landing had already removed the expensive payload copy, but allocator-call count was still inflated by the tracked-send bookkeeping itself.
- Packing the state into the backing block fixed that cleanly:
  - `seed_plaintext_burst --iterations=500 --scale=8`
  - before this pass: about `12.5 ms` to `13.0 ms`, `1001` alloc calls, `276 KB` transient bytes
  - after this pass: about `10.7 ms` to `12.8 ms`, `501` alloc calls, `276 KB` transient bytes
- So this is a second-stage cleanup win: same low transient memory footprint, fewer allocator calls, and a modest additional wall-clock improvement.

## Remaining issues and follow-up work

- The plaintext path is now in a much better place. The next optional experiment here is a small pool for the packed send-state blocks, but it is no longer urgent.
- `sendmsg_zc` is still only worth trying if real swarm measurements say plaintext seeding remains hot after this pass.
- The encrypted seed path still copies, by design, because the current MSE path wants one contiguous buffer for in-place encryption.
