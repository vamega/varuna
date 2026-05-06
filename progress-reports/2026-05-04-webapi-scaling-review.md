# 2026-05-04: WebAPI scaling review

What changed and why:
- Reviewed qBittorrent-compatible WebAPI paths for 10k-torrent behavior.
- Compared Varuna's current qBittorrent-compatible polling model against Flood's native API shape and browser push transports.
- No code behavior changed; this is a static scaling/design audit for future API work.

What was learned:
- Most list/sync API work tracks loaded torrents in `SessionManager.sessions`, not only active event-loop torrents.
- `/api/v2/sync/maindata` uses a delta response, but still snapshots, hashes, and stores change metadata for all loaded torrents on every poll.
- `getAllStats()` currently decorates every torrent with `queue_manager.getPosition()`. Since queue positions are stored in a linear array, all-stats endpoints become effectively quadratic when the queue contains every loaded torrent.
- `/api/v2/torrents/info` applies filters, category/tag matching, sorting, and pagination after collecting all stats, so `limit`/`offset` reduce response size but not snapshot work.
- `/api/v2/sync/torrentPeers` scales with configured peer slots / active peers for one torrent, not with loaded torrent count.
- Flood exposes a native `GET /api/activity-stream` Server-Sent Events stream with coarse full-update events such as `TORRENT_LIST_FULL_UPDATE`, plus `GET /api/torrents` returning an `id` and a hash-keyed torrent map. That is a useful UI-cache precedent, but a full-list/full-update shape is still too coarse for arbitrary 10k-torrent viewports unless paired with server-side query/view state.
- A push stream by itself does not solve the scaling problem. The expensive question is still "which rows does this UI need?" For large libraries with one or two human UI surfaces, the better unit is a server-side view: filter + sort + projection + window.
- SSE is a good first native push transport for Varuna: it is one-way, HTTP-native, browser-supported, reconnect-friendly, and matches "server pushes changes; clients use normal HTTP for commands." WebSockets are better if the same connection must carry bidirectional command/ack traffic or many dynamic subscriptions, but add upgrade/framing/ping/reconnect/backpressure complexity.
- More expressive search/query endpoints are worthwhile, but should be structured and bounded rather than free-form SQL-like strings. They should support exact filters, tag/category/status predicates, ranges, stable sorts, field projection, pagination/windows, and possibly facets.

Design direction:
- Keep `/api/v2/*` qBittorrent compatibility as a compatibility surface, not the high-scale UI surface.
- Add a varuna-native view API, for example:
  - `POST /api/v2/varuna/views` creates an ephemeral server-side view from `{ filter, sort, window, fields }`.
  - `GET /api/v2/varuna/views/<id>` returns `{ revision, total_count, rows }` for the current window.
  - `GET /api/v2/varuna/views/<id>/events?since=<revision>` streams SSE patches: rows changed, entered, left, moved, count changed, or reset required.
  - Commands remain ordinary authenticated HTTP POST/PATCH/DELETE requests.
- Maintain a compact `TorrentSummaryStore` separate from live `TorrentSession` objects. It should hold one summary per loaded torrent, revision counters, dirty sets, and indexes for common predicates such as status, tag, category, and stable sort keys.
- Coalesce hot fields such as speeds and ETA at a fixed UI cadence. Sorting by hot fields should be supported cautiously because it can reorder active torrents constantly.

Remaining issues or follow-up:
- Add an O(1) queue position index or cache positions in sessions before relying on all-stats endpoints at 10k torrents.
- Avoid double all-stats collection in `/sync/maindata` by deriving `server_state` aggregate fields from the already-collected stats or maintained counters.
- Consider exact-hash fast paths for `/torrents/info?hashes=...` and indexes for category/tag/state filters.
- Pool or reuse `SyncState` snapshot maps if `/sync/maindata` remains a dominant poll workload.
- Draft a varuna-native view/search API spec before implementing SSE. The transport should be the final delivery mechanism for a query model, not a substitute for one.
- Decide which filters/sorts get indexes first. Recommended first pass: status, category, tags, added_on, completion_on, name, size, ratio, progress, and queue position.
- Define reset/backpressure behavior for SSE views: if a client falls behind or the view changes too much to patch cheaply, send a `view_reset` event and require a snapshot refetch.
- Keep WebSocket as a later option if SSE plus REST becomes awkward for multiplexed views or command acknowledgement.

Key code references:
- `src/daemon/session_manager.zig:592` - `getAllStats()` iterates every loaded session.
- `src/daemon/session_manager.zig:601` - each stat lookup asks `QueueManager` for position.
- `src/daemon/queue_manager.zig:60` - queue position lookup is a linear scan.
- `src/rpc/sync.zig:53` - `/sync/maindata` collects all stats.
- `src/rpc/sync.zig:58` - `/sync/maindata` calls `getTransferInfo()`, which collects all stats again.
- `src/rpc/sync.zig:71` - every poll builds a full current-hash map.
- `src/rpc/sync.zig:192` - every response stores a full snapshot hash map.
- `src/rpc/handlers.zig:453` - `/torrents/info` collects all stats before filtering/paging.
- `src/rpc/handlers.zig:2586` - `hashes=all` expands through another all-stats pass.
- `src/daemon/session_manager.zig:2010` - peer sync scans active peer slots for one torrent.

External references:
- Flood README: https://github.com/jesec/flood
- Flood API activity stream / torrent list docs: https://flood-api.netlify.app/
- MDN Server-Sent Events: https://developer.mozilla.org/en-US/docs/Web/API/Server-sent_events/Using_server-sent_events
- MDN WebSocket API: https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API
