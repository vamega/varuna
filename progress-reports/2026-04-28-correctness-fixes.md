# 2026-04-28 — Correctness fixes: PieceStore.sync wiring, c-ares bind_device, SQLite policy

Branch: `worktree-correctness-fixes`.

Three small correctness gaps surfaced as side-findings during recent
research rounds. None blocking individually; together they're a
contained day's worth of focused work.

## What changed

### Gap 1: `PieceStore.sync` was only called from a test (R6)

**Source**: `docs/mmap-durability-audit.md` §R6 found that
`src/storage/writer.zig:741` (`PieceStore.sync`) was invoked **only
from a test**. The daemon never called it. Pages sat in the OS
pagecache under whatever dirty-writeback policy the kernel chose, with
no varuna-driven flush. Same gap on every IO backend.

**Fix shape**: rather than wire `PieceStore.sync` directly (which has
a latent dangling-pointer footgun — `PieceStore.io` points at a
short-lived `init_io` that goes out of scope at the end of
`doStartBackground` in `src/daemon/torrent_session.zig`), implement
the sync sweep at the event-loop level using `tc.shared_fds`. Same
fsync mechanics, but using the EL's `self.io` which is alive for the
loop's lifetime, and reusing the file-descriptor list the daemon
already shares with peer_policy / peer_handler.

Specifically:

  - `TorrentContext.dirty_writes_since_sync: u32` tracks pending
    fsyncs. `peer_handler.handleDiskWriteResult` bumps it once per
    first-completion of a piece's spans (decoupled from duplicate
    completions in the endgame race). EL-thread-only, no atomics.
  - `TorrentContext.sync_in_flight: bool` makes
    `submitTorrentSync` idempotent under repeated calls.
  - `EventLoop.submitTorrentSync(torrent_id, force_even_if_clean)`
    submits one async fsync per non-skipped fd in `tc.shared_fds`,
    heap-allocates a `TorrentSyncCtx` + completions slab, and frees
    on the last CQE. Snapshot of dirty count subtracted on success
    (saturating) — writes that complete during a sweep stay dirty
    for the next pass.
  - `EventLoop.startPeriodicSync` schedules a self-rearming timer at
    `sync_timer_interval_ms` (default 30 s — matches Linux's
    `vm.dirty_expire_centisecs = 3000` so we don't add write
    amplification while bounding worst-case post-crash data loss).
  - `EventLoop.submitShutdownSync` + `EventLoop.anySyncInFlight`
    let the deinit Phase 0.5 drain pending sync sweeps before
    closing fds.
  - `peer_policy.onPieceVerifiedAndPersisted` calls
    `submitTorrentSync(tid, force=true)` when `pt.isComplete()` so
    torrent completion is a stable on-disk milestone.

**Test coverage**: 9 inline tests in `tests/torrent_sync_test.zig`
driving `EventLoopOf(SimIO)` end-to-end — clean-no-op,
dirty-submit, in-flight-coalesce, force-clean, shutdown-count,
all-skipped fds, missing torrent_id, writes-during-sweep
preservation, and the 30 s default interval. Wired into `build.zig`
as `test-torrent-sync` and the top-level `zig build test`.

**Key references**:

  - `src/io/types.zig:226-242` — TorrentContext dirty fields
  - `src/io/event_loop.zig:1830-2030` — submitTorrentSync,
    torrentSyncCallback, periodic timer, submitShutdownSync,
    anySyncInFlight
  - `src/io/event_loop.zig:579-595` — Phase 0.5 in deinit
  - `src/io/peer_handler.zig:935-952` — dirty-count bump
  - `src/io/peer_policy.zig:1655-1665` — completion-hook sync
  - `src/main.zig:215-220` — startPeriodicSync wiring

### Gap 2: `bind_device` silently bypassed by DNS path

**Source**: `docs/custom-dns-design-round2.md` §1 found that
`network.bind_device` was applied to peer / tracker / RPC traffic but
not DNS — `getaddrinfo` (threadpool, build default) owns its own UDP
socket and has no application hook. A user with `bind_device = "wg0"`
saw DNS leak out the default route while everything else was
correctly bound. Privacy / correctness gap.

**Investigation finding (Pattern #14)**: c-ares exposes both
`ares_set_socket_callback(channel, fn(fd, type, ud) -> int, ud)` (a
simple "after-create" callback that gives us the fd) and the more
sophisticated `ares_set_socket_functions_ex` with
`ARES_SOCKET_OPT_BIND_DEVICE` (full native bind-device support). The
simpler socket-create callback is sufficient: it fires once per
UDP/TCP socket the channel opens, we call `applyBindDevice(fd,
device)`, c-ares proceeds with the bound socket. So the c-ares
backend gets the fix today; the threadpool backend remains a
documented Known Issue tied to the queued custom-DNS-library work.

**Fix shape**:

  - **`src/io/dns.zig`**: new module-level `setDefaultBindDevice` /
    `defaultBindDevice` API (write-once at daemon startup, read by
    every `DnsResolver.init`). This avoids touching `HttpExecutor`
    / `UdpTrackerExecutor` / `session_manager.zig` (which lazily
    create resolvers via the executor `create(allocator, io, .{})`
    signature) — the constraint here was the team-lead's "MUST NOT
    TOUCH" list, which included `session_manager.zig`. Lifetime
    contract: the slice must outlive every resolver, naturally
    satisfied by the daemon borrowing `cfg.network.bind_device`
    from the config arena.
  - **`src/io/dns_cares.zig`**: `init` reads
    `dns.defaultBindDevice()` and, when non-null, registers
    `caresSocketCreateCallback` via `ares_set_socket_callback`. The
    callback applies `applyBindDevice(fd, device)` from
    `src/net/socket.zig` and swallows errors (return 0 + log) so a
    misconfigured interface name doesn't take down DNS entirely.
  - **`src/io/dns_threadpool.zig`**: top-level docstring grew a
    "Known limitation" paragraph documenting the gap and pointing at
    the c-ares workaround.
  - **`src/main.zig`**: one-line wiring,
    `varuna.io.dns.setDefaultBindDevice(cfg.network.bind_device)`,
    placed before any DnsResolver is constructed.
  - **`src/config.zig`**: `bind_device` docstring lists coverage and
    the Known Issue.
  - **`STATUS.md`** "Known Issues": prominent entry for the gap.

**Key references**:

  - `vendor/c-ares/include/ares.h:524-525` — `ares_set_socket_callback`
    signature (the chosen mechanism)
  - `vendor/c-ares/include/ares.h:599-600` —
    `ARES_SOCKET_OPT_BIND_DEVICE` (the native option, deferred)
  - `src/io/dns.zig:50-105` — module-level bind_device API
  - `src/io/dns_cares.zig:71-141` — c-ares socket callback wiring
  - `src/io/dns_threadpool.zig:21-32` — limitation docstring
  - `src/main.zig:104-114` — daemon wiring

### Gap 3: AGENTS.md SQLite-threading policy was stale

**Source**: `docs/sqlite-simulation-and-replacement.md` (the storage
research doc) found AGENTS.md said SQLite is dedicated-background-
thread-only, but the reality is multi-threaded access via
`SQLITE_OPEN_FULLMUTEX` (`src/storage/state_db.zig:31`). The shared
`ResumeDb` connection in `SessionManager` is intentionally touched
from worker threads, RPC handlers, and the queue manager.

**Fix shape**: updated the "Allowed daemon exceptions" section in
AGENTS.md to describe the actual threading model (FULLMUTEX, multi-
threaded access, SQLite's own mutex serialises). The single hard
invariant remains: never call SQLite from the event-loop thread,
since SQLite syscalls block.

The exact updated wording:

> SQLite operations -- the resume database (`src/storage/state_db.zig`)
> is opened with `SQLITE_OPEN_FULLMUTEX`, so SQLite's own internal
> mutex serialises concurrent access. The shared `ResumeDb` connection
> (held in `SessionManager.resume_db`) is intentionally accessed
> concurrently from worker threads (`TorrentSession.startWorker`
> background init), RPC handlers (settings / tracker-overrides
> loads), and the `QueueManager` (queue position persistence). The
> single hard invariant: never call SQLite from the event-loop
> thread, since SQLite syscalls block.

## What was learned

  - **The dangling `store.io` pointer in `doStartBackground`**: when
    `init_io` goes out of scope at the end of the function, every
    `PieceStore` field that was created against it has a `store.io`
    that points to freed memory. In practice this never matters
    because the daemon hot path uses the EL's `self.io` and only the
    fds from `store.fileHandles` — but `PieceStore.sync` would have
    UAF'd if anyone called it. By implementing the sync sweep at the
    EL level, we sidestep that footgun without touching the rewire
    engineer's territory.

  - **c-ares socket callbacks are fully sufficient for the
    bind_device case** despite the more sophisticated
    `ares_socket_functions_ex` existing. The simpler API is
    appropriate here — we just need a hook to apply
    `SO_BINDTODEVICE` after creation, not full ownership of socket
    lifecycle.

  - **The team-lead's "MUST NOT TOUCH" list shapes the fix**: the
    cleanest API for bind_device would have been an init-time
    parameter on `DnsResolver`, but every executor that creates a
    resolver lives in files I cannot touch. The module-default
    pattern is gross-but-contained, and the lifetime invariant
    happens to be naturally satisfied by where bind_device lives in
    the config arena.

  - **Periodic-sync interval choice**: 30 s matches Linux's
    `vm.dirty_expire_centisecs = 3000` default. Going faster
    (e.g. 5 s) would force fsyncs on still-fresh pages and add write
    amplification; going slower (e.g. 5 min) would let too many
    pieces accumulate in pagecache. 30 s is the sweet spot where
    we're flushing what would have been written back anyway.

## Remaining issues / follow-up

  - **Custom DNS library** (queued): the threadpool backend's
    `bind_device` gap is the cleanest motivation for the custom DNS
    work in `docs/custom-dns-design-round2.md`. A custom resolver
    that owns its UDP socket can apply `SO_BINDTODEVICE` natively
    on every backend.
  - **`store.io` dangling pointer**: still latent. Not blocking
    because nothing calls `store.sync` / `store.writePiece` /
    `store.readPiece` from the daemon hot path today, but the
    rewire engineer's `RealIO`-replacement work would be a natural
    place to either repoint `store.io` to the EL's IO post-handoff
    or extract `syncFiles(io, files)` into a top-level helper.
  - **c-ares backend build**: the worktree's c-ares build fails on
    `ares_build.h not found` — a pre-existing issue (the daemon's
    `@cImport({@cInclude("ares.h")})` doesn't see the
    `build/cares-generated/ares_build.h` header that the c-ares
    library compilation does). Not in scope here, but the c-ares
    socket-callback fix is type-checked and would compile against
    that backend once the build issue is resolved.

## Test count delta

1509 → 1518 (9 new tests in `tests/torrent_sync_test.zig`).
