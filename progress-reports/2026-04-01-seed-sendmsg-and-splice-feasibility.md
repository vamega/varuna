## What was done and why

I added three benchmark-only upload workloads to compare plausible syscall strategies for plaintext seeding:

- `seed_send_copy_burst`: build one contiguous `piece` message buffer and submit it with `io_uring` `send`
- `seed_sendmsg_burst`: build per-block `13` byte headers and submit header + piece-data iovecs with `io_uring` `sendmsg`
- `seed_splice_burst`: send the header separately, then move file bytes through `io_uring` `splice` using a pipe

The goal was to decide whether the next production seed-path optimization should be vectored `sendmsg`, `sendmsg_zc`, `splice` / `sendfile`, or deeper fixed-buffer work.

Key code references:

- benchmark scenarios: [src/perf/workloads.zig](/home/vmadiath/projects/varuna-uringopt/src/perf/workloads.zig#L49)
- copy benchmark: [src/perf/workloads.zig](/home/vmadiath/projects/varuna-uringopt/src/perf/workloads.zig#L486)
- `sendmsg` benchmark: [src/perf/workloads.zig](/home/vmadiath/projects/varuna-uringopt/src/perf/workloads.zig#L539)
- `splice` benchmark: [src/perf/workloads.zig](/home/vmadiath/projects/varuna-uringopt/src/perf/workloads.zig#L599)
- current production seed queue and flush path: [src/io/seed_handler.zig](/home/vmadiath/projects/varuna-uringopt/src/io/seed_handler.zig#L25), [src/io/seed_handler.zig](/home/vmadiath/projects/varuna-uringopt/src/io/seed_handler.zig#L187)

## What was learned

- Plain vectored `sendmsg` is promising for plaintext seeding. On the same loopback TCP benchmark shape (`200` iterations, `8` blocks per burst), the contiguous copy path took about `54` to `59 ms`, while `sendmsg` took about `39` to `46 ms`. That is about a `23%` to `33%` wall-clock win.
- `sendmsg` also drastically reduced transient allocation volume on that benchmark shape, from `26.2 MB` down to `72 KB`.
- `splice` is a poor fit for the current BitTorrent upload path. The measured file-to-pipe-to-socket prototype took about `180 ms` on the current rerun and remained much slower than both the contiguous copy path and `sendmsg`.
- This is not blocked on Zig bindings. The local Zig `0.15.2` `IoUring` wrapper already exposes `sendmsg_zc`, `splice`, `read_fixed`, and `write_fixed`; the unresolved questions are framing, lifetime, and whether the kernel path is actually faster for this workload.
- Local man pages line up with the benchmark result:
  - `sendfile(2)` still needs a separate header send if the protocol requires one before the file bytes.
  - `splice(2)` requires one endpoint to be a pipe, so the `io_uring` equivalent is still a file -> pipe -> socket sequence.
- `READ_FIXED` / `WRITE_FIXED` do not solve the main upload problem. They can help the registered-buffer layer, but the real hot-path question here is how to frame `piece` messages without copying the payload and while keeping the backing pages alive until the send completion arrives.

## Piece-buffer lifetime issue

The current production seed path is only safe because it copies before the async send:

- `queuePieceBlockResponse()` records `piece_data` slices directly in `queued_responses`: [src/io/seed_handler.zig](/home/vmadiath/projects/varuna-uringopt/src/io/seed_handler.zig#L25)
- `handleSeedDiskRead()` installs the latest disk-read buffer as `cached_piece_data` and defers the previous cache buffer for later release: [src/io/seed_handler.zig](/home/vmadiath/projects/varuna-uringopt/src/io/seed_handler.zig#L143)
- `flushQueuedResponses()` then copies each queued block into a fresh contiguous `send_buf`, submits the socket send, and only then releases deferred piece buffers: [src/io/seed_handler.zig](/home/vmadiath/projects/varuna-uringopt/src/io/seed_handler.zig#L187)

That means `queued_responses` does not currently own piece memory. It only borrows slices into the cache. A direct `sendmsg` or `sendmsg_zc` implementation would point iovecs at those borrowed pages, so the piece buffer would have to stay alive until the socket CQE reports completion. Right now that is not guaranteed:

- a later read can replace `cached_piece_data`
- old cached buffers are moved into `deferred_piece_buffers`
- pooled piece buffers can be returned to the huge-page cache after the flush

A correct production scatter/gather upload path therefore needs explicit ownership across completion, likely refcounted piece-buffer objects or equivalent tracked lifetimes on each queued send.

## Remaining issues and follow-up work

- The promising next production step is a plaintext-only vectored send path with tracked piece-buffer ownership and partial-send fallback.
- `sendmsg_zc` should only be considered after the lifetime model exists, because zero-copy completion notifications add CQE complexity but do not remove the ownership requirement.
- `splice` / `sendfile` should not be pursued further for the current peer upload path unless the framing model changes substantially.
