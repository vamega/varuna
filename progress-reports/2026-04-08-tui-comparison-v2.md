# TUI Comparison v2: libxev vs zio (Improved Implementations)

## Date: 2026-04-08

Both branches have been significantly reworked since the initial comparison
(`progress-reports/2026-04-06-tui-comparison.md`). This is a thorough
architectural comparison of the improved implementations.

---

## 1. Code Metrics

| File                     | libxev (LOC) | zio (LOC) |
|--------------------------|-------------|-----------|
| `src/tui/main.zig`       | 720         | 1100      |
| `src/tui/api.zig`        | 859         | 555       |
| `src/tui/views.zig`      | 668         | 735       |
| **Total Zig**            | **2247**    | **2390**  |
| `tests/tui_test.sh`      | 302         | 281       |
| `tests/tui_mock_server.py` | 280       | 215       |
| **Total (all files)**    | **2829**    | **2886**  |

The implementations are remarkably close in total size. The interesting
difference is *where* the code lives: libxev has a larger `api.zig` (typed
enums, `std.json.parseFromSlice` with concrete structs, per-type free
functions) while zio has a larger `main.zig` (thread-safe queues, action
dispatch, shared state).

---

## 2. Architecture Overview

### libxev Architecture

```
┌──────────────────────────────────────────────┐
│                 Main Thread                    │
│                                                │
│   zigzag start() + tick()                     │
│       │                                        │
│       ├── everyMs(100) → tick handler          │
│       │       │                                │
│       │       ├── pollDaemonAsync()            │
│       │       │   (SYNCHRONOUS HTTP via        │
│       │       │    std.http.Client)            │
│       │       │                                │
│       │       └── applyPollResult()            │
│       │                                        │
│       └── libxev loop.run(.no_wait)            │
│           (no-op: nothing uses libxev)         │
│                                                │
│   [Single thread, single event loop]           │
└──────────────────────────────────────────────┘
```

### zio Architecture

```
┌─────────────────────────┐     ┌─────────────────────────┐
│      Main Thread         │     │    zio Worker Thread     │
│                          │     │    (Executor 1)          │
│  zigzag start() + tick() │     │                          │
│      │                   │     │  zioPollerTask():        │
│      ├── everyMs(200)    │     │    loop:                 │
│      │   drainResults()◄─┼──── │      drain ActionQueue   │
│      │                   │     │      processAction()     │
│      ├── key handling    │     │      (dusty HTTP)        │
│      │   enqueueAction()─┼────►│                          │
│      │                   │     │      poll torrents       │
│      └── view rendering  │     │      (dusty HTTP)        │
│                          │     │      push ResultQueue    │
│                          │     │      zio.sleep(2s)       │
│                          │     │                          │
│  SharedState:            │     │  ApiClient (dusty):      │
│    ResultQueue (mutex)   │     │    fiber-based HTTP      │
│    ActionQueue (mutex)   │     │    async networking      │
│    running (atomic bool) │     │                          │
└─────────────────────────┘     └─────────────────────────┘
```

**Key structural difference**: libxev runs everything on one thread with
synchronous HTTP. zio runs a dedicated background fiber for all HTTP I/O,
communicating via mutex-protected queues.

---

## 3. Main Loop Comparison

### libxev main loop

```zig
pub fn main() !void {
    // ...setup...
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    var program = try zz.Program(Model).init(allocator);
    defer program.deinit();
    try program.start();

    while (program.isRunning()) {
        loop.run(.no_wait) catch {};    // Process libxev events (currently no-op)
        try program.tick();              // Process one zigzag frame
    }
}
```

### zio main loop

```zig
pub fn main() !void {
    // ...setup...
    const rt = try zio.Runtime.init(std.heap.smp_allocator, .{
        .executors = .exact(2),
    });
    rt.next_executor_index.store(1, .monotonic);

    var poller_handle = try rt.spawn(zioPollerTask, .{&shared});

    var program = try zz.Program(Model).init(allocator);
    defer program.deinit();
    // ...set model fields...

    try program.start();
    while (program.isRunning()) {
        try program.tick();
    }

    shared.running.store(false, .release);
    program.model.data_arena.deinit();
    poller_handle.cancel();
    rt.deinit();
}
```

**Analysis**: The libxev main loop is simpler (4 meaningful lines inside the
loop vs the zio setup/teardown). However, the `loop.run(.no_wait)` call is
a no-op -- nothing is registered on the libxev event loop. The libxev import
is unused beyond this call. The zio main loop is slightly more complex but
the complexity buys a truly non-blocking architecture.

---

## 4. Event Loop Integration

### libxev: start()/tick() with no real integration

The libxev branch imports libxev and calls `loop.run(.no_wait)` each frame,
but nothing is registered on the loop. No libxev timers, no async wakeups,
no thread pool submissions. The HTTP polling happens synchronously inside
`pollDaemonAsync()`, which is called from zigzag's `update()` handler on
every tick. The comment in the code acknowledges this:

```
// Synchronous poll for now (runs in zigzag tick which has a short
// deadline). The std.http.Client calls are typically fast for
// localhost connections (<1ms). For remote daemons, a dedicated
// thread could be added later.
```

**Verdict**: libxev is declared but not used. The architecture is effectively
"zigzag + std.http.Client in a synchronous loop."

### zio: genuine async integration

The zio branch runs a real background fiber (`zioPollerTask`) on a zio worker
executor. This fiber:
1. Drains the `ActionQueue` for user-initiated commands
2. Executes HTTP requests via dusty (which uses zio's async networking)
3. Pushes results to the `ResultQueue`
4. Sleeps 2 seconds via `zio.sleep()` (non-blocking cooperative yield)

The main thread's tick handler calls `drainResults()` to consume API data.
User actions (pause, add, delete) go through `enqueueAction()` into the
`ActionQueue`.

**Verdict**: zio is genuinely integrated. The UI thread never blocks on HTTP.

---

## 5. HTTP Client Approach

### libxev: std.http.Client (synchronous, blocking)

```zig
fn pollDaemonAsync(self: *Model) void {
    // Synchronous HTTP calls using std.http.Client
    if (self.api_client.fetchTorrents(g_allocator)) |torrents| {
        result.torrents = torrents;
        result.connected = true;
    } else |err| { ... }

    // More synchronous fetches...
    self.pending_result = result;
}
```

The `ApiClient` in the libxev branch uses `std.http.Client` with `fetch()`.
Each poll cycle makes up to 6 sequential HTTP requests (torrents, transfer,
properties, trackers, files, preferences). All blocking. The result is
stored in `self.pending_result` and applied in the next tick.

Despite the name `pollDaemonAsync`, there is nothing asynchronous about it.
The `pending_result` / `poll_in_flight` pattern simulates async but the
calls block the main thread.

**Error handling**: Each fetch is wrapped in an `if/else` with specific
error matching (`ApiError.AuthRequired`, `ApiError.ConnectionRefused`).

### zio: dusty HTTP client (truly async, fiber-based)

```zig
fn zioPollerTask(shared: *SharedState) void {
    var client = api_mod.ApiClient.init(...) catch { ... };
    while (shared.running.load(.acquire)) {
        while (shared.actions.pop()) |cmd| {
            processAction(&client, shared, cmd, &arena_impl);
        }
        _ = arena_impl.reset(.retain_capacity);
        const arena = arena_impl.allocator();
        const torrents = client.getTorrents(arena) catch |err| { ... };
        const transfer = client.getTransferInfo(arena) catch ...;
        shared.results.push(.{ .torrents = torrents, .transfer = transfer, .connected = true });
        zio.sleep(zio.Duration.fromSeconds(2)) catch return;
    }
}
```

Dusty runs on zio's event loop, so `client.getTorrents()` suspends the
fiber rather than blocking a thread. The code reads like synchronous code
(no callbacks) but is cooperative under the hood.

**Error handling**: Similar pattern with catch blocks, but errors propagate
cleanly through the `ApiResult` struct.

**Which is simpler to reason about?**: The dusty code reads identically to
synchronous code but doesn't block. The libxev code IS synchronous code
pretending to be async. For understanding what happens: libxev is marginally
simpler (no queue indirection). For understanding correctness: zio is better
because you know the UI can't freeze.

---

## 6. Thread Safety

### libxev: No threads, no safety concerns

Single-threaded. All state lives in `Model`. No mutexes, no atomics.
`pending_result` and `poll_in_flight` are simple fields read and written
from the same thread.

**Potential race conditions**: None (single-threaded).

**Risk**: The main thread blocks during HTTP requests. If the daemon is slow
or on a remote host, the UI freezes completely.

### zio: Two threads, mutex-protected queues

- **Main thread**: zigzag TUI loop
- **Worker thread**: zio executor 1 running the poller fiber

Shared state:
- `ResultQueue`: bounded ring buffer, `std.Thread.Mutex`, capacity 16
- `ActionQueue`: bounded ring buffer, `std.Thread.Mutex`, capacity 16
- `running`: `std.atomic.Value(bool)` for shutdown signaling

**Potential race conditions**:
1. **Arena reset race**: When `applyApiResult()` receives new torrents, it
   resets `data_arena` and deep-copies the data. However, the torrent data
   in the `ApiResult` was allocated on the poller's arena, which gets reset
   on the next poll cycle. If the poller resets its arena before the main
   thread finishes copying, the source data is invalidated. This is mitigated
   by the 2-second sleep between polls, but is not formally safe.
2. **Detail data not deep-copied**: The code has comments acknowledging that
   `detail_files` and `detail_trackers` from results are "transient, pointer
   only valid for this result" -- but the model still stores `detail_props`
   directly from the result without deep-copying. This data points into the
   poller's arena.

These are real bugs that would manifest under high load or slow networks.

---

## 7. Memory Management

### libxev: Manual free per type

Each data type has a dedicated free function:
- `freeTorrents()`, `freeTrackers()`, `freeFiles()`, `freeProperties()`
- Each function frees individual string fields then the slice

Old data is freed before new data is assigned. The pattern is correct but
requires discipline: every new string field added to a type needs a
corresponding free line.

**Potential leaks**: The `last_error` field points to string literals so no
leak there. `prefs.save_path` is freed on prefs reload. Looks correct.

### zio: Arena allocator for API data

Uses `std.heap.ArenaAllocator` (`data_arena`) for all API response data.
On each torrent list update, the arena is reset and data is deep-copied:

```zig
_ = self.data_arena.reset(.retain_capacity);
const arena = self.data_arena.allocator();
var list = arena.alloc(api_mod.TorrentInfo, t.len) catch { ... };
for (t, 0..) |src, i| {
    list[i] = src;
    list[i].hash = arena.dupe(u8, src.hash) catch "";
    list[i].name = arena.dupe(u8, src.name) catch "";
    // ... more dupes ...
}
```

This is a cleaner pattern: no per-type free functions needed, no risk of
forgetting to free a field. However, the deep-copy only happens for
torrents -- detail properties, trackers, and files are NOT deep-copied
(see thread safety section above).

The poller also uses its own arena (`arena_impl`) which it resets each cycle.

**Potential leaks**: None from the arena pattern itself, but the arena is
only reset when new torrent data arrives. If the daemon is unreachable for
a long time, the arena holds stale data without growing.

---

## 8. Architectural Simplicity

### Struct/type count

| Construct          | libxev | zio   |
|-------------------|--------|-------|
| Top-level structs  | 2 (Model, PollResult) | 6 (Model, ApiResult, ResultQueue, ActionQueue, ActionCmd, SharedState) |
| Enums              | 3 (ViewMode, DetailTab, TorrentState) | 4 (ViewMode, DetailTab, ActionKind, AuthField) |
| File-scoped globals | 2 (g_base_url, g_allocator) | 0 |
| State fields in Model | 29 | 33 |

### Indirection layers

**libxev**: Model.update() -> pollDaemonAsync() -> api_client.fetchX() -> applyPollResult(). Two levels.

**zio**: Model.update() -> enqueueAction() -> ActionQueue -> zioPollerTask() -> processAction() -> api_client.X() -> ResultQueue -> drainResults() -> applyApiResult(). Five levels.

### Control flow readability

**libxev `main.zig`**: Read top-to-bottom, the control flow is immediately
clear. `update()` handles ticks by polling and applying. Key handlers mutate
state directly. No indirection for actions (pause calls `api_client.pauseTorrent`
directly from the key handler).

**zio `main.zig`**: Must understand the queue protocol to follow control flow.
User presses 'p' -> `doPauseResume()` -> builds `ActionCmd` -> copies hash
into fixed-size buffer -> `enqueueAction()` -> eventually processed by
`processAction()` on the worker thread. Six steps where libxev has two.

---

## 9. Feature Parity

| Feature                   | libxev | zio  |
|--------------------------|--------|------|
| Torrent list display      | Yes    | Yes  |
| Status bar                | Yes    | Yes  |
| Navigation (j/k/arrows)  | Yes    | Yes  |
| Home/End keys             | Yes    | Yes  |
| Detail view               | Yes    | Yes  |
| Detail tabs (3)           | Yes    | Yes  |
| Add torrent dialog        | Yes    | Yes  |
| Magnet link support       | Yes    | Yes  |
| File path support         | Yes*   | Yes  |
| Delete confirmation       | Yes    | Yes  |
| Delete files toggle       | Yes    | Yes  |
| Pause/Resume              | Yes    | Yes  |
| Preferences view          | Yes    | Yes  |
| Preferences editing       | No     | Yes  |
| Filter / search           | No     | Yes  |
| Login dialog              | Yes    | Yes  |
| Disconnected overlay      | Yes    | Yes  |
| Auto-reconnect            | Yes    | Yes  |
| SID cookie extraction     | No**   | Yes  |
| Colored progress bars     | Yes    | Yes  |
| File/magnet toggle (Tab)  | No     | Yes  |
| Non-blocking UI           | No***  | Yes  |

\* libxev's add dialog accepts a path string but the `addTorrent` API method
sends it as a URL-encoded body, not as a multipart file upload.

\*\* libxev's `login()` checks the response body for "Ok." but cannot extract
the `SID` cookie from response headers because `std.http.Client.FetchResult`
only exposes `status`. The zio version uses dusty's `response.headers()` to
extract `Set-Cookie`.

\*\*\* libxev blocks the main thread during HTTP requests. For localhost
connections this is sub-millisecond, but for remote daemons or slow networks
the UI will freeze.

**zio has 3 more features**: preference editing, name filtering, and
file/magnet toggle in the add dialog.

---

## 10. Extensibility

### Adding a new API endpoint

**libxev**: Add a fetch method to `ApiClient` (std.http.Client call, ~15
lines), add a field to `PollResult`, add a free function, call it from
`pollDaemonAsync()`, handle it in `applyPollResult()`. ~5 touch points.

**zio**: Add a method to `ApiClient` (dusty call, ~10 lines), add a field to
`ApiResult`, optionally add an `ActionKind` variant, handle in
`processAction()`, handle in `applyApiResult()`. ~5 touch points.

Roughly equivalent.

### Adding a new view/dialog

Both implementations require the same work: add a `ViewMode` variant, add a
key handler function, add a render function in `views.zig`, add the case to
the `view()` function. Equivalent.

### Adding a new action (e.g., set download limit)

**libxev**: Call `api_client.setX()` directly from the key handler. 1 touch
point for the call + the API method itself.

**zio**: Build an `ActionCmd`, copy data into fixed-size buffers, push to
queue, add a case in `processAction()`, handle the response. 4 touch points.
More boilerplate per action.

**libxev wins on action boilerplate** -- but only because it takes the
shortcut of blocking the UI thread.

---

## 11. Dependencies

### libxev

```
.dependencies = .{
    .toml      -- zig-toml (config parsing, shared with daemon)
    .zigzag    -- TUI framework
    .libxev    -- Event loop library
}
```

3 dependencies. libxev is a well-maintained, single-purpose library by
Mitchell Hashimoto. No transitive deps beyond Zig stdlib.

### zio

```
.dependencies = .{
    .toml      -- zig-toml (config parsing, shared with daemon)
    .zigzag    -- TUI framework
    .zio       -- Async runtime (coroutines, executors, networking)
    .dusty     -- HTTP client built on zio
}
```

4 dependencies. zio is a full async runtime; dusty is an HTTP client that
depends on zio. This is a deeper dependency tree. Both are pinned to specific
commits/tags (`zio v0.9.0`, `dusty main@2a90274`).

**Build complexity**: zio brings a coroutine runtime, executor pool, and I/O
subsystem. More code to compile, more potential for build issues. libxev is
lighter.

**However**: libxev is imported but not actually used for anything meaningful.
If the dependency is not providing value, it could be removed entirely and
the implementation would be identical.

---

## 12. Test Approach

### libxev tests

- 13 test cases in `tui_test.sh` (302 lines)
- Mock server: 280 lines, tracks state changes (pause, delete, add)
- Tests: torrent list, navigation, detail view, tab switch, add dialog with
  actual submission and verification of newly-added torrent, delete dialog
  with file toggle, pause state change, preferences view, quit
- Uses `wait_for` with timeout for async assertions
- `--keep` flag for debugging failed tests

### zio tests

- 25 assertions across 8 test groups in `tui_test.sh` (281 lines)
- Mock server: 215 lines, also tracks state changes
- Tests: torrent list, navigation, detail view with tabs, add dialog (cancel
  only -- no submission test), delete dialog with file toggle, preferences
  view, filter mode, quit
- Uses `assert_screen_contains` / `assert_screen_not_contains` helpers

### Comparison

The libxev test suite tests more *behavior* (actually submits a torrent and
verifies it appears). The zio test suite has more *assertions* but tests less
end-to-end behavior (cancels the add dialog instead of submitting). The
libxev mock server is more thorough (tracks added torrents and returns them
in subsequent list queries).

---

## 13. Code Quality

### Error handling

**libxev**: Action methods (pause, resume, add, remove) use `catch {}` to
silently swallow errors. For example:
```zig
self.api_client.resumeTorrent(g_allocator, hash) catch {};
```
This is reasonable for fire-and-forget actions, but provides no user feedback
on failure.

**zio**: Action results can carry error messages back through the queue:
```zig
shared.results.push(.{ .action_ok = false, .action_error = "Failed to add magnet" });
```
The model then displays these via `self.last_error`. Better UX.

### Separation of concerns

**libxev**: `Model` does everything -- state management, key handling, API
polling, result application, view composition. The `api.zig` handles HTTP
transport and JSON parsing. `views.zig` handles rendering. Clean three-way
split, but `Model` is a god object.

**zio**: Same three-way split, but with additional separation: the polling
logic lives in `zioPollerTask()` and `processAction()` outside the Model.
The action/result queues create a clean boundary between UI and I/O. However,
the `ActionCmd` struct with its fixed-size buffers and `@memcpy` calls is
boilerplate-heavy glue code.

### Anti-patterns

**libxev**:
- File-scoped mutable globals (`g_base_url`, `g_allocator`) -- works but
  prevents testing Model in isolation.
- `pollDaemonAsync()` name is misleading -- it's synchronous.
- `poll_in_flight` flag is checked but the "poll" always completes instantly
  in the same tick, making the flag meaningless.

**zio**:
- `detail_files` and `detail_trackers` from API results are acknowledged as
  invalid pointers but stored anyway (the `if (result.detail_files) |_| {}`
  blocks are empty -- the data is simply dropped).
- `processAction` resets the shared arena when fetching detail data, which
  could invalidate previously pushed but not-yet-consumed result data.
- The `login` action packs username and password into a single buffer
  separated by a null byte -- fragile encoding.

---

## 14. TorrentState Handling

A notable design difference:

**libxev**: `TorrentState` is a proper Zig enum with a `fromString()` method
using `StaticStringMap` and methods like `symbol()` and `displayString()`.
State comparison is type-safe (`switch (t.state)`).

**zio**: State is stored as `[]const u8` (raw string from JSON). Status
checks use `std.mem.eql(u8, t.state, "pausedDL")` throughout the codebase.
This is fragile -- a typo in any state string is a silent bug.

**libxev wins clearly here** -- type-safe enums catch errors at compile time.

---

## 15. Pros and Cons Summary

### libxev

| Pros | Cons |
|------|------|
| Simpler architecture (single-threaded) | UI blocks during HTTP requests |
| Fewer moving parts (no queues, no mutexes) | libxev imported but unused |
| Type-safe TorrentState enum | No preference editing |
| Easier to follow control flow | No filter feature |
| Less boilerplate per action | Cannot extract SID cookies |
| Smaller dependency footprint | Silent error swallowing |
| Slightly more thorough test suite | File globals prevent testability |
| Correct memory management | Misleading "async" naming |

### zio

| Pros | Cons |
|------|------|
| Truly non-blocking UI | More complex architecture |
| Action error feedback to user | 5-step indirection for actions |
| Arena-based memory (cleaner) | Thread safety bugs in detail data |
| More features (filter, pref edit) | Deeper dependency tree |
| SID cookie extraction works | ActionCmd buffer-copy boilerplate |
| Clean I/O thread separation | State stored as raw strings (fragile) |
| Cooperative fiber sleeping | Arena reset race condition |

---

## 16. Recommendation

**Recommendation: Merge the libxev branch, then adopt specific patterns from zio.**

### Rationale

1. **Architectural honesty**: The libxev branch is simpler and its
   limitations are honest -- it's synchronous and it knows it. The zio
   branch has genuine async capabilities but also has thread safety bugs
   (detail data lifetime, arena reset races) that would need fixing before
   production use.

2. **libxev's limitation is solvable**: The blocking HTTP is only a problem
   for remote daemons. For localhost (the primary use case), sub-millisecond
   latency makes it invisible. When remote support is needed, the existing
   libxev loop can be genuinely used: submit HTTP work to a `libxev.ThreadPool`,
   receive completions via `libxev.Async` wakeup. The infrastructure is
   already imported.

3. **Type safety**: libxev's `TorrentState` enum is strictly better than
   zio's string-based state handling. This alone prevents a class of bugs.

4. **Correctness**: libxev's memory management is correct (manual but
   complete). zio's arena approach is cleaner in principle but has the
   detail-data lifetime bug and the cross-thread arena race.

5. **Dependency cost**: libxev adds one small dependency. zio adds two
   (zio + dusty), with zio being a full async runtime. For a TUI that
   makes a few HTTP requests per second, the runtime overhead is unjustified
   unless remote daemon support is a priority.

### What to adopt from zio

- **Filter feature**: Port the `containsIgnoreCase` filter and `/` key
  binding. Small, self-contained feature.
- **Preference editing**: Port the navigable preference list with inline
  editing and `setPreferences` API call.
- **Action error feedback**: Add `last_error` display and propagate action
  failures to the user instead of swallowing with `catch {}`.
- **Arena for API data**: Replace per-type free functions with an arena
  allocator that resets on each poll cycle. Less code, fewer leak risks.
- **File/magnet toggle**: Minor UX improvement for the add dialog.

### What NOT to adopt from zio

- The thread-safe queue architecture (unnecessary complexity for localhost)
- Storing torrent state as raw strings (use the typed enum)
- The `ActionCmd` buffer-copy pattern (direct calls are simpler)
- dusty as HTTP client (std.http.Client is sufficient for the TUI's needs)
