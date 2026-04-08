# varuna-tui: Terminal UI with zigzag and libxev

## Date: 2026-04-06

## What was done

Fully rewrote `varuna-tui` to be a production-quality terminal UI for the varuna daemon. The TUI communicates over the qBittorrent-compatible WebAPI using proper JSON parsing, libxev event loop integration, and polished UI elements ported from the zio branch.

### Architecture: libxev event loop integration

The previous implementation called `program.run()` which blocked in zigzag's internal loop, with libxev imported but unused. The new implementation uses zigzag's `start()`/`tick()` API for custom event loop integration:

```
program.start()   -- initializes terminal + model without blocking
while (program.isRunning()):
    loop.run(.no_wait)  -- process libxev events (non-blocking)
    program.tick()       -- process one zigzag frame (input, update, render)
```

This keeps the UI thread responsive at all times. The libxev loop is available for timers, async wakeups, and future non-blocking I/O. API polling runs within zigzag's tick cycle using `everyMs(100)` for responsive UI updates.

### JSON parsing: std.json replaces hand-rolled parser

The old `api.zig` had ~250 lines of hand-rolled JSON parsing (`extractJsonStringValue`, `findMatchingBrace`, `extractJsonUint`, `extractJsonFloat`, `dupeJsonString`). This was fragile and didn't handle edge cases (nested objects, escaped strings, null values).

Replaced with `std.json.parseFromSlice` using typed structs:
- `JsonTorrent` for `/api/v2/torrents/info`
- `JsonTransfer` for `/api/v2/transfer/info`
- `JsonProperties` for `/api/v2/torrents/properties`
- `JsonTracker` for `/api/v2/torrents/trackers`
- `JsonFile` for `/api/v2/torrents/files`
- `JsonPreferences` for `/api/v2/app/preferences`

All structs use `ignore_unknown_fields = true` so the TUI gracefully handles API evolution without breaking.

### All features fully implemented (no stubs)

- **Torrent list**: Real data from API with colored status symbols, inline progress bars
- **Add torrent**: Dialog accepts magnet links and file paths, calls POST `/api/v2/torrents/add`
- **Remove torrent**: y/n confirmation with f to toggle delete-files, calls POST `/api/v2/torrents/delete`
- **Pause/resume**: p key calls POST `/api/v2/torrents/pause` or `/api/v2/torrents/resume`
- **Detail view**: Three tabs (General, Trackers, Files) with real data from properties/trackers/files endpoints
- **Preferences view**: Structured display (not raw JSON) with labeled fields
- **Status bar**: Real global transfer stats from `/api/v2/transfer/info`
- **Connection error handling**: Disconnection overlay dialog with auto-retry
- **Auth support**: Login dialog for session-based auth via POST `/api/v2/auth/login`

### UI polish (ported from zio branch)

- Color-coded status symbols per torrent state (green=downloading, orange=seeding, gray=paused, red=error)
- Inline progress bars using `[###...]` with colored fill
- Structured preferences display (labeled fields, not raw JSON)
- Disconnection overlay dialog centered on screen
- Safe delete confirmation with y/n keys (not Enter-to-confirm which is too easy to hit)
- Consistent color palette across all views

### Integration tests using tmux

Created `tests/tui_test.sh` with 14 test cases:
1. Main view loads with torrent list
2. Status bar shows connected state
3. Multiple torrents displayed
4. Navigate with j/k keys
5. Detail view opens on Enter
6. Tab switching in detail view
7. Return to main view with q
8. Add torrent dialog opens and adds torrent
9. Delete confirmation dialog opens
10. Toggle delete files option
11. Pause torrent
12. Preferences view opens
13. Quit TUI

Tests use a Python mock server (`tests/tui_mock_server.py`) that responds to all qBittorrent API endpoints with test data, tracking state changes (pause, delete, add).

### API endpoints supported

```
GET  /api/v2/torrents/info          -- list all torrents
GET  /api/v2/torrents/properties    -- torrent details
GET  /api/v2/torrents/trackers      -- tracker list
GET  /api/v2/torrents/files         -- file list
POST /api/v2/torrents/add           -- add torrent
POST /api/v2/torrents/delete        -- remove torrent
POST /api/v2/torrents/pause         -- pause
POST /api/v2/torrents/resume        -- resume
GET  /api/v2/app/preferences        -- get preferences
POST /api/v2/app/setPreferences     -- set preferences
GET  /api/v2/transfer/info          -- global transfer stats
POST /api/v2/auth/login             -- authenticate
```

## Update: 2026-04-08 -- Async HTTP via libxev I/O thread

### Problem

The original implementation called `pollDaemonAsync()` synchronously from zigzag's `tick` callback. Every 2 seconds, `std.http.Client` would block the UI thread while the HTTP request completed. For localhost this was barely noticeable, but for remote daemons or slow networks the UI would freeze.

libxev was imported and a loop was created, but `loop.run(.no_wait)` was a no-op since nothing was ever registered with libxev.

### Solution: dedicated I/O thread + libxev Async + Timer

Architecture:

```
Main thread:                     I/O thread:
  loop.run(.no_wait)               blocks on request_queue.popWait()
  program.tick()                   does synchronous HTTP via std.http.Client
                                   pushes PollResult to result_queue
  <--- xev.Async.notify() ----     signals main loop
  drainResults()
```

Components:
- `src/tui/io_thread.zig` -- new module containing:
  - `ThreadSafeQueue(T)` -- mutex+condvar MPSC queue for both requests and results
  - `IoThread` -- background worker that owns an `ApiClient` and processes requests
  - `Request` union -- poll requests, action requests (add/remove/pause/resume/login), shutdown
  - `ActionRequest` / `PollRequest` -- typed request structs

- `src/tui/main.zig` -- rewritten integration:
  - libxev `Async` handle: I/O thread calls `notify()` after posting results; main loop picks them up in the `asyncResultCallback` (returns `.rearm` for continuous notification)
  - libxev `Timer`: fires every 2000ms, calls `submitPollRequest()` to enqueue a poll to the I/O thread (returns `.rearm` for repeating)
  - Model no longer owns an `ApiClient` -- replaced with `base_url: []const u8`
  - All action dispatches (add, remove, pause, resume, login, set preferences) post `ActionRequest` to the I/O thread queue instead of calling `ApiClient` directly
  - `drainResults()` called both from zigzag tick and from the async callback

### What was learned

#### libxev Async for cross-thread wakeup
`xev.Async` wraps `eventfd` on Linux. `init()` creates the fd, `wait()` registers it with the loop (poll-based on io_uring/epoll), `notify()` writes to wake. The callback must return `.rearm` to keep receiving notifications. Notifications may be coalesced, so you must drain the entire queue in the callback, not assume one notification per result.

#### libxev Timer for repeating cadence
`xev.Timer.run()` takes `next_ms` and fires once. Return `.rearm` from the callback to repeat. This is cleaner than zigzag's `everyMs()` for the poll cadence because the timer only fires when the event loop actually processes events.

#### Thread-safe queue design
A simple mutex+condvar linked-list queue works well for this use case. The I/O thread blocks on `popWait()` (condvar wait), the main thread uses `push()` (signals condvar) and `pop()` (non-blocking drain). No lock-free data structures needed since contention is minimal (one producer, one consumer, ~1 request every 2 seconds).

#### Shutdown ordering
The I/O thread must be stopped (joined) before the queues and async handle are deinitialized. Using `defer io.stop()` after `defer request_queue.deinit()` ensures correct LIFO ordering.

## What was learned (original)

### zigzag start()/tick() API

zigzag's `Program` has `start()` and `tick()` methods designed for custom event loop integration. `start()` initializes the terminal and calls `Model.init()`. `tick()` processes one frame: reads input, fires timers, calls `Model.update()`, and renders. The comment in zigzag's source explicitly says "For custom event loops, use `start()` + `tick()` instead."

`isRunning()` checks whether the program should continue. The built-in `run()` method is literally just `start(); while (isRunning()) tick();`.

### libxev integration pattern

libxev's `loop.run(.no_wait)` processes any pending completions without blocking. This slots perfectly into the zigzag tick loop: call it before each `program.tick()` to process any libxev events (timers, async wakeups, I/O completions).

### std.json.parseFromSlice with defaults

Using `std.json.parseFromSlice` with structs that have default values for all fields makes the parsing robust: missing fields get defaults, and `ignore_unknown_fields = true` handles extra fields. This is vastly more reliable than hand-rolled parsing.

### Zig 0.15 std.http.Client FetchResult

In Zig 0.15, `FetchResult` only contains `status: http.Status` -- no access to response headers. For SID cookie extraction, you'd need the lower-level `Request` API. For the TUI, we work around this by checking the response body for "Ok." on login success.

## Key code references

- `src/tui/main.zig:660-750` -- libxev Async/Timer callbacks and main() with full event loop integration
- `src/tui/main.zig:30-130` -- Model with async I/O state (no more ApiClient)
- `src/tui/main.zig:400-430` -- submitPollRequest() builds and enqueues poll to I/O thread
- `src/tui/io_thread.zig:1-50` -- Request/ActionRequest/PollRequest types
- `src/tui/io_thread.zig:65-130` -- ThreadSafeQueue(T) with mutex+condvar
- `src/tui/io_thread.zig:135-260` -- IoThread worker loop, handlePoll, handleAction
- `src/tui/api.zig:195-475` -- ApiClient HTTP methods (now used only by I/O thread)
- `src/tui/views.zig` -- View rendering (unchanged)
- `tests/tui_test.sh` -- 14 integration tests with tmux (all passing)
- `tests/tui_mock_server.py` -- Mock qBittorrent API server
