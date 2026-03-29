# Multipart Form-Data Parsing for torrents/add

## What was done

Added multipart/form-data parsing so the `/api/v2/torrents/add` endpoint accepts torrent uploads from qBittorrent-compatible WebUIs (Flood, qBittorrent Web UI, etc.) which send torrents as multipart form uploads rather than raw bytes.

### New file: `src/rpc/multipart.zig`
- Zero-copy parser: `Part` struct holds slices into the original body buffer
- `parse(allocator, content_type, body)` extracts boundary from Content-Type, splits body by boundary markers, parses Content-Disposition headers for name/filename
- `isMultipart()` / `findPart()` / `freeParts()` helpers
- 7 tests covering: boundary extraction, single torrent upload, Flood-style multi-param upload, error cases, header param parsing

### Changes to `src/rpc/server.zig`
- Added `content_type: ?[]const u8` to `Request` struct
- Added `extractHeader()` for case-insensitive header lookup
- Added `parseContentLength()` to support Content-Length-aware body reads
- `handleRecv()` now waits for complete body based on Content-Length before dispatching (previously dispatched as soon as `\r\n\r\n` was seen, which could truncate POST bodies)
- Dynamic buffer growth: recv buffer starts at 8 KiB, grows up to 4 MiB for large torrent uploads
- 5 new tests for header extraction and Content-Type parsing

### Changes to `src/rpc/handlers.zig`
- `handleTorrentsAdd()` now checks Content-Type:
  - If `multipart/form-data`: parses parts, extracts `torrents` part for torrent bytes, `savepath` for save directory
  - Otherwise: uses raw body as torrent bytes (backward compatible with varuna-ctl)

## What was learned

- Returning slices to stack-local arrays from functions is undefined behavior in Zig (same as C). The initial implementation used a stack `[16]Part` buffer and returned a slice into it, which caused test failures due to corrupted data. Fixed by allocating the parts array via the caller's allocator.
- Multipart boundaries in the body are prefixed with `--` (the boundary value itself does not include the leading dashes). The closing marker has `--` appended. WebKit-style boundaries already start with `----` so the full delimiter becomes `------`.
- The HTTP server's `handleRecv` previously only checked for `\r\n\r\n` to decide the request was complete. For POST requests with bodies, this is insufficient -- the body may arrive in subsequent recv calls. Content-Length parsing was necessary to fix this.

## Code references

- `src/rpc/multipart.zig` (new file, entire)
- `src/rpc/server.zig:287-293` (Request struct with content_type)
- `src/rpc/server.zig:169-218` (handleRecv with Content-Length awareness)
- `src/rpc/server.zig:353-412` (parseRequest, extractHeader, parseContentLength)
- `src/rpc/handlers.zig:216-250` (handleTorrentsAdd with multipart support)

## Remaining work

- Additional multipart form fields could be extracted: `dlLimit`, `upLimit`, `sequentialDownload` (currently parsed but not wired to session manager)
- Multiple torrent files in a single upload (multiple `torrents` parts) not yet supported
- No URL-encoded form body parsing for non-multipart POST to torrents/add (would need to decode percent-encoding)
