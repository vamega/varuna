# 2026-04-05: DHT Peer Feed Race Condition Fix

## What Was Done

Fixed a race condition where DHT-discovered peers were silently dropped,
causing torrents with few tracker peers (especially Ubuntu) to download
extremely slowly or not at all.

## Root Cause

The timing of DHT peer discovery vs event loop registration created a
window where peers were found but couldn't be delivered:

1. Torrent added via API → main loop calls `requestPeers()` immediately
2. DHT bootstrap completes (~1s), `get_peers` lookup starts
3. DHT finds peers (e.g., 9 peers for Ubuntu) within seconds
4. `drainDhtPeerResults()` calls `findTorrentIdByInfoHash()` → **returns null**
   because `integrateIntoEventLoop()` hasn't been called yet
5. **All discovered peers silently dropped** (`orelse continue`)
6. `start()` finishes tracker announce (minutes for UDP-only trackers)
7. `integrateIntoEventLoop()` registers torrent in event loop
8. Next DHT requery is 5 minutes away — initial peers are lost

This explains why Ubuntu was "incredibly slow" — the only peer it had
was the single one from the tracker. The 9 DHT peers were found quickly
but thrown away because the event loop didn't know about the torrent yet.

## Fix

Added `DhtEngine.forceRequery(info_hash)` which resets
`pending_search_done[i]` for the given hash, triggering an immediate
`get_peers` lookup on the next tick.

In `integrateIntoEventLoop()`, replaced `requestPeers()` with
`forceRequery()`. This means:
- Early `requestPeers()` in the main loop fires immediately (might find
  peers that get dropped — that's OK)
- When the torrent is finally registered in the event loop, `forceRequery()`
  triggers a fresh `get_peers` lookup
- This time `findTorrentIdByInfoHash()` succeeds and peers are fed to
  the connection pipeline

## Impact

Before fix: Ubuntu ISO stuck at 0.07 MB/s with 1 peer for minutes.
After fix: DHT peers connected within 10-20 seconds of torrent integration.

## Code References

- `src/dht/dht.zig` — `forceRequery()` method
- `src/daemon/torrent_session.zig:469-477` — calls `forceRequery` on integration
- `src/io/dht_handler.zig:51` — the `findTorrentIdByInfoHash` that returned null
