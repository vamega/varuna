# Convert RPC server hot-path close to io_uring

**Date:** 2026-03-29

## What was done

Replaced three `posix.close(fd)` calls in `src/rpc/server.zig` with
`IORING_OP_CLOSE` SQEs via `self.ring.inner.close(0, fd)`. These are
fire-and-forget: the SQE is queued with `user_data=0` and the CQE is
silently consumed by the dispatch loop's `else => {}` branch.

### Changed call sites

1. **`closeClient` (line ~259)** -- called after every completed
   request-response cycle (close-after-response mode) and on recv
   errors. This is the highest-frequency close path.

2. **`handleAccept` reject path (line ~144)** -- when the server is at
   `max_api_clients`, the accepted fd is closed immediately.

3. **`handleAccept` alloc failure (line ~152)** -- when recv buffer
   allocation fails, the accepted fd is closed.

### What was NOT changed

- `errdefer posix.close(fd)` in `init` -- one-time setup, acceptable.
- `deinit` closing all clients + listen_fd -- shutdown cleanup, acceptable.
- Test code `defer posix.close(client_fd)` -- test-only, not daemon code.

## What was learned

- The `Ring` wrapper's `close()` method is synchronous (submit + wait for
  CQE), so for fire-and-forget async close we go through `ring.inner`
  (the raw `std.os.linux.IoUring`) directly, matching how the server
  already uses `ring.inner.accept/recv/send`.

- `user_data=0` with no matching op code means the close CQE falls
  through the dispatch switch's `else => {}` -- no special handling needed.

## Code references

- `src/rpc/server.zig:144` -- handleAccept reject path
- `src/rpc/server.zig:152` -- handleAccept alloc failure path
- `src/rpc/server.zig:259-264` -- closeClient
