# DHT Peer Delivery: Push vs Pull/Callback Model

## Current Model (Push-Based Global Queue)

Varuna's DHT discovers peers independently and stores results in a global
`peer_results: ArrayList(PeerResult)` on the DhtEngine. The event loop
drains this queue each tick via `drainDhtPeerResults()`, looking up the
torrent by info hash with `findTorrentIdByInfoHash()`.

This creates a race window: if DHT finds peers before the torrent is
registered in the event loop, `findTorrentIdByInfoHash` returns null
and peers are silently dropped. We work around this with `forceRequery()`
— when a torrent integrates into the event loop, it forces the DHT to
redo the `get_peers` lookup so the results arrive after the torrent is
registered.

The workaround is reliable (one extra lookup, ~64 UDP packets, peers
arrive within seconds of integration) but the underlying issue is
architectural: the DHT has no way to know which torrents are ready to
receive peers.

## How libtorrent Does It (Pull-Based Callbacks)

libtorrent (arvidn, used by qBittorrent) avoids this race entirely:

1. When a torrent is ready, it calls `prioritize_dht(weak_ptr<torrent>)`
   on the session (`session_impl.cpp:3801-3823`).
2. The session adds the torrent to a `m_dht_torrents` deque and schedules
   a DHT announce via timer.
3. DHT results come back via `on_dht_announce_response()` callback
   (`torrent.cpp:2911-2938`), which holds a `shared_ptr<torrent>`.
4. The callback guarantees the torrent exists and directly calls
   `add_peer()` on it.

The key insight: **DHT search is initiated by the torrent (pull), not by
a global registration (push).** The torrent controls when DHT starts,
and results are delivered via a direct callback tied to the torrent's
lifetime. There's no global results queue, no info hash lookup, and no
race window.

## How rtorrent Does It (Callback Slots)

rtorrent's libtorrent-rakshasa uses a per-torrent `TrackerDht` object
(subclass of `TrackerWorker`). Each torrent registers callback slots
(`m_slot_new_peers`, `m_slot_success`) that the DHT tracker calls when
peers are found. Results route directly to the torrent's registered
callback — no global queue or hash-based lookup needed.

## What a Refactor Would Look Like

To switch varuna from push to pull:

1. **Add a callback to DhtEngine**: Instead of `peer_results: ArrayList`,
   accept a function pointer or interface for delivering peers:
   ```zig
   pub const PeerResultCallback = *const fn (info_hash: [20]u8, peers: []std.net.Address) void;
   peer_callback: ?PeerResultCallback = null,
   ```

2. **Torrent initiates DHT**: In `integrateIntoEventLoop`, the torrent
   calls `engine.startSearch(info_hash)` (not `requestPeers`). The DHT
   only searches for hashes with active searches.

3. **Callback delivers peers**: When `completeLookup` finds peers, it
   calls the callback directly. The callback runs on the event loop
   thread and calls `addPeerForTorrent()`.

4. **Torrent controls lifecycle**: When a torrent stops or is removed,
   it calls `engine.stopSearch(info_hash)`. No more orphaned searches.

5. **Remove `drainDhtPeerResults`**: No longer needed — delivery is
   inline via callback.

Files touched: `src/dht/dht.zig`, `src/io/dht_handler.zig`,
`src/daemon/torrent_session.zig`, `src/io/event_loop.zig`.

## When to Do This

Low priority. Only worth doing if:
- We're already restructuring DhtEngine for another reason (BEP 44
  mutable items, DHT storage for announced peers, etc.)
- The `forceRequery` workaround proves insufficient (unlikely — it
  adds one extra lookup per torrent, negligible overhead)
- We want to support DHT search cancellation (currently no way to
  stop searching for a removed torrent's hash)

The current push model + `forceRequery` is functionally correct and
has no user-visible difference from libtorrent's pull model.
