# varuna-tui: Terminal UI with zigzag and libxev

## Date: 2026-04-06

## What was done

Added `varuna-tui`, a new binary providing an rtorrent-style terminal user interface for the varuna daemon. The TUI communicates with the daemon over the qBittorrent-compatible WebAPI.

### Dependencies added
- **zigzag** (v0.1.2, Zig 0.15 compatible) -- TUI framework implementing the Elm architecture (Model-Update-View) with 30+ widgets, styling, and layout
- **libxev** (Zig 0.15 compatible) -- Cross-platform event loop; initialized in the model for future non-blocking I/O use

### Files created
- `src/tui/main.zig` -- Entry point and zigzag Model (Elm architecture: init/update/view)
- `src/tui/api.zig` -- HTTP client for the daemon API, JSON parsing, formatting helpers
- `src/tui/views.zig` -- View components: torrent table, status bar, detail view, dialogs

### Build integration
- Added `varuna-tui` executable target to `build.zig`
- Added `run-tui` build step (`zig build run-tui`)
- Dependencies added to `build.zig.zon`

### Features implemented
- **Main view**: Torrent list table with columns for name, size, progress, download/upload speed, seeds, peers, ETA, status
- **Status bar**: Global download/upload speeds, torrent count, DHT node count
- **Help bar**: Context-sensitive keybinding hints
- **Detail view**: Three tabs (General, Trackers, Files) with scrolling
- **Add dialog**: Text input for file path or magnet link
- **Remove dialog**: Confirmation with delete-files toggle
- **Preferences view**: Pretty-printed daemon preferences JSON
- **Navigation**: j/k and arrow keys, Enter for details, Tab for tab switching
- **API polling**: Every 2 seconds via zigzag's tick/every mechanism
- **HTTP client**: Real HTTP GET/POST using `std.http.Client` and `std.Io.Writer.Allocating`

### API endpoints used
- `GET /api/v2/torrents/info` -- torrent list
- `GET /api/v2/transfer/info` -- global stats
- `GET /api/v2/torrents/trackers?hash=X` -- tracker list
- `GET /api/v2/torrents/files?hash=X` -- file list
- `POST /api/v2/torrents/add` -- add torrent
- `POST /api/v2/torrents/delete` -- remove torrent
- `POST /api/v2/torrents/pause` -- pause
- `POST /api/v2/torrents/resume` -- resume
- `GET /api/v2/app/preferences` -- daemon preferences

## What was learned

### Zig 0.15 API changes
- `std.ArrayList(T)` in Zig 0.15 is the unmanaged variant (formerly `ArrayListUnmanaged`). It has no `init(allocator)` -- use `.empty` instead. All methods (`append`, `toOwnedSlice`, `writer`, `deinit`) require passing the allocator.
- `std.io.getStdOut()` no longer exists. Use `std.fs.File.stdout()` which returns a `File`. Get a writer with `.writer(&buf)` which returns a `File.Writer` with an `.interface` field of type `std.Io.Writer`.
- `std.Io.Writer.Allocating` is the replacement for collecting HTTP response bodies. Use `.writer.buffer[0..writer.end]` to get the written data.

### zigzag framework
- Follows Elm architecture: Model struct with `init`, `update`, `view` pub fns
- `Cmd.everyMs(ms)` sets up repeating timer ticks
- The `tick` field in the Msg union must be `zz.msg.Tick` (struct with `timestamp: i64, delta: u64`)
- `Program.init` sets model to `undefined`; model's `init` is called during `run()` -- cannot set model fields before `run()`
- Solution: use file-scoped variables for configuration that `Model.init` reads
- Key events use `u21` for char (Unicode codepoint), not `u8`
- `align` is a reserved keyword in Zig, cannot be used as parameter name

### libxev integration
- libxev loop is initialized in the model and available for future async I/O
- Current polling uses zigzag's built-in tick mechanism with synchronous HTTP
- Future optimization: use libxev for non-blocking HTTP with io_uring backend

## Remaining issues / follow-up work

- HTTP polling is synchronous (blocks the UI thread briefly during API calls). For a better experience, could use zigzag's `AsyncRunner` or libxev's non-blocking I/O to run HTTP requests on background threads.
- Peer list view not yet implemented (would use `/api/v2/sync/torrentPeers`)
- No authentication support yet (daemon login endpoint)
- Add torrent dialog only supports magnet links via URL parameter, not multipart file upload
- Preferences view is read-only (displays JSON but doesn't allow editing)
- Could add color-coded status indicators (green for seeding, yellow for downloading, red for error)

## Key code references

- `build.zig:167-185` -- varuna-tui build target and run-tui step
- `src/tui/main.zig:30-102` -- Model struct with all TUI state
- `src/tui/main.zig:67-68` -- Msg union with zigzag tick type
- `src/tui/main.zig:84-87` -- libxev loop initialization
- `src/tui/api.zig:127-290` -- ApiClient with real HTTP GET/POST
- `src/tui/views.zig:102-140` -- Torrent table column rendering
