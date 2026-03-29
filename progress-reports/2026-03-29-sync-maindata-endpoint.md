# Sync maindata endpoint

## What was done
Implemented `/api/v2/sync/maindata` endpoint matching qBittorrent's delta sync protocol. This is the primary endpoint that Flood and other WebUIs poll every 1-2 seconds for state updates.

## Key files
- `src/rpc/sync.zig` (new): `SyncState` struct with circular buffer of 100 snapshots, `computeDelta()` method that returns JSON with only changed torrents
- `src/rpc/handlers.zig`: Added `handleSyncMaindata` route and `sync_state` field to `ApiHandler`
- `src/rpc/root.zig`: Export sync module
- `src/main.zig`: Initialize and defer-deinit `SyncState`

## Design decisions
- **v1 simplification**: No field-level diffs. If any stat field changes on a torrent, the full torrent object is included. Change detection uses Wyhash over all key stat fields.
- **Circular buffer**: Last 100 snapshots stored in a ring buffer indexed by `rid % 100`. If a client sends a stale rid that's been evicted, it gets a full update.
- **Snapshot storage**: Each snapshot stores a `StringHashMap(u64)` mapping info_hash_hex to the wyhash of its stats. Keys are owned copies since torrent sessions can be removed.
- **server_state**: Always included with global transfer speeds, data totals, and rate limits. `alltime_dl`/`alltime_ul` currently equal session totals (no persistence yet).

## Protocol semantics
- `rid=0` or missing rid: full update with all torrents
- `rid=N`: delta since snapshot N; includes only changed/added torrents
- `torrents_removed`: hashes present in previous snapshot but absent in current state
- `full_update` field: true when rid=0 or snapshot not found

## Tests
- `statsHash` correctness: different progress values produce different hashes
- Circular buffer eviction: snapshot at rid N is evicted when rid N+100 is stored
