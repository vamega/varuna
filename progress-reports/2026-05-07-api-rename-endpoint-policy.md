# API Rename Endpoint Policy

## What changed and why

- Documented that qBittorrent-compatible `renameFile` and `renameFolder`
  remain intentionally unsupported.
- Updated the runtime 501 responses to tell API clients to leave Varuna-managed
  files in place and use hard links in a separate directory tree for alternate
  names or organization.
- Added focused API assertions so the hard-link guidance stays present in both
  501 responses.

## What was learned

The compatibility gap is a product policy, not just missing plumbing. Varuna's
storage path model is tied to torrent metadata plus the save root; per-file or
per-folder virtual renames would add manifest remapping, active-download
coordination, and resume persistence complexity. Hard links give users an
external organization layer without changing the daemon's managed paths.

## Remaining issues or follow-up

- `toggleSpeedLimitsMode` remains the better compatibility endpoint to tackle
  next if we want a real qBittorrent API gap closed.
- If users need cross-filesystem organization, hard links will not be enough;
  that should be handled by external copies/reflinks or a separate media-library
  workflow, not by Varuna file renames.

## Key code references

- `docs/api-compatibility.md:72` - endpoint matrix marks `renameFile` unsupported.
- `docs/api-compatibility.md:77` - rename policy and hard-link guidance.
- `src/rpc/handlers.zig:2218` - `renameFile` 501 response.
- `src/rpc/handlers.zig:2228` - `renameFolder` 501 response.
- `tests/api_endpoints_test.zig:186` - response guidance regression tests.
