# RPC JSON Response Structs

## What changed and why

- Added `src/rpc/json_body.zig`, a small JSON response helper for serializing typed values into owned `server.Response` bodies.
- Replaced direct JSON body formatting in several RPC handlers with response structs, including build info, transfer info, torrent files, trackers, properties, move status, connection diagnostics, web seeds, ban import/unban summaries, banned peer listings, and piece state/hash responses.
- Replaced the large `/api/v2/app/preferences` formatted JSON block with `PreferencesResponse`, preserving qBittorrent field names, boolean fields, numeric compatibility defaults, and fixed 4-decimal ratio formatting.
- Moved qBittorrent torrent list row serialization in `src/rpc/compat.zig` behind `TorrentJsonBody`, preserving custom 4-decimal fields with `json_body.Fixed4`.
- Replaced the hand-formatted `sync/maindata` `server_state` object with `SyncServerStateResponse`.

## What was learned

- `std.json` handles string escaping for `[]const u8` fields, so handler code no longer needs to route each string through `jsonSafe`.
- `[]u8` is serialized as a JSON string by Zig, but `/torrents/pieceStates` expects an array of numeric byte states; that endpoint now uses a small wrapper with custom `jsonStringify`.
- Some RPC outputs remain dynamic object maps, so a full conversion should use explicit map-shaped wrappers or keep those sections streamed.

## Remaining issues or follow-up

- `sync/maindata` and `sync/torrentPeers` still stream dynamic torrent/peer maps around typed object fragments.
- Several error responses are still static string literals; the shared helper is now available, but replacing every literal would be a larger churn pass.

## Key references

- `src/rpc/json_body.zig:12`
- `src/rpc/json_body.zig:35`
- `src/rpc/compat.zig:89`
- `src/rpc/compat.zig:171`
- `src/rpc/handlers.zig:639`
- `src/rpc/handlers.zig:1834`
- `src/rpc/handlers.zig:2173`
- `src/rpc/handlers.zig:2281`
- `src/rpc/handlers.zig:2478`
- `src/rpc/handlers.zig:3052`
- `src/rpc/sync.zig:154`
- `src/rpc/sync.zig:205`
