# Code Quality Review -- 2026-03-30

## What was done

Comprehensive code quality review of the core codebase, covering the event loop,
peer handling, protocol parsing, session management, RPC handlers, storage, piece
tracking, and hasher. Also ran the full 24-test transfer matrix.

## Transfer test matrix

All 24 tests pass (1KB to 100MB single-file, multi-file with subdirectories,
various piece sizes 16KB-256KB). Fixed `scripts/test_transfer_matrix.sh` port
cleanup issue where leftover processes from a previous run caused tracker port
conflicts, resulting in 12/24 tests being skipped.

## Findings

### Critical

**(C1) Session pointer use-after-free in RPC handlers**
`src/rpc/handlers.zig:451-511` (handleTorrentsFiles), `:513-575` (handleTorrentsTrackers),
`:577-623` (handleTorrentsProperties): These call `getSession(hash)` which briefly
locks the SessionManager mutex, returns a raw `*TorrentSession` pointer, then
unlocks. The handler then reads session fields without holding the lock. If
`removeTorrent` is called concurrently from another API request, the session is
freed while the handler is still reading from it. This is a use-after-free.

The same pattern appears in `handleTorrentsInfo` (`:240-257`) via `getAllStats`,
but that is safer because `getAllStats` copies stats under the lock.

**(C2) Hasher result append can silently drop results**
`src/io/hasher.zig:207`: `self.completed_results.append(...) catch {};` -- if the
append fails (OOM), the hash result is silently dropped. The piece buffer
(`job.piece_buf`) is neither freed nor returned to the caller. This leaks memory
and causes the piece to be stuck in in_progress state forever (never completed,
never released).

### High

**(H1) PieceTracker.completePiece ignores set error**
`src/torrent/piece_tracker.zig:293`: `self.complete.set(piece_index) catch {};`
If the bitfield set fails (out-of-range index), the bytes_complete counter is
still incremented, permanently desynchronizing the piece tracker's progress
from reality. Although the index should always be valid if callers check bounds,
a defensive approach would skip the bytes_complete increment on error.

**(H2) JSON injection in RPC serialization**
`src/rpc/handlers.zig:907-934` (serializeTorrentInfo) and `src/rpc/sync.zig:241-267`
(serializeTorrentObject): Torrent names, save paths, categories, tags, and
comments are interpolated directly into JSON strings via `{s}` format. If any of
these contain double quotes, backslashes, or control characters, the JSON output
is malformed and clients will fail to parse it. Torrent names are taken from
untrusted .torrent files and commonly contain special characters.

**(H3) handleTorrentsFiles reads PieceTracker bitfield without synchronization**
`src/rpc/handlers.zig:477`: `pt.complete.has(pidx)` reads the bitfield directly
without holding the PieceTracker mutex. The event loop thread may be calling
`completePiece` (which modifies the same bitfield) concurrently. While individual
byte reads are atomic on x86, this is a data race per the Zig memory model and
could produce incorrect results on other architectures.

**(H4) handlePartialSend finds wrong buffer on multiple in-flight sends**
`src/io/event_loop.zig:923-940` (handlePartialSend): Scans pending_sends for
the FIRST buffer matching `slot`. If a peer has multiple tracked sends in flight
(e.g., extension handshake + piece response), this may find the wrong buffer.
The `sent` offset would be applied to the wrong buffer, corrupting the send.
The `freeOnePendingSend` function has the same first-match issue but is less
dangerous since it only frees on completion.

### Medium

**(M1) Sync state race on double mutex acquire**
`src/rpc/sync.zig:143-144` and `:153-154`: `computeDelta` calls
`getAllStats` (which locks SessionManager mutex), then separately locks the mutex
again for categories and tags. Between these two lock acquisitions, the session
list could change, causing the snapshot to have inconsistent data (e.g., a torrent
appears in stats but its category was already removed).

**(M2) Cleanup race in seed_handler pending_reads**
`src/io/seed_handler.zig:82-127`: The `handleSeedDiskRead` function finds a
pending read by scanning the list and computing an index from pointer arithmetic.
If a `swapRemove` on a different pending read happens between finding the entry
and computing the index (which can't happen in single-threaded event loop, but
the code is fragile), the index could be wrong. Currently safe because the event
loop is single-threaded, but the pointer arithmetic pattern
(`@intFromPtr(pr) - @intFromPtr(...)`) is error-prone and should use a direct
index scan.

**(M3) `persistNewCompletions` scans all pieces every time**
`src/daemon/torrent_session.zig:929-943`: Every call scans all `piece_count`
pieces to find newly completed ones. For large torrents (e.g., 10,000+ pieces),
this is O(n) on every tick. A more efficient approach would track which pieces
were completed since the last persist call, using the PieceTracker's completion
count delta to skip the scan entirely when nothing changed (already partially
done with the `resume_last_count` check at line 933, but the scan itself is
still O(n) when there ARE new completions).

**(M4) SessionManager.addTorrent holds mutex across auto-start**
`src/daemon/session_manager.zig:64-79`: The mutex is held from line 64 to 79,
covering both the HashMap put and the `startWithEventLoop` call. While
`startWithEventLoop` itself just spawns a thread and returns quickly, holding
the mutex during thread spawn is unnecessary and could block other API requests.

**(M5) Tags list uses O(n) duplicate check**
`src/daemon/session_manager.zig:252-257`: Adding a tag to a torrent scans the
entire tags list for duplicates. For a typical number of tags (<20) this is fine,
but the pattern is inconsistent with using a HashMap-based approach for the global
tag store.

**(M6) extractParam does not URL-decode values**
`src/rpc/handlers.zig:937-948`: Form-encoded parameters may contain
percent-encoded characters (e.g., spaces as `%20`, equals as `%3D`). The current
implementation returns raw encoded values, which could cause parameter mismatches
for save paths or category names containing special characters.

### Low

**(L1) Magic numbers in peer_policy.zig**
`src/io/peer_policy.zig:14-17`: `pipeline_depth=5`, `peer_timeout_secs=60`,
`unchoke_interval_secs=30`, `max_unchoked=4`, `optimistic_unchoke_slots=1` are
module-level constants. These are standard BitTorrent values and well-named, but
they should probably be configurable per-session or at least documented as
protocol defaults.

**(L2) ApiServer slot encoding limited to u8**
`src/rpc/server.zig:122-124`: The `encodeUd` function takes `slot: u8`, limiting
the API server to 256 client slots (though `max_api_clients=64` is lower). If
`max_api_clients` is ever raised above 255, the encoding silently truncates.

**(L3) cached_piece_data not torrent-aware**
`src/io/event_loop.zig:277-279`: The seed piece cache stores only one piece
globally (`cached_piece_index`), not per-torrent. In multi-torrent daemon mode,
a cache hit could serve data from the wrong torrent if two torrents happen to
have pieces with the same index. However, `servePieceRequest` validates the piece
is complete for the requesting torrent's bitfield, so this would only cause a
cache miss (not data corruption) when the cached data doesn't match.

**(L4) `peerCountForTorrent` is O(max_peers)**
`src/io/event_loop.zig:496-504`: Called multiple times during `addPeerForTorrent`
(twice: once for limit check, once for log warning). With `max_peers=4096`, this
scans 4096 slots each time. Could be maintained as a per-torrent counter instead.

**(L5) uTP send queue uses orderedRemove(0)**
`src/io/utp_handler.zig:102`: `orderedRemove(0)` on an ArrayList is O(n) because
it shifts all elements. For a packet send queue that drains from the front, a
ring buffer or linked list would be more efficient, though in practice the queue
is likely small.

## No test-passing hacks found

No code was found that appears designed to make tests pass rather than be correct.
There are no `if (testing)` conditionals, no hardcoded test-matching values, and
no stubbed functionality returning fake data. The test suite uses proper unit tests
with real io_uring rings (skipping via `SkipZigTest` when io_uring is unavailable).

## Key files reviewed

- `src/io/event_loop.zig` (1024 lines)
- `src/io/peer_handler.zig` (405 lines)
- `src/io/protocol.zig` (267 lines)
- `src/io/seed_handler.zig` (269 lines)
- `src/io/peer_policy.zig` (555 lines)
- `src/io/utp_handler.zig` (509 lines)
- `src/io/hasher.zig` (282 lines)
- `src/io/rate_limiter.zig` (264 lines)
- `src/daemon/torrent_session.zig` (967 lines)
- `src/daemon/session_manager.zig` (350 lines)
- `src/rpc/handlers.zig` (955 lines)
- `src/rpc/server.zig` (533 lines)
- `src/rpc/auth.zig` (235 lines)
- `src/rpc/sync.zig` (335 lines)
- `src/storage/writer.zig` (319 lines)
- `src/torrent/piece_tracker.zig` (665 lines)
