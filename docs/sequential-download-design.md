# Sequential Per-File Download — Design

**Status:** research / pre-implementation. Read-only audit of the
current piece-picker surface, plus a design for the per-file extension.
No code in `src/` is touched by this document.

**TL;DR.** varuna already has a torrent-level sequential-download
toggle (`PieceTracker.sequential: bool` in
`src/torrent/piece_tracker.zig:44`). libtorrent-rasterbar — which is
the closest production reference — *also* exposes sequential at the
torrent level only, not per file. This document proposes a varuna
extension: store sequential as a per-file bit, derive a `sequential_pieces`
bitfield (boundary pieces resolve to sequential under `max()` rules,
matching libtorrent's piece-priority composition), and switch the
picker to a two-phase claim (sequential pieces first, in index order,
then rarest-first over the rest). The torrent-level qBittorrent-
compatible toggle is preserved as "set every file's sequential bit."

---

## §1 — Goal

Allow a multi-file torrent to mix selection strategies on a per-file
basis: one file (or a subset) downloads sequentially in file-offset
order to enable streaming consumers (video players that can start
playback before the file is complete), while the remaining files
continue to use rarest-first to keep swarm health intact. Today's
flag is per-torrent, which is too coarse for the stream-one-file-from-
a-pack workload — flipping it forces *every* file in the torrent off
rarest-first, hurting overall download time.

The picker must:

- prefer pieces that overlap a sequential file in file-offset order;
- continue to use rarest-first for pieces that overlap only non-
  sequential files;
- handle boundary pieces (a single piece that spans a sequential and
  a non-sequential file) deterministically;
- continue to honour `do_not_download` (selective download) and the
  existing `wanted` mask;
- continue to support multi-source piece assembly, late-peer block
  stealing (Task #23), and smart-ban Phase 1-2 attribution without
  regression.

---

## §2 — libtorrent-rasterbar reference

The reference codebase is
`reference-codebases/libtorrent` (arvidn/libtorrent-rasterbar).

### §2.1 — Sequential download is per-torrent only

The flag is a single bit on the torrent:

- `include/libtorrent/torrent_flags.hpp:151` — `constexpr torrent_flags_t sequential_download = 9_bit;`
  Comment: "In this mode the piece picker will pick pieces with low
  index numbers before pieces with high indices. (...) **Sequential
  mode is not ideal for streaming media. For that, see
  set_piece_deadline() instead.**"
- `src/torrent.cpp:258` — constructor: `m_sequential_download(p.flags & torrent_flags::sequential_download)`.
- `src/torrent.cpp:9145` — `void torrent::set_sequential_download(bool const sd)`.

There is **no** per-file sequential surface in the public
`add_torrent_params`, `torrent_handle`, or `torrent_status` API. A
`grep -rn 'sequential' include/libtorrent/` only turns up the torrent-
level flag, the picker option, and the corresponding `torrent_status`
field.

### §2.2 — Picker integration: hard branch, not a tiebreaker

`src/peer_connection.cpp:911` (`peer_connection::picker_options`) is
where the per-peer call sets the picker mode bit. Reproduced in part:

```cpp
if (t->is_sequential_download())
{
    ret |= piece_picker::sequential;
}
else if (t->num_have() < m_settings.get_int(settings_pack::initial_picker_threshold))
{
    ret |= piece_picker::prioritize_partials;
}
else
{
    ret |= piece_picker::rarest_first;
    // ...
}
// only one of rarest_first and sequential can be set
TORRENT_ASSERT(((ret & piece_picker::rarest_first) ? 1 : 0)
    + ((ret & piece_picker::sequential) ? 1 : 0) <= 1);
```

The picker itself (`src/piece_picker.cpp:2118`, inside
`piece_picker::pick_pieces`) splits on the bit:

```cpp
if (options & sequential)
{
    // walk m_pieces in index order, picking high-priority first
    // then m_cursor..m_reverse_cursor for the rest
}
else if (options & rarest_first)
{
    // walk m_priority_boundaries by ascending availability
}
```

Sequential and rarest-first are **mutually exclusive code paths**, not
weighted alternatives. Within sequential, libtorrent still respects
piece priority — it walks `m_pieces` while `piece_priority(*i) ==
top_priority` first, then everything in `[m_cursor, m_reverse_cursor)`.
That ordering matters for our design: piece priority composes *over*
sequential, not under.

### §2.3 — File priority composes via `max()` over piece spans

The bridge from per-file priority to per-piece priority is
`src/torrent.cpp:154` (`file_to_piece_prio`):

```cpp
aux::vector<download_priority_t, piece_index_t> file_to_piece_prio(
    file_storage const& fs
    , aux::vector<download_priority_t, file_index_t> const& file_prios)
{
    aux::vector<download_priority_t, piece_index_t> pieces(...);
    for (auto const i : fs.file_range())
    {
        // ...
        // mark all pieces of the file with this file's priority
        // but only if the priority is higher than the pieces
        // already set (to avoid problems with overlapping pieces)
        for (piece_index_t p = start; p < end; ++p)
            pieces[p] = std::max(pieces[p], file_prio);
    }
    return pieces;
}
```

This is the libtorrent answer to the boundary case: a piece that
spans two files inherits the **maximum** priority of any file it
overlaps. That's the rule we'll mirror for the sequential bit.

`src/torrent.cpp:5799` (`update_piece_priorities`) is the path
re-run on every `set_file_priority` call, which translates fresh
file priorities into piece priorities and informs the picker.

### §2.4 — End-game mode

End-game in libtorrent is a piece-picker option
(`piece_picker::prioritize_partials`, set when many partial pieces
exist) plus per-block duplicate requests inside a piece. It is
orthogonal to sequential vs. rarest-first: both code paths in
`pick_pieces` consult the same partial-piece machinery for block-level
end-game.

### §2.5 — Streaming: the official answer is `set_piece_deadline()`

The torrent-flag comment in §2.1 explicitly says "Sequential mode is
not ideal for streaming media. For that, see set_piece_deadline()
instead." The deadline API
(`include/libtorrent/torrent_handle.hpp:430`) lets a caller mark
specific pieces with millisecond deadlines; the picker prioritises
those pieces over both rarest-first and sequential. This is how
qBittorrent's "Download first and last pieces first" toggle works
internally — it's deadline-driven, not sequential-driven.

### §2.6 — qBittorrent UI surface

The qBittorrent submodule pointer is `2aa33ee8a006d7c3ccd7255e74ed73fdd42aeb13`,
but the working tree at `reference-codebases/qbittorrent` is empty in
this checkout (the submodule is symlinked from the main checkout, and
the main checkout has not initialised it). Documented behaviour from
the upstream UI:

- **"Sequential download"** (right-click on a torrent → context menu, or `F6`):
  per-torrent toggle. Maps directly to `torrent::set_sequential_download`.
- **"Download in sequential order"** option in the torrent properties:
  same per-torrent toggle as above, just a different UI surface.
- **"Download first and last pieces first"**: separate per-torrent toggle.
  Implemented via libtorrent's `set_piece_deadline` on the head-of-file
  and tail-of-file pieces. Distinct from sequential download.
- qBittorrent does **not** expose per-file sequential download. Per-file
  control is limited to priority (do-not-download / normal / high / max).

### §2.7 — rakshasa/libtorrent

`grep -rn 'sequential' reference-codebases/libtorrent-rakshasa/src/`
returns only `MADV_SEQUENTIAL` (a kernel paging hint applied to mmap
chunks, `src/data/memory_chunk.h:27`) and unrelated mentions. There is
**no sequential download mode** in rakshasa. So rakshasa offers no
alternative reference for this design.

### §2.8 — Caveats libtorrent documents

The `torrent_flags::sequential_download` doc comment is unusually
forthcoming about the trade-off:

- Sequential trades rare-first swarm health for predictable in-order
  delivery.
- It is **not** ideal for streaming (deadline pieces are).
- "The actual pieces that are picked depend on other factors still,
  such as which pieces a peer has and whether it is in parole mode or
  prefer whole pieces-mode." — i.e., sequential is advisory, not a
  hard guarantee, and the picker can still skip ahead when a peer
  doesn't have the strict next piece.

These caveats apply 1:1 to varuna's design.

---

## §3 — Current varuna surface

### §3.1 — Picker

`src/torrent/piece_tracker.zig:15` (`PieceTracker`) already supports
torrent-level sequential mode:

- field `sequential: bool = false` (`piece_tracker.zig:44`)
- `setSequential(self: *PieceTracker, enabled: bool)` (`piece_tracker.zig:201`)
- `claimPiece` branches on `self.sequential` (`piece_tracker.zig:268`)
  to one of:
  - `claimRarestFirstLocked` (`piece_tracker.zig:275`)
  - `claimSequentialLocked` (`piece_tracker.zig:333`)

Both branches honour the `wanted` mask (selective download) and have
end-game fall-throughs when all eligible pieces are in-progress.
`claimSpecificPiece` (`piece_tracker.zig:372`) is mode-independent
and used for contiguous-run claims.

### §3.2 — File priority surface

`src/torrent/file_priority.zig:5`:

```zig
pub const FilePriority = enum(u2) {
    normal = 0,
    high = 1,
    do_not_download = 2,
};
```

`buildPieceMask` (`file_priority.zig:16`) walks files and marks every
piece any wanted file overlaps. Boundary pieces between a wanted and
an unwanted file are *included* — they hold bytes the wanted file
needs.

The piece tracker's `wanted` mask is set / swapped via
`setWanted` (`piece_tracker.zig:98`) and `swapWanted`
(`piece_tracker.zig:188`).

### §3.3 — File priority storage

Per-file priorities live on `TorrentSession`
(`src/daemon/torrent_session.zig:259`):

```zig
file_priorities: ?[]u8 = null,  // 0=skip, 1=normal, 6=high, 7=max
sequential_download: bool = false,
```

`apiPriorityToEnum` (`torrent_session.zig:991`) collapses the
qBittorrent-style 0/1/6/7 raw values to varuna's `FilePriority` enum.
`applyFilePriorities` (`torrent_session.zig:1039`) builds the wanted
mask and applies it via `pt.swapWanted`. `applySequentialMode`
(`torrent_session.zig:1092`) propagates the torrent-level flag to the
piece tracker.

The `SessionManager` API surface is in
`src/daemon/session_manager.zig`:

- `setSequentialDownload(hash, enabled)` (`session_manager.zig:642`)
- `setFilePriority(hash, file_indices, priority)` (`session_manager.zig:654`)

### §3.4 — RPC surface

In `src/rpc/handlers.zig`:

- `setSequentialDownload` (`handlers.zig:279`, handler at `:1072`) —
  qBittorrent-compatible, body params `hash` + `value`.
- `toggleSequentialDownload` (`handlers.zig:374`, handler at `:1987`) —
  qBittorrent-compatible, body param `hash`.
- `filePrio` (`handlers.zig:275`, handler at `:1035`) — qBittorrent-
  compatible, body params `hash`, `id` (pipe-separated indices),
  `priority` (0/1/6/7).

### §3.5 — Persistence (or lack thereof)

`grep -n 'sequential\|file_prio' src/storage/sqlite_backend.zig`
returns nothing. Neither the per-torrent `sequential_download` flag
nor the per-file priority array is currently persisted to the resume
DB. They live only in memory, attached to the in-process
`TorrentSession`. **This is a pre-existing gap** independent of the
sequential-per-file work — but the sequential-per-file design must
ride alongside a fix for it, otherwise per-file sequential settings
disappear on every daemon restart.

### §3.6 — File → piece-span layout

`src/torrent/layout.zig:26` (`Layout.File`) carries `first_piece` and
`end_piece_exclusive`. That's the only data the design needs to derive
the per-piece sequential mask: a file with file-index `i` overlaps
pieces `[files[i].first_piece, files[i].end_piece_exclusive)`. v1, v2,
and hybrid layouts populate these fields uniformly (`layout.zig:223,
:282`).

---

## §4 — Proposed design

### §4.1 — Storage shape

Add a sibling per-file array on `TorrentSession` (next to
`file_priorities`):

```zig
// In src/daemon/torrent_session.zig (alongside line 259)
file_sequential: ?[]bool = null,  // null = no per-file overrides; same len as files
```

Why a sibling array and not an enum widening:

- The existing `FilePriority` enum is `u2`. Widening it to also encode
  sequential would either need to flip to `u3` (forcing a re-pack of
  the storage array) or use a packed struct, both of which churn every
  `apiPriorityToEnum`/`buildPieceMask` call site.
- Sequential is orthogonal to priority. A file can be `do_not_download`
  *and* sequential is meaningless; a file can be `high` and either
  sequential or not. The orthogonal storage keeps this clean.
- Lazy allocation matches the existing `file_priorities` shape: `null`
  means "nothing per-file; use the torrent-level default."

### §4.2 — Picker shape

Replace the boolean `PieceTracker.sequential` with an optional
bitfield:

```zig
// src/torrent/piece_tracker.zig
sequential_pieces: ?Bitfield = null,  // null = no sequential pieces; bit set = sequential
```

The `setSequential(true)` torrent-level path remains a one-liner
helper that builds an all-bits-set bitfield. The new
`setFileSequential` path builds a bitfield where bit `p` is set iff
*any* file overlapping piece `p` has its `file_sequential` bit set.
That's the libtorrent `max()` rule from §2.3, applied to sequential.

`claimPiece` becomes a two-phase scan:

1. **Sequential phase.** If `sequential_pieces` is non-null, scan it
   for the lowest-index eligible unclaimed piece the peer has. If
   found, claim and return. End-game fall-through within sequential
   pieces (mirrors `claimSequentialLocked` lines 354-365).
2. **Rarest-first phase.** Run `claimRarestFirstLocked` over the
   *remaining* pieces (ones with `sequential_pieces` bit clear). If
   sequential phase already returned, this never runs. End-game fall-
   through within non-sequential pieces.

Pseudocode:

```zig
pub fn claimPiece(self: *PieceTracker, peer_has: ?*const Bitfield) ?u32 {
    self.mutex.lock();
    defer self.mutex.unlock();
    if (self.sequential_pieces) |seq_mask| {
        if (claimSequentialMaskedLocked(self, seq_mask, peer_has)) |idx| return idx;
        // sequential exhausted; fall through to rarest-first for non-sequential
        return claimRarestFirstMaskedLocked(self, seq_mask, peer_has);
    }
    return claimRarestFirstLocked(self, peer_has);
}
```

Where `claimSequentialMaskedLocked` requires `seq_mask.has(idx)` for
eligibility, and `claimRarestFirstMaskedLocked` requires
`!seq_mask.has(idx)`.

The boundary case (one piece spans a sequential file and a non-
sequential file) resolves to **sequential** because the OR-of-files
mask is set for that piece. Rationale matches libtorrent's `max()`:
once we've committed to streaming a file, any byte the file needs is
on the critical path, including bytes that incidentally belong to a
neighbouring non-sequential file.

### §4.3 — Composition with `do_not_download` and the wanted mask

`wanted` and `sequential_pieces` are independent. The picker checks
`isEligible` (i.e., not complete and within `wanted`) before checking
the sequential mask. A piece can be:

| `wanted.has` | `sequential_pieces.has` | claim path |
|---|---|---|
| 0 | * | not claimed (selective download skip) |
| 1 | 1 | sequential phase |
| 1 | 0 | rarest-first phase |

If a `do_not_download` file's sole piece happens to overlap a
sequential file, the existing wanted-mask logic in
`buildPieceMask` (`file_priority.zig:30-33`) sets the wanted bit
because the sequential file needs it. The piece is downloaded
sequentially. Correct outcome.

### §4.4 — Composition with `FilePriority.high`

libtorrent walks `m_pieces` while `piece_priority(*i) == top_priority`
*first* inside the sequential branch (`src/piece_picker.cpp:2123-2136`).
That is: high-priority pieces are claimed first, but **still in index
order** within the sequential branch. varuna doesn't currently
differentiate `.high` from `.normal` in the picker (the only thing
priority drives today is the wanted mask). The recommended v1
behaviour:

- v1: ignore `.high` in the picker, exactly like today. Sequential
  orders by index; `.high` is a no-op. This is consistent with the
  existing varuna behaviour.
- Future (out of scope): if/when varuna adds priority-tier scheduling,
  the rule from libtorrent applies — high-priority sequential pieces
  go first within the sequential phase, and high-priority non-
  sequential pieces go first within the rarest-first phase.

### §4.5 — Resume DB persistence

Add two tables in `src/storage/sqlite_backend.zig`. Both use the same
shape as the existing `rate_limits` / `share_limits` tables.

```sql
CREATE TABLE IF NOT EXISTS file_priorities (
    info_hash TEXT NOT NULL,
    file_index INTEGER NOT NULL,
    priority INTEGER NOT NULL,
    sequential INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (info_hash, file_index)
);

CREATE TABLE IF NOT EXISTS torrent_sequential (
    info_hash TEXT PRIMARY KEY,
    enabled INTEGER NOT NULL
);
```

`torrent_sequential` covers the existing per-torrent toggle (which is
also currently unpersisted). `file_priorities.sequential` covers the
new per-file bit. Co-locating the two in one table is intentional —
they're set together and read together.

Schema migration uses `CREATE TABLE IF NOT EXISTS`, so existing
deployments stay readable. Loading on session startup happens in the
same path as `rate_limits` (background-thread `loadRateLimits` shape)
so the daemon's event loop never blocks on SQLite.

This work is technically a pre-existing-gap fix (§3.5) but it has to
land alongside the design; without it, per-file sequential settings
vanish on restart.

### §4.6 — API surface

Three changes in `src/rpc/handlers.zig`:

1. **Existing.** `setSequentialDownload(hash, value)` keeps qBittorrent
   semantics: `value=true` sets every file's `file_sequential[i] = true`
   *and* sets `torrent_sequential.enabled = 1`. `value=false` clears
   both. This preserves UI behaviour for clients that don't speak the
   varuna extension.
2. **Existing.** `toggleSequentialDownload(hash)` flips the per-torrent
   bit, same shape as today.
3. **New.** `POST /api/v2/varuna/torrents/setFileSequential` with body
   params:
   - `hash`: torrent info-hash
   - `id`: pipe-separated file indices (matches qBittorrent
     `filePrio` shape)
   - `value`: `"true"` or `"false"`
   This is varuna-namespaced (`/api/v2/varuna/...`) because qBittorrent
   doesn't have an equivalent endpoint. Match the namespace the move-
   job endpoint is already using (`POST /api/v2/varuna/torrents/move`,
   STATUS.md §"Daemon Features").

`SessionManager` gets one new method:

```zig
pub fn setFileSequential(
    self: *SessionManager,
    hash: []const u8,
    file_indices: []const u32,
    enabled: bool,
) !void
```

Same lazy-allocation shape as `setFilePriority`
(`session_manager.zig:654-679`), then call `session.applyFilePriorities()`
to rebuild the sequential mask alongside the wanted mask.

### §4.7 — Mask rebuild path

`TorrentSession.applyFilePriorities` (`torrent_session.zig:1039`) is
the central rebuild point. Extend it to emit two outputs from one
walk:

- `wanted` mask (existing)
- `sequential_pieces` mask (new) — bit `p` set iff
  `file_sequential[i] == true` for any file `i` whose
  `[first_piece, end_piece_exclusive)` contains `p`.

Apply both atomically via `pt.swapWanted` and a new `pt.swapSequential`
(symmetric to `swapWanted`). Free old bitfields outside the picker
mutex, same shape as the existing `swapWanted` callers (line 1083 +
1086).

---

## §5 — Interaction with existing systems

### §5.1 — `tryFillPipeline` / late-peer block-stealing (Task #23)

`src/io/peer_policy.zig:291` (`tryFillPipeline`) operates inside a
single piece — it requests blocks from `peer.current_piece` and
prefetches `peer.next_piece` via `pt.claimPiece(peer_bf)`. The
sequential-aware claim is transparent here: `claimPiece` returns the
next sequential piece the peer has, and `tryFillPipeline` continues
its block-level pipelining unchanged.

Block stealing (`peer_policy.zig:411-426`) is also unaffected:
stealing operates on `dp.block_infos` for the current piece. Whether
the piece was claimed via sequential or rarest-first doesn't matter
for stealing.

The only interaction worth calling out is **next-piece prefetch
limited by sequential availability**: a peer prefetching ahead while
in sequential mode may not find a "next" piece if the peer doesn't
have the strict next index. Today's `claimPiece` would skip past
unsequential matches to the next sequential one; this matches
libtorrent's caveat in §2.8 ("the actual pieces that are picked
depend on other factors still"). No change recommended.

### §5.2 — Smart-ban Phase 1-2

`src/net/smart_ban.zig` records per-block peer attribution and
compares re-downloaded block hashes against the failed-piece block
hashes. It is orthogonal to which file the piece belongs to and which
mode picked it. **No interaction.**

### §5.3 — Multi-source piece assembly

The multi-source design (`docs/multi-source-piece-assembly.md`) lets
multiple peers contribute blocks to the same `DownloadingPiece`.
`tryJoinExistingPiece` (`peer_policy.zig:451-499` and the join-or-
create code path) checks that the joining peer has the piece via
`peer_bf.has(dp.piece_index)` before joining. That gate is
mode-independent: a sequential piece in flight from peer A can be
joined by peer B if B has it, regardless of whether other pieces in
flight are sequential or rarest-first.

The one observable difference under per-file sequential: while a
sequential file is still downloading, the picker concentrates new
claims on a single piece (the lowest-index eligible). This naturally
narrows the multi-source distribution width — fewer pieces in flight
means fewer peers contributing. That's a streaming-vs-throughput
trade-off the user opts into when they set the sequential bit. No
mitigation for v1; if it becomes a problem, the v2 work would relax
sequential after the first N pieces are in (so the player has enough
buffer to start) and drop back to rarest-first for the tail.

### §5.4 — End-game mode

varuna's end-game is implicit: when every wanted piece is in-progress,
`claimRarestFirstLocked` (`piece_tracker.zig:317-329`) and
`claimSequentialLocked` (`piece_tracker.zig:354-365`) both fall
through to "claim any in-progress piece the peer has." Under per-
file sequential, end-game-within-sequential-pieces remains the same;
when sequential is exhausted, the picker falls through to rarest-
first, which has its own end-game branch.

The two-phase design composes cleanly: end-game is per-phase. No
additional logic needed.

### §5.5 — Streaming consumers — head priority and playback-window priority

A pure sequential download flag is **not** sufficient for streaming.
Real video players also want:

- **Head priority** — the first N pieces of the file ASAP, so the
  player can demux containers and start playback. Without head
  priority, a player stalls until pieces 0..k arrive in strict order,
  which under sequential is fine but slow.
- **Tail priority** — for some container formats (MOV, MP4 with
  `moov` at end), the player needs the last piece before it can
  decode the head. qBittorrent's "Download first and last pieces
  first" toggle covers this.
- **Playback-window priority** — pieces at the current playback
  position (random-seek scenarios) should jump the queue.

In libtorrent these are all implemented via `set_piece_deadline`
(§2.5). The recommended varuna v1 scope is **sequential-only**; head
and tail priority can layer on later via a `setPieceDeadline`-shaped
API, with the picker honouring per-piece deadlines as a third phase
that runs *before* sequential. v1 sequential is a meaningful step on
its own — for music, audiobooks, and video formats with `moov` at
start, sequential alone gives a usable streaming experience.

---

## §6 — Tests

Inline tests in `src/torrent/piece_tracker.zig`:

1. `sequential_pieces` mask: lowest-index sequential piece returned
   first; non-sequential pieces returned only after sequential
   exhaustion.
2. End-game within sequential pieces: when all sequential pieces are
   in-progress, claim returns one of them again, not a non-sequential
   piece.
3. End-game falls through to non-sequential rarest-first when no
   sequential pieces remain.

Inline tests in `src/torrent/file_priority.zig`:

4. `buildSequentialMask` (the symmetric helper to `buildPieceMask`):
   single sequential file → bits `[first, end)` set; boundary piece
   between sequential and non-sequential file → bit set; piece in
   pure-non-sequential region → bit clear.

Sim test under `EventLoopOf(SimIO)` + scripted peers
(`tests/sim_per_file_sequential_test.zig`, new):

5. Two-file torrent: file 0 sequential, file 1 rarest-first. Two
   peers with disjoint bitfields covering both files. Run the EL until
   both files complete. Assert (a) pieces from file 0 complete in
   strict file-offset order, (b) pieces from file 1 complete in some
   non-strict order (i.e., the non-sequential pieces are not also
   accidentally getting sequential treatment), (c) total piece count
   matches the torrent.
6. Boundary piece test: file 0 sequential (3 bytes, piece_length 4) +
   file 1 rarest-first (7 bytes, piece_length 4) → piece 0 spans both.
   Assert piece 0 is in the sequential phase and arrives before
   pieces 1 and 2.

Persistence test (`tests/file_priority_resume_test.zig`, new):

7. Save → close → reopen → verify per-file sequential bits round-trip.
   Same shape as the rate_limits resume test.

---

## §7 — Open questions

These need user input before implementation begins.

1. **Default semantics of the qBittorrent-compatible
   `setSequentialDownload`.** When the operator sets the per-torrent
   toggle, do we want it to:
   - (a) overwrite every file's sequential bit, or
   - (b) act as a "global default" only when no per-file overrides
     exist, leaving per-file overrides intact?
   Recommendation: **(a) overwrite**. Simpler mental model, matches
   qBittorrent's ground truth (no per-file knobs), and avoids "why
   isn't sequential turning off when I clear the toggle" surprises.
   Confirm.

2. **Persistence shape.** §4.5 proposes one combined
   `file_priorities` table covering both priority and sequential, plus
   a `torrent_sequential` table for the torrent-level toggle. The
   alternative is two separate tables. Combined feels right because
   priority and sequential are always set together by the same RPC
   call sequence — but there is no precedent in varuna for a
   "compound" table. Confirm.

3. **Should v1 also implement the "first/last piece priority" for
   streaming?** This is the qBittorrent-equivalent of
   `set_piece_deadline` on pieces 0 and N-1. It's strictly more
   useful than sequential alone for video streaming. Recommendation:
   **defer to v2**. v1 sequential is bounded enough to ship
   confidently; piece-deadline machinery is its own design doc.
   Confirm scope.

4. **`high` priority interaction.** §4.4 recommends ignoring `.high`
   in the picker for v1, matching today's behaviour. If we *do* want
   `.high` to mean something, the libtorrent rule (high-priority
   pieces first, in-order within high; then non-high, in-order) is
   the canonical answer. Confirm v1 scope.

5. **Picker behaviour when sequential file is fully complete.** Today
   the rarest-first picker happily ignores complete pieces. Under
   per-file sequential: once every sequential piece is complete, the
   sequential phase always misses, and the picker falls through to
   rarest-first for the rest. **No code path needed** — this is
   automatic from the two-phase design. Recording for clarity.

6. **Worker/RPC concurrency.** `applyFilePriorities` already runs
   under the `SessionManager` mutex (`session_manager.zig:643-644`).
   Adding `applyFileSequential` follows the same pattern. The picker-
   side `swapWanted` and a new `swapSequential` need to be either
   atomic individually (today's swapWanted shape) or wrapped in a
   single mutex acquisition. Recommendation: **atomic individually**,
   matching `swapWanted`. The transient state where wanted has been
   swapped but sequential hasn't is harmless — `claimPiece` always
   reads both under one mutex, and either combination is internally
   consistent (just one tick of "old sequential, new wanted").

---

## §8 — Estimated scope

| Component | Lines | Days |
|---|---|---|
| `PieceTracker.sequential_pieces: ?Bitfield`, `swapSequential`, two-phase claim | ~70 prod + ~50 tests | 1.0 |
| `file_priority.buildSequentialMask` helper + tests | ~30 prod + ~30 tests | 0.25 |
| `TorrentSession.file_sequential: ?[]bool` + `applyFilePriorities` extension | ~40 prod | 0.25 |
| `SessionManager.setFileSequential` + lazy-alloc shape | ~30 prod | 0.25 |
| Resume DB schema (`file_priorities` + `torrent_sequential` tables, save/load, migration) | ~120 prod + ~40 tests | 1.0 |
| RPC handler `setFileSequential` (varuna-namespaced) | ~40 prod | 0.25 |
| Sim test under `EventLoopOf(SimIO)` for per-file sequential ordering | ~120 tests | 0.5 |
| Boundary-piece + end-game inline tests | ~80 tests | 0.25 |
| **Total** | **~330 prod + ~320 tests** | **~3.5–4 days** |

This is comparable in scope to the partial-seed (BEP 21) and selective
download work already on `Done`.

---

## §9 — References

- libtorrent piece picker: `reference-codebases/libtorrent/src/piece_picker.cpp:1976` (`pick_pieces`), `:2118` (sequential branch), `:2175` (rarest-first branch).
- libtorrent torrent flags: `reference-codebases/libtorrent/include/libtorrent/torrent_flags.hpp:151`.
- libtorrent file→piece priority composition: `reference-codebases/libtorrent/src/torrent.cpp:154` (`file_to_piece_prio`).
- libtorrent picker mode selection: `reference-codebases/libtorrent/src/peer_connection.cpp:911` (`picker_options`).
- libtorrent piece deadline (the streaming primitive): `reference-codebases/libtorrent/include/libtorrent/torrent_handle.hpp:430` (`set_piece_deadline`).
- varuna piece tracker: `src/torrent/piece_tracker.zig:15`, sequential branch `:333`, rarest-first branch `:275`.
- varuna file priority: `src/torrent/file_priority.zig:5` (enum), `:16` (`buildPieceMask`).
- varuna session storage: `src/daemon/torrent_session.zig:259` (`file_priorities`), `:252` (`sequential_download`), `:1039` (`applyFilePriorities`).
- varuna SessionManager API: `src/daemon/session_manager.zig:642` (`setSequentialDownload`), `:654` (`setFilePriority`).
- varuna RPC handlers: `src/rpc/handlers.zig:279` (`setSequentialDownload`), `:374` (`toggleSequentialDownload`), `:275` (`filePrio`).
- varuna layout: `src/torrent/layout.zig:26` (`Layout.File`).
- varuna resume DB tables: `src/storage/sqlite_backend.zig:62-296` — note absence of `file_priorities` / `sequential_download`.
- Multi-source piece assembly: `docs/multi-source-piece-assembly.md`.
- Smart-ban Phase 1-2: STATUS.md `Smart ban Phase 1-2` entry.
