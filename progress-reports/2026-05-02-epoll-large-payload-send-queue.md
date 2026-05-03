## What changed and why

Large epoll-backed live swarm transfers could stall after handshake because the
epoll fallback backends allowed only one pending write completion per socket.
When the peer request pipeline submitted more than one send before the socket
became write-ready, the second send failed with `error.AlreadyInFlight`. The
request state had already advanced, so some block requests were never sent and
large transfers could stop making piece progress.

Both epoll backends now keep a FIFO write queue per fd while preserving the
single read and poll lanes. A write completion that rearms itself during its own
callback is put back at the front of the queue so a partial TCP send finishes
before later writes on the same socket.

## What was learned

A 512 MiB `epoll_posix` live run passed, but a 768 MiB run reliably reproduced
the stall shape in about 150 seconds, timing out at 0.0065 progress. After the
queueing fix, 768 MiB live runs completed for both epoll backends:

- `epoll_posix`: 28.225s transfer time, 27.210 MiB/s
- `epoll_mmap`: 33.690s transfer time, 22.796 MiB/s

Focused regression tests now submit two same-fd sends before readiness and
verify that both complete in order.

## Remaining issues or follow-up

The epoll backends still serialize writes per fd rather than matching
`io_uring`'s ability to have several kernel-submitted sends outstanding at once.
That is intentional for correctness in this fallback path, but future throughput
work could measure whether batching multiple queued writes per readiness tick is
worth the added complexity.

## Key code references

- `src/io/epoll_posix_io.zig:135` - per-fd write queue state
- `src/io/epoll_posix_io.zig:144` - write queue helpers
- `src/io/epoll_posix_io.zig:598` - partial-send front requeue guard
- `src/io/epoll_posix_io.zig:1107` - queued write registration
- `src/io/epoll_mmap_io.zig:115` - per-fd write queue state
- `src/io/epoll_mmap_io.zig:124` - write queue helpers
- `src/io/epoll_mmap_io.zig:494` - partial-send front requeue guard
- `src/io/epoll_mmap_io.zig:1111` - queued write registration
- `tests/epoll_posix_io_test.zig:265` - same-fd send queue regression test
- `tests/epoll_mmap_io_test.zig:282` - same-fd send queue regression test
