# TUI Implementation Comparison: libxev vs zio

## Date: 2026-04-06

## Overview

Two independent implementations of `varuna-tui` were built on separate branches,
both using zigzag (Elm Architecture TUI framework) for rendering but different
event loop libraries for background I/O. This report compares them across code
quality, feature completeness, architectural integrity, and production readiness.

- **libxev branch**: `varuna-tui-libxev` (commit `b03a5eb`)
- **zio branch**: `varuna-tui-zio` (commit `e8ffaa3`)

---

## 1. Code Metrics

| Metric             | libxev     | zio        |
|--------------------|------------|------------|
| `main.zig`         | 551 lines  | 584 lines  |
| `api.zig`          | 610 lines  | 623 lines  |
| `views.zig`        | 601 lines  | 654 lines  |
| **Total TUI code** | **1762**   | **1861**   |
| TUI source files   | 3          | 3          |
| New dependencies   | zigzag, libxev | zigzag, zio |
| build.zig delta    | +29 lines  | +35 lines  |
| build.zig.zon deps | 2 entries  | 2 entries  |

Both implementations are remarkably close in size. The zio version is ~100 lines
larger, mainly due to more detailed data types in `api.zig` and additional view
modes (filter) in `views.zig`.

---

## 2. Feature Comparison Matrix

| Feature                         | libxev | zio    |
|---------------------------------|--------|--------|
| **Main torrent list view**      | Yes    | Yes    |
| **Status bar (global stats)**   | Yes    | Yes    |
| **Context-sensitive help bar**  | Yes    | Yes    |
| **Detail view**                 | Yes    | Yes    |
| **Detail tabs**                 | 3 (General, Trackers, Files) | 3 (Files, Trackers, Info) |
| **Add torrent dialog**          | Yes    | Yes    |
| **Remove/delete dialog**        | Yes    | Yes    |
| **Preferences view**            | Yes (raw JSON pretty-print) | Yes (structured fields) |
| **Filter mode**                 | No     | Yes (UI only, not wired) |
| **Torrent properties fetch**    | No     | Yes (dedicated endpoint) |
| **Auth/login support**          | No     | Yes (SID cookie management) |
| **j/k + arrow navigation**     | Yes    | Yes    |
| **Home/End keys**               | Yes    | Yes    |
| **Scroll in list**              | Yes    | Yes    |
| **Connection error display**    | Banner bar | Modal overlay dialog |
| **Pause/resume action**         | Functional (calls API) | Stubbed (no-op) |
| **Add torrent action**          | Functional (calls API) | Stubbed (no-op) |
| **Remove torrent action**       | Functional (calls API) | Stubbed (no-op) |
| **API polling**                 | Functional (synchronous) | Stubbed (AsyncRunner scaffold) |
| **CLI flags**                   | `--url`, `--help` | `--host`, `--port`, `--help` |
| **Status icons (colored)**      | No (text only) | Yes (symbols with state colors) |
| **Progress bar in list**        | No (percentage only) | Yes (inline mini-bar) |

### Key observations

**libxev wins on functional completeness.** All action dispatches (add, remove,
pause, resume) actually call the HTTP API. The 2-second polling loop runs real
HTTP requests and updates the model. The TUI is a working end-to-end client.

**zio wins on UI polish.** Colored status symbols, inline progress bars in the
torrent list, a dedicated disconnection overlay dialog, structured preferences
display (vs raw JSON), and a filter mode stub. The delete confirmation uses
y/n keys instead of Enter, which is safer for destructive actions.

---

## 3. Event Loop Integration

### libxev

```
Architecture:

  zigzag event loop (terminal I/O, key events, timers)
       |
       v
  Model.update(.tick) --> Model.pollDaemon() [synchronous HTTP]
       |
       v
  xev.Loop [initialized but unused]
```

libxev is imported and a `xev.Loop` is created in `Model.init`, but it is
**never used to drive any I/O**. All HTTP requests go through `std.http.Client`
synchronously on the zigzag tick callback. The loop handle sits idle in the model
struct as a placeholder for "future non-blocking I/O."

**Verdict**: libxev is dead weight. It adds a dependency that contributes nothing
to the current implementation. The event loop import increases compile time and
binary size without providing value. The honest description would be "zigzag only"
since zigzag's own `everyMs` timer drives all polling.

### zio

```
Architecture:

  zigzag event loop (terminal I/O, key events, timers)
       |
       v
  Model.update(.tick) --> AsyncRunner.poll() [check background results]
                     --> AsyncRunner.spawn(&pollDaemon) [background thread]
       |
       v
  zio.Runtime [initialized but not used for I/O]
  pollDaemon() [runs on OS thread, uses std.net TCP]
```

zio is imported, and a `zio.Runtime` is initialized in `main()`, but
**no actual I/O goes through zio**. The `pollDaemon` function uses
`std.net.tcpConnectToAddress` and raw HTTP/1.1 over a plain TCP stream. The
`AsyncRunner` that would bridge zigzag to background tasks references a `spawn`
call but the actual action handlers (togglePauseResume, submitAddTorrent,
submitDeleteTorrent, fetchDetailData, fetchPreferences) are all stubbed with
`_ = self;` no-ops.

**Verdict**: zio is also dead weight. The runtime is initialized and immediately
ignored. The HTTP client hand-rolls HTTP/1.1 over `std.net` instead of using
zio's networking. Both the initialization cost and the dependency are wasted.

### Summary

Neither implementation actually uses its event loop library for I/O. Both rely on
zigzag's built-in timer mechanism (`everyMs`) for polling. The difference is that
libxev's implementation at least makes the synchronous HTTP calls work end-to-end,
while zio's has the plumbing for async (AsyncRunner, background thread polling
function) but the action dispatches are no-ops.

---

## 4. API Client Design

### libxev (`api.zig`)

- Uses `std.http.Client` for HTTP transport (Zig standard library)
- Uses `std.Io.Writer.Allocating` to collect response bodies
- Hand-rolled JSON parsing with string scanning (`extractJsonStringValue`,
  `findMatchingBrace`, etc.)
- Strong typing: `TorrentState` enum with `fromString` and `displayString`
- Utility functions: `formatSize`, `formatSpeed`, `formatEta`, `formatProgress`
- Error type: `ApiError` enum with `ConnectionRefused`, `HttpError`, `ParseError`, etc.
- Functional: all 9 API endpoints are wired up and callable

### zio (`api.zig`)

- Hand-rolls HTTP/1.1 over `std.net.tcpConnectToAddress` (raw TCP sockets)
- Cookie-based session management (SID extraction from Set-Cookie header)
- Uses `std.json.parseFromSlice` for JSON parsing (standard library JSON)
- Richer data model: `TorrentProperties`, `Preferences` as structured types with
  many more fields (dl_limit, up_limit, max_connec, seq_dl, super_seeding, etc.)
- No formatting helpers in api.zig -- those live in views.zig
- 12 API methods including `login`, `getTorrentProperties`, `getPreferences`,
  `addTorrentFile` (with multipart form upload), `addTorrentMagnet`

### Comparison

| Aspect                  | libxev               | zio                    |
|-------------------------|----------------------|------------------------|
| HTTP transport          | `std.http.Client`    | Raw TCP + hand-rolled HTTP/1.1 |
| JSON parsing            | Hand-rolled scanner  | `std.json` (stdlib)    |
| Authentication          | None                 | Cookie/SID support     |
| Data model richness     | Moderate (15 fields) | Rich (25+ fields/type) |
| File upload support     | URL param only       | Multipart form-data    |
| Error handling          | Typed ApiError enum  | Error return from HTTP |
| Formatting helpers      | In api.zig           | In views.zig           |
| Functional endpoints    | 9 (all working)      | 12 (defined, mostly stubbed) |

The libxev API client is simpler but fully functional. The zio API client is more
ambitious (auth, multipart upload, richer types) but most of its methods are
never called because the action dispatches are no-ops.

The zio implementation's use of `std.json` for parsing is clearly better than the
libxev version's hand-rolled JSON scanner. The hand-rolled parser is fragile and
would break on nested objects, escaped characters in unexpected positions, or
non-standard JSON formatting. Using the standard library parser is the right call.

However, the zio implementation's hand-rolled HTTP/1.1 client over raw TCP is
worse than the libxev version's use of `std.http.Client`. The raw TCP approach
doesn't handle chunked transfer encoding, HTTP redirects, connection keep-alive,
or content-length verification. `std.http.Client` handles all of these.

---

## 5. View Rendering Quality

### libxev (`views.zig`)

- 12 comptime style constants at file scope (clean, reusable)
- Column-based torrent table with `formatTorrentColumns` and dynamic name width
- Progress bar with `#` fill and `-` empty characters
- Tabbed detail view with `DetailTab` enum and `.next()` method
- Input dialog with zigzag border rendering and padding
- Confirm dialog with delete-files toggle
- Preferences view with manual JSON pretty-printing

### zio (`views.zig`)

- Color palette in a `colors` struct namespace (clean organization)
- Status symbols (`v`, `^`, `||`, `..`, `!`) with per-state color coding
- Inline progress bar in the torrent list rows
- Disconnection overlay as a centered bordered dialog
- Structured preferences display (field labels + values, not raw JSON)
- Delete confirmation with y/n/f keybindings (safer UX)
- Filter mode rendering (input capture, not yet functional)

### Comparison

The zio views are more polished from a UX perspective. Status color coding,
inline progress bars, and structured preferences display show more attention to
the end-user experience. The libxev views are more utilitarian -- functional but
plain.

Both implementations correctly use zigzag's `Style` API for terminal rendering
and handle screen width/height for responsive layout.

---

## 6. Zig 0.15 Compatibility

Both implementations encountered and handled the same Zig 0.15 breaking changes:

| Change                           | Both handled? |
|----------------------------------|---------------|
| `ArrayList(T)` is now unmanaged  | Yes           |
| `File.stdout()` replaces getStdOut | Yes         |
| `Style.width()` takes `u16`     | Yes (zio adds `toU16` helper) |
| `KeyEvent.key.char` is `u21`    | Yes           |
| `Writer.interface.writeAll()`    | Yes           |

No unique compatibility issues in either branch. Both progress reports document
the same set of API changes, confirming these were genuine 0.15 migration points.

---

## 7. Architecture Quality

### Module separation

Both have identical module structure: `main.zig` (model + event loop),
`api.zig` (HTTP client + data types), `views.zig` (rendering). This is clean
and appropriate for the scope.

The zio version has slightly better separation: formatting helpers live in
`views.zig` rather than `api.zig`, keeping the API module focused on transport
and data modeling.

### Extensibility

The zio version is more extensible due to:
- Richer data types (adding a new view that shows `TorrentProperties` fields
  doesn't require API client changes)
- `ViewMode` enum in views.zig allows adding modes without touching main.zig
- Filter infrastructure is already scaffolded
- Auth/session management is already in place

The libxev version's advantage is that new features can be tested immediately
because all the action dispatch plumbing works. Adding a new action means writing
one function and it works.

### Error handling

The libxev version has better error handling in practice:
- `ApiError` enum with specific error variants
- Error cases are caught and turn into `self.connected = false` or
  `self.last_error = "Connection refused"`
- Poll failures degrade gracefully

The zio version has the error types defined but since actions are stubbed, error
paths are untested and unverified.

### Memory management

Both have a memory concern:
- **libxev**: Allocates per-frame with zigzag's allocator, properly frees old
  torrent/tracker/file data when new data arrives via `freeTorrents()` etc.
- **zio**: The progress report acknowledges a memory leak: `pollDaemon` uses
  `page_allocator` and results are never freed. The `applyApiResult` replaces
  slice pointers without freeing old data.

The libxev version handles memory lifecycle correctly. The zio version has a
known leak that would grow linearly with runtime.

---

## 8. Build Integration

### libxev

- Adds `run-tui` step (`zig build run-tui`)
- libxev pinned to main branch (no version tag): URL is `refs/heads/main.tar.gz`
- zigzag pinned to v0.1.2 via main branch

### zio

- Adds `tui` step (`zig build tui`)
- zio pinned to v0.9.0 via git ref: `git+https://...?ref=v0.9.0#d946751b...`
- zigzag pinned identically

The zio dependency is better pinned (specific version tag + commit hash) compared
to libxev's main-branch reference which could break at any time. This is a
significant practical difference for build reproducibility.

---

## 9. Dependency Assessment

### libxev (mitchellh/libxev)

- Well-known Zig event loop library by Mitchell Hashimoto
- Cross-platform (io_uring, epoll, kqueue, IOCP)
- Mature project with active maintenance
- But: not actually used in this implementation
- Risk: main-branch pin means any breaking change upstream breaks the build

### zio (lalinsky/zio)

- Less well-known I/O library
- Fiber/coroutine model
- Version-tagged release (v0.9.0)
- But: not actually used in this implementation
- The Runtime initialization is the only zio call in the entire codebase

### Shared: zigzag (meszmate/zigzag)

- Elm Architecture TUI framework, v0.1.2
- Both implementations depend on it equally
- This is the library that actually does the work in both cases

---

## 10. Summary: Strengths and Weaknesses

### libxev implementation

**Strengths:**
- All API actions work end-to-end (add, remove, pause, resume)
- API polling is functional (real HTTP calls every 2 seconds)
- Correct memory lifecycle (free-before-replace pattern)
- Uses `std.http.Client` (robust HTTP transport)
- Less total code for more working functionality

**Weaknesses:**
- libxev is imported but completely unused (dead dependency)
- Hand-rolled JSON parser is fragile and error-prone
- No auth support
- Plain text status (no color coding or symbols)
- Preferences shown as raw JSON
- Dependency pinned to main branch (fragile)

### zio implementation

**Strengths:**
- Richer data model with more API fields
- Uses `std.json` for parsing (correct, maintainable)
- Better UI polish (status colors, progress bars, structured prefs)
- Auth/session scaffolding in place
- Filter mode scaffolded
- Dependency pinned to version tag (stable)
- Safer delete confirmation UX (y/n instead of Enter)

**Weaknesses:**
- All action dispatches are stubbed no-ops (can't actually control torrents)
- API polling function exists but is never actually invoked from a working path
- zio is imported but completely unused (dead dependency)
- Hand-rolled HTTP/1.1 client (missing chunked encoding, redirects, keep-alive)
- Known memory leak in polling results
- More code for less working functionality

---

## 11. Recommendation

**For immediate production use: libxev branch**, with modifications.

The libxev implementation is the only one that actually works as a torrent client
UI. You can connect it to a running daemon and see torrents, add new ones, pause
them, and remove them. The zio implementation looks nice but cannot actually
control anything.

**Recommended merge strategy: take the best of both.**

1. Start with the libxev branch as the base (working action dispatch, correct
   memory management, functional polling)
2. **Remove the libxev dependency entirely** -- it does nothing; remove the
   import, the loop field, and the build.zig.zon entry
3. Replace the hand-rolled JSON parser with `std.json` (from the zio branch's
   `api.zig`)
4. Adopt the zio branch's richer data types (`TorrentProperties`, `Preferences`
   struct, auth support)
5. Port the zio branch's UI improvements: status color symbols, inline progress
   bars, structured preferences view, disconnect overlay dialog
6. Port the filter mode scaffolding
7. Replace `std.http.Client` in the libxev version's `api.zig` with a
   better approach -- keep `std.http.Client` for HTTP transport (it handles
   chunked encoding properly) but structure the client more like the zio version
   with proper session management
8. If background threading is desired later, use zigzag's `AsyncRunner` (which
   the zio branch demonstrates) without needing either libxev or zio as a
   dependency

The combined result would be a TUI with:
- Zero unnecessary event loop dependencies (zigzag alone handles everything)
- Working action dispatch (from libxev branch)
- Correct JSON parsing via `std.json` (from zio branch)
- Polished UI with status colors and progress bars (from zio branch)
- Proper memory management (from libxev branch)
- Auth support (from zio branch)

Neither libxev nor zio should be kept as dependencies in the final version. Both
are unused, and the TUI's needs (periodic HTTP polling, terminal rendering) are
fully served by zigzag alone. If true async I/O is needed in the future, the
daemon's io_uring ring could potentially be shared, but for a TUI that polls once
per second, synchronous HTTP on a background thread is more than adequate.
