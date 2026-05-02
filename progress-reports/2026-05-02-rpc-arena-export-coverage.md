# RPC Arena Export Coverage

## What changed and why

- Added request-arena ownership coverage for dynamic `ApiHandler` responses across login headers, `/api/v2/app/preferences`, `/api/v2/transfer/info`, and `/api/v2/torrents/export`.
- Fixed `/api/v2/torrents/export` to duplicate `.torrent` bytes into the request allocator and return them through `owned_body`, instead of borrowing `session.torrent_bytes` after the session-manager mutex is released.

## What was learned

- Most audited dynamic handlers already build response bodies or extra headers from the request allocator and are reclaimed by arena reset.
- `/torrents/export` was the exception: it returned a session-owned buffer directly. That could dangle if the torrent session is removed before the HTTP send completes, and it also bypassed the arena response ownership contract.

## Remaining issues or follow-up

- `/sync/maindata` and `/sync/torrentPeers` intentionally keep persistent delta snapshots in `SyncState` / `PeerSyncState` parent allocators. Those are not per-request response leaks, but they remain separate persistent-memory surfaces from the request arena.
- Static response bodies and long-lived config strings such as `/api/v2/app/defaultSavePath` still borrow persistent storage by design.

## Key code references

- `src/rpc/handlers.zig:424` - routes `/api/v2/torrents/export` with the request allocator.
- `src/rpc/handlers.zig:2261` - duplicates exported torrent bytes into `owned_body`.
- `tests/rpc_arena_test.zig:447` - dynamic endpoint arena ownership regression.
- `tests/rpc_arena_test.zig:520` - login `Set-Cookie` header arena ownership probe.
- `tests/rpc_arena_test.zig:529` - `/api/v2/app/preferences` response ownership probe.
- `tests/rpc_arena_test.zig:540` - `/api/v2/transfer/info` response ownership probe.
- `tests/rpc_arena_test.zig:551` - `/api/v2/torrents/export` response ownership probe.
