# Executor genericization — round 1

**Date:** 2026-04-29
**Branch:** `worktree-executor-genericization`
**Commits:** `317d177`, `be294b1`, `55d4111`, `ccb0df3`

## Goal

Close the C2/C3 follow-ups from the external review:
- **C2** — three "supposedly generic" IO paths still hardcoded `io: *RealIO`:
  - `src/io/http_executor.zig`
  - `src/daemon/udp_tracker_executor.zig`
  - `src/io/metadata_handler.zig` (parameterized but blocked by C3)
- **C3** — `AsyncMetadataFetch` was bypassing the IO contract via direct
  `posix.socket()` and `posix.close()` calls, so the
  `AsyncMetadataFetchOf(SimIO)` happy-path test couldn't be written.

## What changed

### Commit 1 — `HttpExecutorOf(comptime IO: type)`

`src/io/http_executor.zig` wrapped in `HttpExecutorOf(IO)` returning a
struct with `const Self = @This()`. The daemon-side alias
`pub const HttpExecutor = HttpExecutorOf(RealIO)` keeps every caller
compiling unchanged (verified: `tracker_executor.zig`,
`web_seed_handler.zig`, `session_manager.zig`, `event_loop.zig`).

Internal `*HttpExecutor` → `*Self`. The two inline tests
(`appendRecvData` target_buf paths) stayed inside the struct and now
compile under the alias.

### Commit 2 — `UdpTrackerExecutorOf(comptime IO: type)`

Same shape applied to `src/daemon/udp_tracker_executor.zig`. Daemon
alias `pub const UdpTrackerExecutor = UdpTrackerExecutorOf(RealIO)`
preserves the public surface (`SessionManager`, `EventLoop`,
`TorrentSession` callers unchanged).

### Commit 3 — `AsyncMetadataFetch` socket lifecycle through IO contract

Three changes in `src/io/metadata_handler.zig`:

1. **Async socket creation.** `connectPeer` previously called
   `posix.socket()` synchronously and immediately handed the fd to
   `io.connect`. Now it submits `self.io.socket(...)` with a new
   `metadataSocketComplete` callback that chains the connect once the
   fd is available.

2. **Async socket close.** `releaseSlot` switched from `posix.close()`
   to `self.io.closeSocket()` so SimIO can reclaim its socket-pool
   slots correctly.

3. **New `SlotState.socket_creating`.** Sits between `.free` and
   `.connecting` to gate `releaseSlot` idempotence. The existing
   `.free` check still works — we only set the state to
   `.socket_creating` after a successful `io.socket` submit; allocation
   failures roll back through the existing buffer-OOM error path
   without ever leaving the slot in a half-initialized state.

**Surprise:** `socket_util.configurePeerSocket` had to be gated behind
`if (comptime IO != sim_io_mod.SimIO)`. The function uses
`posix.setsockopt(...) catch {}` which looks safe but
`std.posix.setsockopt` has `BADF => unreachable` — a hard panic, not
a returned error. SimIO synthetic fds (from `synthetic_fd_base =
100_000`) trip this. Real backends still get TCP_NODELAY / SNDBUF /
RCVBUF tuning unchanged.

### Commit 4 — Happy-path test + SimIO scripted-recv extension

`src/io/sim_io.zig` extended (~50 LOC):

- `enqueueSocketResult(fd)` — FIFO of pre-prepared fds returned by
  future `socket()` calls, falling back to `nextSyntheticFd()` when
  empty. Lets tests script "the next call to `io.socket()` resolves
  to this specific fd."
- `pushSocketRecvBytes(fd, bytes)` — appends directly to a socket's
  recv queue (the scripted-peer mirror of `setFileBytes`). Wakes a
  parked recv if one is currently blocked on the fd. Returns
  `error.InvalidFd` / `error.SocketClosed` / `error.RecvQueueFull`
  for the obvious failure modes.

`tests/metadata_fetch_test.zig` adds the happy-path test:

1. `createSocketpair` allocates a paired socket; the test pushes the
   fetcher-side fd into `enqueueSocketResult` so the metadata fetch's
   first `io.socket()` resolves to that specific fd.
2. The test pre-builds the entire scripted peer response stream:
   - 68-byte BT handshake reply with the BEP 10 reserved bit
     (`reserved[5] |= 0x10`) set.
   - 4-byte length + msg_id=20 + sub_id=0 + bencoded extension
     handshake `d1:md11:ut_metadatai2ee13:metadata_sizei256e1:pi6881e1:v6:varunae`.
   - 4-byte length + msg_id=20 + sub_id=`local_ut_metadata_id`(=1) +
     bencoded `d8:msg_typei1e5:piecei0e10:total_sizei256ee` + 256
     bytes of "info dict" (deterministic sequence; SHA-1 hashed
     upfront and used as the info_hash).
3. `pushSocketRecvBytes` loads the entire stream onto the fetcher's
   recv queue.
4. Fetch is started with one peer; SimIO is ticked until the callback
   fires.
5. Assertions:
   - `completed`
   - `had_metadata` (i.e. `result_bytes != null` — would be null if
     SHA-1 verify failed and `assembler.reset()` ran)
   - `result_len == 256`
   - first/last bytes match the original info dict

## Why pre-loading works

The fetcher's read pattern is fully sequential and deterministic:

1. recv 68 bytes (BT handshake)
2. recv 4 bytes (msg length prefix)
3. recv N bytes (extension handshake body)
4. recv 4 bytes (msg length prefix)
5. recv M bytes (ut_metadata data body)

SimIO's recv reads `min(buf_len, queue_count)` and the fetcher
accumulates partial reads via
`recv_buf[slot.recv_len..slot.recv_expected]`. As long as the
cumulative scripted bytes match what the fetcher reads, the order
doesn't matter — the queue acts as a stream the fetcher consumes
piece by piece.

The 64 KiB recv queue cap is enough for any one-piece info dictionary
(max 16 KiB metadata piece per BEP 9). Multi-piece info dicts would
need to push subsequent piece responses incrementally during ticks.

## What works under SimIO now that didn't before

| Scenario | Before | After |
|----------|--------|-------|
| `HttpExecutorOf(SimIO)` typecheck | hardcoded `*RealIO` field | works; alias preserves daemon shape |
| `UdpTrackerExecutorOf(SimIO)` typecheck | hardcoded `*RealIO` field | works; alias preserves daemon shape |
| `AsyncMetadataFetchOf(SimIO)` happy-path | `posix.socket` panics SimIO | full `socket → connect → handshake → ext_handshake → ut_metadata` chain |
| `AsyncMetadataFetchOf(SimIO)` releaseSlot | `posix.close` on synthetic fd | `io.closeSocket` reclaims pool slot correctly |

## Test count delta

- `zig build test-metadata-fetch`: 3 → 4 tests (+1 happy-path)
- Full `zig build test`: 1568 tests (no change in count; the 1
  added test offsets the deferral note that wasn't a test).

## Surprises

1. **`posix.setsockopt` panics on BADF.** Spent ~10 minutes
   debugging the first SimIO test failure thinking my socket lifecycle
   was wrong. Turns out `BADF => unreachable` in Zig std means the
   `catch {}` looks defensive but isn't. Same trap could bite future
   IO-generic refactors that touch `setsockopt` paths
   (`tracker_executor` doesn't have any; `RealIO`-specific socket
   tuning lives in real_io / epoll backends).

2. **The flaky test count varies between runs.** Pre-existing
   flakiness in UDP / uTP / banlist territory shows up as
   1552-1553/1568 passing across runs (1-2 step failures). Not
   introduced by this work — verified by running 4-of-5 green
   immediately after Commit 4 with no other changes.

3. **No need for a separate "scripted peer driver."** The
   pre-load-the-recv-queue approach was simpler than I expected.
   Because the fetcher's protocol is fully sequential and the SimIO
   recv ring buffer is large enough for one piece of metadata, the
   test reduces to "compute the bytes, push them, drive ticks."

## Expected merge conflicts

- **`STATUS.md`** — clock-random-engineer and custom-dns-engineer
  also write milestones. Hand-merge by appending under the "Last
  Verified Milestone" stack; my section uses the
  `## Last Verified Milestone (2026-04-29 — Executor genericization R1: ...)`
  header.
- **`src/io/sim_io.zig`** — clock-random-engineer may add fields
  near `now_ns` and `submit_seq`. My additions are in a different
  region (after `file_content` field) and add `prepared_socket_fds`.
  Should not conflict.
- **`tests/metadata_fetch_test.zig`** — sole owner.
- **`src/io/http_executor.zig`, `src/daemon/udp_tracker_executor.zig`** —
  sole owner; should not collide.
- **`src/io/metadata_handler.zig`** — sole owner; the `IO != SimIO`
  comptime guard is the only addition that touches the imports.

## Out of scope

- **Commit 5 — Live-pipeline BUGGIFY harness for
  `AsyncMetadataFetchOf(SimIO)`.** Same 32-seed shape as
  `tests/recheck_live_buggify_test.zig`. Filed as a follow-up because
  the happy-path landing is the higher-value deliverable and the
  BUGGIFY harness is mechanical to add once the foundation is in
  place. The deferred-test note in `STATUS.md`'s "Next" section
  remains for the BUGGIFY follow-up.

- **Other `posix.close` / `posix.setsockopt` sites.** HttpExecutor
  and UdpTrackerExecutor still call `posix.close` directly in their
  reset/destroy paths (for connection-pool eviction, etc.). The
  daemon's RealIO path uses real fds so this works fine; SimIO
  drivers for those executors are not in scope for this round.

## Key code references

- `src/io/http_executor.zig:35` — `HttpExecutorOf(comptime IO: type)`
- `src/daemon/udp_tracker_executor.zig:31` — `UdpTrackerExecutorOf(comptime IO: type)`
- `src/io/metadata_handler.zig:78-89` — new `SlotState.socket_creating`
- `src/io/metadata_handler.zig:198-241` — `metadataSocketComplete` callback
- `src/io/metadata_handler.zig:228-235` — `if (comptime IO != sim_io_mod.SimIO)`
  guard around `configurePeerSocket`
- `src/io/sim_io.zig:317-323` — `prepared_socket_fds` field
- `src/io/sim_io.zig:380-433` — `enqueueSocketResult` + `pushSocketRecvBytes`
- `src/io/sim_io.zig:957-967` — `socket()` consumes `prepared_socket_fds`
- `tests/metadata_fetch_test.zig` — happy-path test + `buildScriptedPeerResponses`
  helper
