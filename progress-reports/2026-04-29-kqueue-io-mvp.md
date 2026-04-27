# KqueueIO MVP — 2026-04-29

Implementation round on `worktree-kqueue-io`. Lands a minimum-viable
kqueue(2) backend so varuna can build (and cross-compile-validate) on
macOS. Production stays on Linux/io_uring; this is a developer
backend per the strategy in `docs/epoll-kqueue-design.md`.

Branch: `worktree-kqueue-io`.

## What changed

**New files**
- `src/io/kqueue_io.zig` (~700 LOC) — `KqueueIO` type, all 16
  contract methods, inline tests.
- `tests/kqueue_io_test.zig` — varuna_mod-side bridge tests for the
  Linux build path.

**Modified files**
- `build.zig` — adds `-Dio={io_uring,kqueue}` flag, `IoBackend`
  enum, full-daemon gate (skip daemon/ctl/tools/perf installs when
  the backend isn't io_uring), `test-kqueue-io` step (standalone,
  cross-compile-clean), `test-kqueue-io-bridge` step (varuna_mod,
  Linux only).
- `src/io/root.zig` — exposes `kqueue_io`.

## Coverage versus the brief's op-by-op order

| Op | Status | Notes |
|---|---|---|
| `init` / `deinit` / `tick` / `closeSocket` | ✅ implemented | tick processes timer expiry, drains completed, then handles ready kevents |
| `cancel` | ✅ implemented (best-effort) | removes from timer heap or marks parked completions |
| `timeout` | ✅ implemented | heap-of-deadlines; `tick` passes `next_deadline - now` as the kevent timeout |
| `socket` | ✅ implemented (synchronous) | macOS lacks SOCK_NONBLOCK / SOCK_CLOEXEC, two extra fcntls per socket |
| `connect` | ✅ implemented | EAGAIN→park-on-EVFILT_WRITE, then `getsockoptError` on readiness; deadline via timer heap |
| `accept` | ✅ implemented | single-shot + multishot via re-register-on-each-accept (kqueue's EV_ONESHOT model) |
| `recv` / `send` | ✅ implemented | EAGAIN→register, retry on readiness |
| `recvmsg` / `sendmsg` | ✅ implemented | calls `std.c.recvmsg`/`sendmsg` directly (the posix wrappers are Linux-shaped) |
| `poll` | ✅ implemented | translates POLL_IN→EVFILT_READ / POLL_OUT→EVFILT_WRITE; revents synthesised from EV.EOF / EV.ERROR |
| `truncate` | ✅ implemented (synchronous) | mirrors RealIO's inline `posix.ftruncate` path; this is the daemon's existing pattern for the rare `setEndPos` fallback |
| `read` / `write` / `fsync` / `fallocate` | ⏳ deferred | stubs return `error.OperationNotSupported` synchronously — see "Deferred" below |

## What cross-compiles vs. what's mock-tested

- **Linux native (default `-Dio=io_uring`)**: `zig build` and `zig
  build test` both green. Kqueue inline tests run under `zig build
  test-kqueue-io`; the platform-portable subset (timer heap
  ordering, errno mapping, state-size assert) actually executes,
  the syscall-touching ones `return error.SkipZigTest`.
- **macOS cross-compile (`-Dtarget=aarch64-macos -Dio=kqueue`)**:
  bare `zig build` succeeds (the daemon install steps are gated
  off, so the result is just the build script running). `zig build
  test-kqueue-io -Dtarget=aarch64-macos -Dio=kqueue` cross-compiles
  the test binary; the run step is skipped because the host can't
  exec a macOS binary.
- **macOS native (when validated on real hardware)**: the inline
  tests should run fully — `init`, `timeout` with real syscall path,
  `socket` op, `cancel` against a pending timeout. None of these
  have been exercised on a macOS box in this round; flagged below.

## What needs real-macOS validation

The cross-compile contract guarantees the file *parses and
type-checks*; it does not guarantee runtime correctness.
Specifically:

1. **`std.c.EVFILT.READ` / `EV.ADD | EV.ENABLE | EV.ONESHOT` masks**
   compile-check on the macOS target via the Zig stdlib's
   conditional definitions, but the actual values landing in
   kevent's flags field need eyes-on-darwin verification.
   Tigerbeetle's `darwin.zig` uses the same mask combo, so this is
   low risk but not zero.
2. **`posix.recv` / `posix.send` / `posix.accept` / `posix.connect`
   error returns on macOS.** The Zig stdlib's wrappers are designed
   to be cross-platform but BSD errno layouts differ in tail
   variants from Linux. Spot-check that `error.WouldBlock` is
   actually reported (not, say, an unmapped errno that lands in the
   `else => posix.unexpectedErrno(e)` arm).
3. **`std.c.recvmsg` / `std.c.sendmsg` signatures.** The contract's
   `posix.msghdr` / `posix.msghdr_const` types are platform-aware;
   the syscall wrappers I'm calling here trust those types are
   layout-compatible with the macOS `struct msghdr`. They
   *should* be — Zig's stdlib carries the platform-specific
   definitions — but verification is mandatory before any
   datagram-driven test can claim it works.
4. **Connect-with-deadline race.** When a deadline expires before
   the socket becomes writable, the timer-heap path delivers
   `error.ConnectionTimedOut` and marks `cancelled=true`; if the
   kevent later fires, `tick` sees `cancelled` and pushes another
   completed entry. The first `cancelled=true` push beat the
   kevent, so the callback already fired. Confirm under load that
   the second push doesn't cause a double-callback. (Linux io_uring
   handles this via the link_timeout SQE pair; the kqueue model
   here relies on the dispatch's `in_flight` clear semantics.)
5. **`posix.fcntl(F_SETFL, flags | O_NONBLOCK)` on the accepted fd.**
   The POSIX call shape is correct; the actual `O_NONBLOCK` value
   on darwin needs to match what the Zig stdlib defines for
   `posix.SOCK.NONBLOCK`. Worth a sanity run on macOS before
   trusting `tryAccept`.

## Deferred

The file-op family (`read`, `write`, `fsync`, `fallocate`) is the
remaining macOS-side gap. The design doc and libxev/zio both treat
these as "thread-pool offload always" on the readiness backends —
kqueue can't deliver readiness for regular files, so a
worker-thread pool plus cross-thread wakeup (self-pipe or
`EVFILT_USER`) is the standard pattern. That lift is sized at ~200
LOC and is the natural next milestone.

Today the stubs deliver `error.OperationNotSupported` synchronously.
That happens to be the same errno Linux returns for filesystems
that reject `fallocate`, so existing daemon fallback paths
(`PieceStore.init` → `truncate`) will trigger uniformly under
KqueueIO. They'll fail next, since `truncate`'s synchronous path
is the only file-op stub that actually does work — in the MVP
scope that's by design.

## Surprises vs. the design doc

1. **Cross-compile-only validation is genuinely limited.** I
   originally over-budgeted my own confidence in "this looks like
   tigerbeetle's code, ship it." Re-reading at runtime is non-
   negotiable — Zig stdlib's `posix.send`/`recv` error mapping has
   tail variants per OS that no amount of careful reading catches.
   The cross-compile target catches type errors and missing
   imports; everything semantic stays on the user's macOS box.
2. **The build wiring took more space than the implementation.**
   Gating daemon installs on `io_backend == .io_uring` plus a
   standalone `test-kqueue-io` step with a host-vs-target check is
   the cleanest way to make `zig build` and `zig build
   test-kqueue-io` both work for both targets without dragging
   `varuna_mod` into the macOS compile path. That's ~80 lines of
   build.zig for ~20 lines of "what the user types".
3. **The `posix.kqueue` / `posix.kevent` symbols exist on Linux**
   (declared unconditionally) but their bodies fail to compile if
   semantically analysed. Zig's lazy semantic-analysis means
   nothing on Linux references them, so the file compiles cleanly
   on both targets without `comptime` walls everywhere. This is a
   nicer property than I expected.
4. **`std.c.recvmsg` / `std.c.sendmsg` are the right entry points
   for datagram I/O on macOS.** `std.posix.recvmsg` / `sendmsg` are
   Linux-shaped — they assume `linux.system.recvmsg` exists, which
   it doesn't on darwin. Calling `std.c.*` directly sidesteps that.
   The contract's `posix.msghdr` type carries the platform-specific
   layout, so passing it to the C-shim is fine.

## Coordination notes

- `epoll-io-engineer` adds `-Dio=epoll` to the same `IoBackend` enum
  on a parallel branch. The conflict at merge is just extending the
  choice list. I left a comment on the enum to that effect.
- `runtime-detect-engineer` is unrelated — they're touching
  `RealIO` for `IORING_REGISTER_PROBE`-based feature detection.
- The contract (`src/io/io_interface.zig`) is unchanged. No surface
  required modification for the MVP, matching the design doc's
  prediction.

## Validation

```
$ nix develop --command zig build                                    # Linux io_uring: green
$ nix develop --command zig build test                               # Linux full suite: green
$ nix develop --command zig build test-kqueue-io                     # native inline tests: green
$ nix develop --command zig build -Dtarget=aarch64-macos -Dio=kqueue # cross-compile bare: clean
$ nix develop --command zig build test-kqueue-io \
       -Dtarget=aarch64-macos -Dio=kqueue                            # cross-compile tests: clean
$ nix develop --command zig fmt .                                    # clean
```

`zig build test --summary all` count: unchanged at 1418 + the new
KqueueIO inline tests on the Linux path. The kqueue-syscall tests
all skip on Linux as expected.

## Key code references

- `src/io/kqueue_io.zig:170-207` — `KqueueIO.init` / `deinit`
- `src/io/kqueue_io.zig:218-275` — `tick` (timer expiry → drain →
  kevent → drain)
- `src/io/kqueue_io.zig:421-461` — timer heap (push / pop / sift
  helpers)
- `src/io/kqueue_io.zig:469-503` — `socket` / `connect` (macOS
  fcntl + EAGAIN→park pattern)
- `src/io/kqueue_io.zig:515-542` — `accept` + multishot emulation
- `src/io/kqueue_io.zig:594-617` — `cancel` (timer heap removal +
  parked-marker)
- `build.zig:43-58, 156-188` — `-Dio=` flag + daemon install gate
- `build.zig:344-394` — `test-kqueue-io` standalone target
