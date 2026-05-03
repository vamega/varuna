# SIMIO/REALIO Bypass Audit

Date: 2026-05-03

Scope: static audit of the current worktree for code paths that bypass the
`SimIO` / `RealIO` interface and call POSIX, stdlib filesystem, or thread APIs
directly. I did not run `strace` / `bpftrace`; this is source-level evidence.
The worktree was already dirty before this report, so line numbers refer to the
current checked-out files, not necessarily a committed revision.

## What changed

- Added this report only; no source code was changed.
- Re-scanned direct syscall, stdlib filesystem, and thread creation sites.
- Re-classified the findings against the current IO contract and documented
  exceptions.

## Boundary used for this audit

The intended daemon boundary is the backend contract in `src/io/io_interface.zig`.
Current backend selection is centralized in `src/io/backend.zig`; daemon callers
are expected to reach file, socket, timer, poll, namespace, and fd lifecycle ops
through the selected backend. The contract now covers socket/connect/accept,
recv/send/recvmsg/sendmsg, read/write/fsync/fallocate/truncate, close,
openat/mkdirat/renameat/unlinkat/statx/getdents, bind/listen/setsockopt, poll,
timeout, and cancel (`src/io/backend.zig:36`, `src/io/backend.zig:53`,
`src/io/io_interface.zig:660`).

Accepted exceptions from repository policy and current docs:

- Backend implementations themselves call raw syscalls to implement the contract
  (`src/io/real_io.zig:105`, `src/io/epoll_posix_io.zig`,
  `src/io/epoll_mmap_io.zig`, `src/io/kqueue_posix_io.zig`,
  `src/io/kqueue_mmap_io.zig`).
- SQLite resume state is outside the IO contract, opened with
  `SQLITE_OPEN_FULLMUTEX`, and may be touched by worker/RPC/queue-manager
  threads. The hard rule is still: no SQLite from the event-loop thread
  (`src/storage/state_db.zig:14`, `src/storage/sqlite_backend.zig:9`).
- DNS via the default threadpool backend uses blocking `getaddrinfo`; this is a
  documented limitation because stdlib DNS owns its internal sockets
  (`src/io/dns_threadpool.zig:340`, `STATUS.md:320`).
- CPU-bound hashing threads are accepted, but not disk I/O inside those threads.
- One-time file creation, directory setup, and preallocation setup during
  `PieceStore.init` is accepted (`src/storage/writer.zig:109`,
  `src/daemon/torrent_session.zig:2090`).
- `varuna-ctl`, `varuna-tools`, benchmarks, perf harnesses, and tests may use
  stdlib/POSIX directly.
- Runtime probing via `uname` and systemd notification are accepted startup or
  notification exceptions (`src/runtime/probe.zig:81`,
  `src/daemon/systemd.zig:26`).

## Findings

### Direct daemon/generic bypasses

1. Inbound peer accept rejection paths still use raw fd operations.
   `handleAccepted` calls `getpeername` directly, then closes rejected accepted
   fds with `posix.close` (`src/io/peer_handler.zig:73`,
   `src/io/peer_handler.zig:76`). Later stale-CQE paths in the same file already
   document that synthetic SimIO fds must go through `io.closeSocket`, so these
   early inbound branches are inconsistent with the current contract.

2. HTTP executor is generic over `IO` but still directly closes fds and drains
   the DNS eventfd. Examples: pooled fd close (`src/io/http_executor.zig:335`),
   DNS eventfd creation/close (`src/io/http_executor.zig:351`,
   `src/io/http_executor.zig:424`), eventfd read from the event loop callback
   (`src/io/http_executor.zig:499`), connect submit failure close
   (`src/io/http_executor.zig:813`), and terminal slot close
   (`src/io/http_executor.zig:1333`). These are unsafe for synthetic SimIO fds
   and bypass fault injection.

3. UDP tracker executor mostly routes UDP socket work through `IO`, but the
   threadpool-DNS eventfd remains direct: creation/close and event-loop drain
   (`src/tracker/udp_executor.zig:212`, `src/tracker/udp_executor.zig:278`,
   `src/tracker/udp_executor.zig:343`). Slot socket closes use `io.closeSocket`,
   which is the desired shape.

4. RPC server setup and fd cleanup bypass the interface. API listen socket
   creation is raw `posix.socket`; bind/listen/setsockopt then use blocking
   contract helpers (`src/rpc/server.zig:83`, `src/rpc/server.zig:97`,
   `src/rpc/server.zig:110`). Client and listen fds are closed with raw
   `posix.close` (`src/rpc/server.zig:125`, `src/rpc/server.zig:138`,
   `src/rpc/server.zig:199`, `src/rpc/server.zig:483`).

5. Event loop listener lifecycle still directly creates and closes listener fds.
   uTP UDP and TCP listener socket creation uses `posix.socket`; `SO_BINDTODEVICE`
   is applied through `socket_util.applyBindDevice`, not the IO contract; stop
   paths close directly (`src/io/event_loop.zig:1557`,
   `src/io/event_loop.zig:1588`, `src/io/event_loop.zig:1635`,
   `src/io/event_loop.zig:1656`, `src/io/event_loop.zig:1672`,
   `src/io/event_loop.zig:1700`). `EventLoop.deinit` also raw-closes UDP/signal
   fds (`src/io/event_loop.zig:667`).

6. `src/net/socket.zig` remains a direct-syscall helper module. Some helpers are
   test/startup-only, but production listener and peer setup still call
   `applyBindDevice` / `configurePeerSocket`; those options should either be on
   the IO contract or explicitly limited to real-fd-only paths
   (`src/net/socket.zig:15`, `src/net/socket.zig:28`,
   `src/net/socket.zig:52`).

7. Merkle tree building reads disk from the hasher path using `posix.pread`.
   `RealHasher` is allowed to spawn CPU hashing threads, but the Merkle job path
   performs file I/O inside the hasher (`src/io/hasher.zig:481`). `SimHasher`
   also calls `posix.pread` for Merkle jobs (`src/io/hasher.zig:793`), so that
   path bypasses the SimIO virtual filesystem even in deterministic tests.
   Eventfd wakeup reads/writes are also direct (`src/io/hasher.zig:102`,
   `src/io/hasher.zig:311`, `src/io/hasher.zig:385`); background eventfd writes
   are a documented practical exception, but event-loop-side reads should be
   contract-routed if this pattern remains.

8. Remove-with-delete-files is synchronous stdlib filesystem work in the daemon.
   `SessionManager.removeTorrent` deletes files and recursively removes empty
   directories with `std.fs` (`src/daemon/session_manager.zig:406`,
   `src/daemon/session_manager.zig:526`, `src/daemon/session_manager.zig:549`).
   This is not one of the explicit accepted daemon exceptions.

9. `PieceStore.init` direct `std.fs` creation is accepted by policy, but the
   lazy `ensureFileOpen` path has the same direct `makePath` / `createFile`
   shape after startup (`src/storage/writer.zig:148`,
   `src/storage/writer.zig:156`). That is probably acceptable by intent as
   one-time creation for newly-wanted files, but it should be documented or
   converted to `openat`/`mkdirat` if the exception is meant to stay narrow.

10. Magnet metadata completion initializes `PieceStore` on the event-loop
    thread. The comments explicitly deem this one-time creation acceptable, but
    it still means direct file creation can occur on the EL during metadata
    completion (`src/daemon/torrent_session.zig:2090`,
    `src/daemon/torrent_session.zig:2103`).

11. c-ares DNS backend is a build-option path that directly uses epoll and real
    wall-clock time (`src/io/dns_cares.zig:288`,
    `src/io/dns_cares.zig:342`, `src/io/dns_cares.zig:358`). Current HTTP/UDP
    executors have an IO-backed custom DNS path under `-Ddns=custom`, so c-ares
    should either be retired, integrated through the IO poll contract, or kept as
    an explicitly non-sim deterministic backend.

12. The daemon main loop still sleeps directly when there is no IO
    (`src/main.zig:433`). This is not filesystem/network I/O, but it bypasses
    the timer/clock abstractions and matters for deterministic lifecycle tests.

### Acceptable or out-of-scope direct usage

- `MoveJob` production path is now an event-loop state machine through the IO
  contract for mkdir/open/rename/copy/fsync/close/unlink
  (`src/storage/move_job.zig:6`, `src/storage/move_job.zig:588`,
  `src/storage/move_job.zig:752`). `SessionManager` starts it with
  `startOnEventLoop` and ticks it with `tickOnEventLoop`
  (`src/daemon/session_manager.zig:1069`,
  `src/daemon/session_manager.zig:1172`). The legacy `start()` worker-thread
  mover remains source-side/test support and still uses std.fs/POSIX directly
  (`src/storage/move_job.zig:14`, `src/storage/move_job.zig:1095`,
  `src/storage/move_job.zig:1145`).
- `src/net/peer_wire.zig` blocking send/recv helpers are still direct POSIX
  (`src/net/peer_wire.zig:5`), but current usage appears to be tests and
  serialization helpers; production peer IO uses the event-loop protocol
  modules.
- `src/crypto/mse.zig` still contains blocking POSIX handshake helpers for
  tests (`src/crypto/mse.zig:210`, `src/crypto/mse.zig:239`), while production
  peer handling uses async MSE state machines through `peer_handler`
  (`src/io/peer_handler.zig:299`, `src/io/peer_handler.zig:1098`).
- `src/app.zig` is reached by `varuna-tools`, so its direct stdlib file access
  is tool-side and acceptable (`src/tools/main.zig:16`, `src/app.zig:49`).
- `src/torrent/create.zig` uses stdlib filesystem and hashing threads for
  torrent creation, which is `varuna-tools` work, not daemon hot-path I/O
  (`src/torrent/create.zig:471`).
- `src/perf`, `src/bench`, and `tests/` intentionally use direct POSIX/stdlib
  for harness setup, fake peers/servers, and measurement.
- `src/runtime/probe.zig:81` (`uname`) and `src/daemon/systemd.zig:26`
  (`sd_notify`) match documented exceptions.

## Thread creation inventory

Daemon production or daemon-adjacent:

- `TorrentSession.startLocked` spawns `startWorker` per session
  (`src/daemon/torrent_session.zig:423`). That worker parses torrent metadata,
  constructs `PieceStore` using a one-shot selected backend for preallocation,
  loads SQLite resume state, and exits (`src/daemon/torrent_session.zig:1312`).
  Comments explicitly say it no longer performs recheck or blocking tracker I/O.
- `RealHasher.create` spawns hasher workers unless configured with zero threads
  (`src/io/hasher.zig:96`, `src/io/hasher.zig:126`). CPU hashing is acceptable;
  Merkle disk reads inside this path are not.
- `dns_threadpool` creates a fixed worker pool for `getaddrinfo`
  (`src/io/dns_threadpool.zig:253`). This is the default DNS backend and an
  accepted limitation, with a known `bind_device` leak.
- `posix_file_pool` spawns workers for the `epoll_posix` / `kqueue_posix`
  alternate IO backends (`src/io/posix_file_pool.zig:191`). This is backend
  infrastructure, not the primary io_uring deployment target.

Non-production, legacy, or tool/test paths:

- Legacy `MoveJob.start()` worker path (`src/storage/move_job.zig:1145`), while
  current daemon moves use `startOnEventLoop`.
- Torrent creation hash workers in `varuna-tools` (`src/torrent/create.zig:471`).
- MSE responder threads inside crypto tests (`src/crypto/mse.zig:1790`,
  `src/crypto/mse.zig:1837`).
- Perf harness server/client workers (`src/perf/workloads.zig:308`,
  `src/perf/workloads.zig:877`, `src/perf/workloads.zig:1135`).
- Test-only peer/server threads under `tests/`.

Direct sleeps worth tracking:

- Main loop idle sleep (`src/main.zig:433`).
- Shutdown/pause wait for announce/scrape flags (`src/daemon/torrent_session.zig:2515`).
- Backend/perf/test polling sleeps in `src/io/posix_file_pool.zig`,
  `src/io/epoll_posix_io.zig`, `src/io/epoll_mmap_io.zig`, `src/perf`, and
  `tests/`.

## Suggested follow-up order

1. Convert generic fd cleanup (`http_executor`, `rpc/server`, inbound accept
   rejection paths, listener stop paths) to `io.closeSocket` or contract
   `close`, and add tests under `EventLoopOf(SimIO)` / executor SimIO paths.
2. Add a contract shape for peer address retrieval, or change accept completions
   to carry the accepted address so `getpeername` disappears from
   `peer_handler`.
3. Route listener/API socket creation through `io.socket`; move bind-device and
   peer socket options behind `io.setsockopt`.
4. Split Merkle jobs into IO-contract reads plus CPU-only hashing, and remove
   `posix.pread` from both `RealHasher` and `SimHasher`.
5. Replace remove-with-delete-files with an event-loop delete job using
   `getdents`/`unlinkat`/`openat`/`close`.
6. Replace threadpool eventfd drains with `io.read` or a small wakeup abstraction
   that has RealIO and SimIO implementations.
7. Decide c-ares' future: remove it in favor of custom DNS, or wire c-ares fd
   readiness through the IO poll contract.
8. Document the lazy `ensureFileOpen` and magnet `PieceStore.init` exceptions if
   they are intentionally accepted, otherwise move them to directory/file
   contract ops.
9. Add a focused static audit build step for daemon modules, with allowlists for
   backend implementations, tests/tools/perf, SQLite, DNS threadpool,
   `runtime/probe`, and `systemd`.

## What was learned

Many older direct-I/O findings have been closed in the current worktree:
storage read/write/fsync/preallocate paths route through the IO contract, async
metadata fetch socket creation is IO-backed, HTTP/UDP tracker socket operations
are mostly IO-backed, and production data relocation has moved to the
event-loop MoveJob state machine. The remaining risks are now narrower: raw fd
lifecycle in generic code, a few startup/listener syscalls, eventfd drains,
delete-data cleanup, and Merkle disk reads inside hashing paths.
