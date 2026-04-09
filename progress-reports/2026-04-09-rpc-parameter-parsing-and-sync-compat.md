# 2026-04-09: RPC Parameter Parsing And Sync Compatibility

## What was done and why

Finished the remaining API correctness work for request parsing, peer sync deltas, and browser-auth semantics.

- `src/rpc/handlers.zig:26` removes the invalid `Access-Control-Allow-Credentials: true` pairing with wildcard origin. The API now behaves as a same-origin cookie API instead of advertising unsupported cross-origin credentialed access.
- `src/rpc/handlers.zig:138` marks the login cookie `SameSite=Lax`, which matches the intended browser-auth posture.
- `src/rpc/handlers.zig:552` makes `setPreferences` fail closed on malformed JSON and invalid form values instead of silently retaining old values.
- `src/rpc/handlers.zig:1327` and `src/rpc/sync.zig:202` add a dedicated peer-delta snapshot path for `/api/v2/sync/torrentPeers`, including `rid`, `full_update`, changed peers only, and `peers_removed`.
- `src/rpc/handlers.zig:1626` keeps central in-place URL decoding in `extractParam`, so form/query values are decoded consistently for all handlers.

## What was learned

- qBittorrent compatibility is not just field shape. The sync endpoints need stateful rid handling or polling clients end up doing full peer refreshes forever.
- The combination `Access-Control-Allow-Origin: *` plus `Access-Control-Allow-Credentials: true` is not merely suboptimal; it is incoherent for browser cookie auth. Removing the credential claim is safer than pretending cross-origin cookie auth works.
- Once parameter decoding is centralized, downstream handlers can stop open-coding `%0A` or `+` handling and become much easier to reason about.

## Remaining issues / follow-up

- `server.Request` still does not parse `Origin`, so this remains a deliberately same-origin cookie API rather than an origin-reflecting credentialed CORS API.
- `/sync/torrentPeers` now has delta semantics, but it still keys peers by the string returned from `SessionManager.getTorrentPeers()`. If that key format changes, the snapshot state must change with it.

## Code references

- `src/rpc/handlers.zig:26`
- `src/rpc/handlers.zig:138`
- `src/rpc/handlers.zig:552`
- `src/rpc/handlers.zig:1327`
- `src/rpc/handlers.zig:1626`
- `src/rpc/sync.zig:202`
