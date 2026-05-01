# Remove Blocking I/O Background Threads Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Eliminate background threads that perform blocking network and file I/O in the daemon, moving all I/O onto the io_uring event loop. Only SQLite and CPU-bound hashing remain on background threads.

**Architecture:** The daemon currently spawns a background thread per torrent (`startWorker`) that does blocking disk reads, blocking tracker HTTP/UDP, blocking metadata fetch, and `Thread.sleep`. The tracker executors (`TrackerExecutor`, `UdpTrackerExecutor`) already provide ring-based HTTP and UDP -- we use those instead of the blocking `multi_announce.zig` thread pool. Disk recheck moves to the event loop via io_uring `IORING_OP_READ`. The `startWorker` thread becomes a thin SQLite+hash-only background thread that hands off to the event loop for all I/O.

**Tech Stack:** Zig 0.15.2, Linux io_uring, BoringSSL (TLS), SQLite3

---

## Current State

`TorrentSession.startWorker` runs `doStart()` on a background thread. `doStart()` does these steps sequentially:

1. **Metadata fetch** (magnet links) -- blocking TCP `posix.connect`/`read`/`write` in `net/metadata_fetch.zig`
2. **Session.load** -- parses torrent bytes (CPU, no I/O)
3. **PieceStore.init** -- file creation/truncation (allowed exception)
4. **SQLite reads** -- ~10 queries for resume state, stats, categories, etc. (must stay on background thread)
5. **recheckExistingData** -- blocking `posix.pread` for every piece + SHA hash (I/O + CPU)
6. **Thread.sleep** -- jittered announce delay
7. **announceParallel** -- spawns N threads doing blocking HTTP/UDP tracker I/O

Steps 2-3 are fine. Step 4 must stay on a background thread. Steps 1, 5, 6, 7 are the violations.

## Target State

`doStart()` becomes a multi-phase pipeline:

- **Phase 1 (background thread):** Parse torrent, init PieceStore, run all SQLite queries. No network I/O, no disk reads. Returns immediately.
- **Phase 2 (event loop):** Submit io_uring reads for piece verification. Process CQEs, hash completed reads on the hasher pool. Track progress.
- **Phase 3 (event loop):** When recheck completes, submit tracker announce jobs to the existing `TrackerExecutor`/`UdpTrackerExecutor`. Use a timerfd for jittered delay.
- **Phase 4 (event loop):** When announce responses arrive, add peers to the event loop. Torrent is now fully integrated.

For magnet links, metadata fetch becomes a state machine on the event loop (connect/handshake/request via io_uring SQEs), run before Phase 1.

## File Structure

| File | Change | Responsibility |
|------|--------|----------------|
| `src/daemon/torrent_session.zig` | **Modify** | Split `doStart()` into phases; background thread does only SQLite+parse; new methods for event-loop-driven recheck and announce |
| `src/io/recheck.zig` | **Create** | Async piece verification state machine on the event loop: submits io_uring reads, dispatches to hasher, tracks completion |
| `src/io/event_loop.zig` | **Modify** | Add recheck dispatch in CQE handler; add timerfd support for delayed announce scheduling |
| `src/io/types.zig` | **Modify** | Add OpType variants for recheck reads and timerfd |
| `src/io/metadata_handler.zig` | **Create** | Async BEP 9 metadata fetch state machine on the event loop (connect, handshake, piece request/receive via ring) |
| `src/tracker/multi_announce.zig` | **Delete** | Replaced by TrackerExecutor/UdpTrackerExecutor which are already ring-integrated |
| `src/tracker/announce.zig` | **Modify** | Remove synchronous HTTP fetch helpers. Keep `parseResponse`, `buildUrl`, and types |
| `src/tracker/scrape.zig` | **Modify** | Remove blocking `scrapeHttp*` functions. Scrape already goes through TrackerExecutor |
| `src/net/metadata_fetch.zig` | **Modify** | Extract protocol logic (handshake building, piece assembly, BEP 9 message parsing) into reusable helpers; remove blocking socket I/O |
| `src/storage/verify.zig` | **Modify** | Extract `planPieceVerification` and `verifyPieceBuffer` as the pure/compute parts; remove `recheckExistingData` blocking loop |

---

## Task 1: Add timerfd Support to Event Loop

**Why first:** Timerfd is a prerequisite for delayed announce scheduling and replaces `Thread.sleep`. Small, self-contained, testable in isolation.

**Files:**
- Modify: `src/io/types.zig` -- add `OpType.timerfd` variant
- Modify: `src/io/event_loop.zig` -- add timerfd creation, read submission, CQE dispatch
- Test: inline test block in `src/io/event_loop.zig`

- [ ] **Step 1: Add OpType.timerfd to types.zig**

In `src/io/types.zig`, add `timerfd` to the `OpType` enum:

```zig
pub const OpType = enum(u8) {
    // ... existing variants ...
    timerfd,
};
```

- [ ] **Step 2: Add timerfd field and helpers to EventLoop**

In `src/io/event_loop.zig`, add to the `EventLoop` struct:

```zig
timer_fd: posix.fd_t = -1,
```

In `init` or `create`, create the timerfd:

```zig
self.timer_fd = @intCast(linux.timerfd_create(linux.CLOCK.MONOTONIC, .{ .CLOEXEC = true, .NONBLOCK = true }));
```

Add a method to schedule a one-shot timer:

```zig
pub fn scheduleTimer(self: *EventLoop, delay_ms: u64) !void {
    const secs = delay_ms / 1000;
    const nsecs = (delay_ms % 1000) * 1_000_000;
    const spec = linux.itimerspec{
        .it_interval = .{ .sec = 0, .nsec = 0 },
        .it_value = .{ .sec = @intCast(secs), .nsec = @intCast(nsecs) },
    };
    const rc = linux.timerfd_settime(@intCast(self.timer_fd), 0, &spec, null);
    if (rc != 0) return error.TimerfdSetFailed;

    // Submit a read on the timerfd to get a CQE when it fires
    const user_data = encodeUserData(.timerfd, 0, 0);
    var sqe = try self.ring.get_sqe();
    sqe.prep_read(self.timer_fd, &self.timer_read_buf, 0);
    sqe.user_data = user_data;
}
```

Add `timer_read_buf: [8]u8 = undefined` to EventLoop for the timerfd read buffer.

- [ ] **Step 3: Handle timerfd CQEs in dispatchCqe**

In `dispatchCqe()`, add a case for `.timerfd`:

```zig
.timerfd => {
    self.handleTimerFired();
},
```

Implement `handleTimerFired` to process pending timer callbacks (announce scheduling, recheck delays, etc.). Start with a simple callback list:

```zig
fn handleTimerFired(self: *EventLoop) void {
    // Process pending timer-triggered actions
    // (announce scheduling will be added in Task 5)
    _ = self;
}
```

- [ ] **Step 4: Clean up timerfd in deinit**

Close `self.timer_fd` in EventLoop's deinit/destroy path.

- [ ] **Step 5: Verify build**

Run: `zig build 2>&1 | head -20`
Expected: clean build

- [ ] **Step 6: Commit**

```
io: add timerfd support to event loop for delayed scheduling
```

---

## Task 2: Async Piece Recheck on Event Loop

**Why now:** This is the largest piece of `doStart()` that blocks -- reading every piece from disk and hashing. Moving it to the event loop means io_uring `READ` ops + hasher thread pool for the CPU work.

**Files:**
- Create: `src/io/recheck.zig` -- async recheck state machine
- Modify: `src/io/types.zig` -- add `OpType.recheck_read`
- Modify: `src/io/event_loop.zig` -- integrate recheck dispatch
- Modify: `src/storage/verify.zig` -- expose `planPieceVerification` and `verifyPieceBuffer` as the reusable compute parts (already public, but ensure `recheckExistingData` is not the only entry point)

- [ ] **Step 1: Design the RecheckState machine**

`src/io/recheck.zig` tracks:
- Which torrent is being rechecked
- Current piece index being verified
- How many io_uring reads are in flight (pipeline depth, e.g., 4-8 concurrent reads)
- A scratch buffer pool for piece data
- The resulting `PieceSet` of completed pieces
- A callback for when recheck is done

The flow per piece:
1. Call `planPieceVerification()` to get spans
2. Submit io_uring `IORING_OP_READ` for each span (using PieceStore's file descriptors)
3. On CQE completion, when all spans for a piece are read, submit to hasher pool
4. On hash result, mark piece complete/incomplete, advance to next piece
5. When all pieces done, invoke completion callback

- [ ] **Step 2: Implement RecheckState struct**

```zig
pub const RecheckState = struct {
    allocator: std.mem.Allocator,
    session: *const torrent.session.Session,
    piece_io: storage.writer.PieceIO,
    complete_pieces: storage.verify.PieceSet,
    bytes_complete: u64 = 0,
    current_piece: u32 = 0,
    in_flight: u32 = 0,
    max_in_flight: u32 = 8,
    scratch_bufs: [8][]u8,
    known_complete: ?*const storage.verify.PieceSet,
    done: bool = false,
    on_complete: ?*const fn (*RecheckState) void = null,

    // ... init, submitNextRead, handleReadComplete, handleHashResult ...
};
```

- [ ] **Step 3: Implement submitNextRead**

Skips pieces in `known_complete` (resume fast path). For each piece needing verification:
- Calls `verify.planPieceVerification()`
- Submits io_uring reads via the event loop ring for each span in the plan
- Uses `OpType.recheck_read` with the piece index encoded in user_data

- [ ] **Step 4: Implement handleReadComplete**

Called from event loop's `dispatchCqe` when a `.recheck_read` CQE arrives:
- Tracks partial reads (a piece may span multiple files/spans)
- When all spans for a piece are read, submits the buffer to the hasher pool
- Calls `submitNextRead` to keep the pipeline full

- [ ] **Step 5: Implement handleHashResult**

Called when hasher returns a result:
- Calls `verify.verifyPieceBuffer()` with the hashed data
- Updates `complete_pieces` bitfield
- When `current_piece == piece_count` and `in_flight == 0`, invokes `on_complete`

- [ ] **Step 6: Add OpType.recheck_read to types.zig**

- [ ] **Step 7: Integrate into event_loop.zig**

Add `recheck_state: ?*RecheckState = null` field. In `dispatchCqe`, route `.recheck_read` to `recheck_state.?.handleReadComplete()`. In the tick loop, check if recheck submitted enough reads.

- [ ] **Step 8: Write test**

Create a test that:
1. Creates a small torrent session with known piece data
2. Starts an async recheck on a test event loop
3. Runs the event loop until recheck completes
4. Verifies the correct pieces are marked complete

- [ ] **Step 9: Commit**

```
io: add async piece recheck via io_uring reads + hasher pool
```

---

## Task 3: Split doStart into Background-Thread Phase and Event-Loop Phase

**Why now:** With async recheck available, we can split `doStart()` so the background thread only does SQLite + parse, then hands off to the event loop for recheck + announce.

**Files:**
- Modify: `src/daemon/torrent_session.zig` -- split `doStart()` into `doStartBackground()` and `continueStartOnEventLoop()`
- Modify: `src/daemon/session_manager.zig` -- update integration flow

- [ ] **Step 1: Extract doStartBackground**

New function `doStartBackground()` contains only:
1. `Session.load()` (CPU -- parse torrent)
2. `PieceStore.init()` (one-time file setup -- allowed exception)
3. All SQLite queries (resume pieces, transfer stats, limits, categories, tags, overrides, v2 hash)
4. Sets `self.state = .checking`
5. Does NOT call `recheckExistingData`, does NOT call `announceParallel`, does NOT call `Thread.sleep`

The background thread exits after `doStartBackground()`. It stores parsed state on `self` for the event loop to pick up.

- [ ] **Step 2: Create continueStartOnEventLoop**

New function `continueStartOnEventLoop()`:
1. Creates `RecheckState` from the session/store/resume data prepared by `doStartBackground()`
2. Starts async recheck on the event loop (submits initial reads)
3. Registers a completion callback that transitions to announce phase

- [ ] **Step 3: Update startWorker to call doStartBackground only**

```zig
fn startWorker(self: *TorrentSession) void {
    self.mutex.lock();
    defer self.mutex.unlock();
    self.doStartBackground() catch |err| {
        self.state = .@"error";
        self.error_message = std.fmt.allocPrint(self.allocator, "{s}", .{@errorName(err)}) catch null;
    };
    // Event loop integration happens in the main thread's tick via integrateIntoEventLoop
}
```

- [ ] **Step 4: Update integrateIntoEventLoop to trigger async recheck**

After the background thread completes, the main thread calls `integrateIntoEventLoop()`. This now also calls `continueStartOnEventLoop()` to begin async verification.

- [ ] **Step 5: Implement recheck completion callback**

When recheck finishes:
1. Persist results to resume DB (submit to SQLite background thread or inline if fast enough)
2. If all pieces complete -> set state to `.seeding`, schedule completed announce
3. Else -> set state to `.downloading`, schedule initial announce with timerfd jitter delay

- [ ] **Step 6: Replace Thread.sleep with timerfd**

The jittered announce delay (currently `Thread.sleep` in `doStart`) becomes a `scheduleTimer()` call. When the timer fires, the event loop submits announce jobs to `TrackerExecutor`/`UdpTrackerExecutor`.

- [ ] **Step 7: Remove announceParallel call from doStart**

The initial announce now goes through the same `scheduleAnnounceJobs()` path that re-announces use, which already submits to the ring-based executors.

- [ ] **Step 8: Test the split**

Verify that:
- Background thread exits quickly (no disk reads, no network)
- Recheck runs on event loop (strace shows `io_uring_enter` for reads)
- Announce goes through TrackerExecutor (no `connect`/`sendto` syscalls from main thread)

Run: `strace -f -yy -c -e trace=read,write,pread64,connect,sendto,recvfrom,io_uring_enter zig build run -- seed testdata/test.torrent /tmp/test 2>&1 | tail -20`

- [ ] **Step 9: Commit**

```
daemon: split torrent startup into background-thread and event-loop phases
```

---

## Task 4: Move Metadata Fetch onto Event Loop

**Why now:** Magnet link metadata fetch currently uses blocking TCP sockets. It needs its own state machine on the event loop, similar to how peer connections work.

**Files:**
- Create: `src/io/metadata_handler.zig` -- async BEP 9 metadata fetch state machine
- Modify: `src/net/metadata_fetch.zig` -- extract protocol helpers (handshake building, piece assembly, message parsing) into non-I/O functions; keep `MetadataAssembler`
- Modify: `src/io/event_loop.zig` -- integrate metadata handler
- Modify: `src/io/types.zig` -- add OpType variants for metadata connect/send/recv
- Modify: `src/daemon/torrent_session.zig` -- use async metadata fetch instead of blocking

- [ ] **Step 1: Extract protocol helpers from metadata_fetch.zig**

Keep `MetadataAssembler`, `buildHandshake`, `parseUtMetadataMessage`, `buildUtMetadataRequest` as pure functions. Remove the blocking `fetchFromPeer` and `fetch` methods. The `MetadataFetcher` struct becomes a protocol-state tracker without I/O.

- [ ] **Step 2: Design metadata_handler.zig state machine**

Per-peer states: `connecting` -> `handshake_send` -> `handshake_recv` -> `extension_handshake_send` -> `extension_handshake_recv` -> `piece_request` -> `piece_recv` -> `done`

The handler manages multiple peer connections concurrently (try up to 3 peers at once). On failure, advance to next peer. Uses the event loop ring for all TCP ops.

- [ ] **Step 3: Implement the state machine**

Follow the same pattern as `peer_handler.zig` -- state enum on a slot, CQE dispatch advances state. Encode metadata slot index in user_data.

- [ ] **Step 4: Integrate with event loop**

Add `metadata_handler: ?*MetadataHandler = null` to EventLoop. In `dispatchCqe`, route metadata op types. In `tick`, drive the metadata handler.

- [ ] **Step 5: Update torrent_session.zig**

For magnet torrents, instead of calling blocking `fetchMetadata()` from the background thread, set a flag and let the event loop drive metadata fetch after `integrateIntoEventLoop`. Once metadata arrives, proceed to the recheck phase.

- [ ] **Step 6: Test with a magnet link**

Use a test torrent with known metadata. Verify metadata fetch completes via event loop, then recheck and announce proceed normally.

- [ ] **Step 7: Commit**

```
io: add async BEP 9 metadata fetch state machine on event loop
```

---

## Task 5: Delete Blocking Tracker Code

**Why now:** With all paths using the ring-based executors, the blocking tracker code is dead.

**Files:**
- Delete: `src/tracker/multi_announce.zig`
- Modify: `src/tracker/announce.zig` -- remove synchronous HTTP fetch helpers; keep `parseResponse`, `buildUrl`, types
- Modify: `src/tracker/scrape.zig` -- remove blocking scrape functions
- Modify: `src/tracker/udp.zig` -- remove `fetchViaUdp`, `scrapeViaUdp` blocking functions; keep packet codec types (`AnnounceResponse`, `ScrapeResponse`, `ConnectionCache`, etc.)
- Modify: `src/tracker/root.zig` -- remove `multi_announce` export
- Modify: `build.zig` -- remove any references to multi_announce test targets
- Delete: `tests/udp_tracker_test.zig` -- tests for blocking UDP code (or rewrite against executor)

- [ ] **Step 1: Identify all callers of blocking tracker functions**

Search for:
- `multi_announce.announceParallel` -- should be zero after Task 3
- announce-layer synchronous HTTP fetch helpers -- should be zero after Task 3
- `announce.fetch` -- already removed (dead code cleanup)
- `scrape.scrapeHttp*`, `scrape.scrapeAuto*` -- should be zero
- `udp.fetchViaUdp`, `udp.scrapeViaUdp` -- should be zero

- [ ] **Step 2: Delete multi_announce.zig**

- [ ] **Step 3: Strip blocking functions from announce.zig, scrape.zig, udp.zig**

Keep: `parseResponse`, `buildUrl`, `appendQueryParam`, types, `parseCompactPeers/6` in types.zig, packet codecs in udp.zig.

Remove: all `fetch*` and `scrape*` functions that create sockets.

- [ ] **Step 4: Update root.zig**

Remove `multi_announce` export.

- [ ] **Step 5: Update or delete tests**

`tests/udp_tracker_test.zig` tests the blocking UDP path. Either delete it or rewrite the retransmit/cache tests against the codec functions that remain.

- [ ] **Step 6: Verify build and tests**

Run: `zig build && zig build test`

- [ ] **Step 7: Verify with strace**

Run a daemon seed and verify no `connect`, `sendto`, `recvfrom`, `read`, `write` syscalls outside of io_uring:

```
strace -f -yy -c zig build run -- seed testdata/test.torrent /tmp/test 2>&1 | grep -v io_uring
```

- [ ] **Step 8: Commit**

```
tracker: remove blocking HTTP/UDP tracker code, use ring-based executors only
```

---

## Task 6: Fix resumeTorrent Start-then-Cancel Pattern

**Why now:** With the background thread doing only SQLite+parse (fast), the start-then-cancel race is less severe but still wrong. Fix it properly.

**Files:**
- Modify: `src/daemon/session_manager.zig`

- [ ] **Step 1: Move shouldBeActive check before unpause**

```zig
if (session.state == .queued) {
    if (self.queue_manager.config.enabled) {
        if (self.queue_manager.shouldBeActive(session.info_hash_hex, &self.sessions)) {
            session.state = .paused;
            session.unpause();
        }
        // else: leave it queued, do not start anything
    } else {
        session.state = .paused;
        session.unpause();
    }
}
```

- [ ] **Step 2: Verify no thread is spawned unnecessarily**

- [ ] **Step 3: Commit**

```
daemon: check queue eligibility before starting torrent, not after
```

---

## Execution Order and Dependencies

```
Task 1 (timerfd)
    |
    v
Task 2 (async recheck) ----+
    |                       |
    v                       |
Task 3 (split doStart) <---+
    |
    v
Task 4 (async metadata fetch) -- can be done in parallel with Task 5
    |
    v
Task 5 (delete blocking tracker code)
    |
    v
Task 6 (fix resumeTorrent)
```

Task 6 is independent and can be done at any point.

---

## What This Does NOT Change

- **SQLite** stays on background threads (required by SQLite's threading model and the io_uring policy)
- **Hasher thread pool** stays (CPU-bound SHA hashing)
- **DNS thread pool** stays when c-ares is not available (getaddrinfo is blocking)
- The former synchronous HTTP network client has since been removed; CLI and
  daemon HTTP callers use the async executor path.
- **`PieceStore.init`** file creation stays blocking (one-time setup, allowed exception)
- **TrackerExecutor / UdpTrackerExecutor** stay as-is (already ring-based, this plan feeds them better)

## Verification

After all tasks, run the daemon under strace and confirm:
- The only non-io_uring syscalls are: `write` (stdout logging), SQLite-related file ops on background threads, and `futex` (thread sync)
- All TCP connect/send/recv and UDP sendto/recvfrom go through `io_uring_enter`
- All file reads for piece verification go through `io_uring_enter`
- No `Thread.sleep` calls remain in the daemon
