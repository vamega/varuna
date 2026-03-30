# High-severity bugfixes -- 2026-03-30

## What was done

Fixed the 4 high-severity bugs identified in the code quality review
(`progress-reports/2026-03-30-code-quality-review.md`).

### H1: completePiece ignores bitfield set error

**File:** `src/torrent/piece_tracker.zig:293`

`complete.set(piece_index)` error was silently discarded with `catch {}`, meaning
`bytes_complete` would be incremented even if the set failed (out-of-range index).
Changed to `catch return false` so the caller is told the completion did not happen,
and `bytes_complete` stays consistent.

### H2: JSON injection via torrent names/paths

**Files:** `src/rpc/handlers.zig`, `src/rpc/sync.zig`, `src/rpc/json.zig` (new)

Torrent names, save paths, categories, tags, and file names were interpolated into
JSON strings without escaping. A torrent named `test"injection` would produce
malformed JSON.

Added `src/rpc/json.zig` with a `jsonSafe()` function that returns an
`std.fmt.Alt` formatter, escaping `"`, `\`, and control characters per RFC 8259.
Applied it to all user-provided strings in `serializeTorrentInfo` (handlers.zig),
`serializeTorrentObject` (sync.zig), and `handleTorrentsFiles` (handlers.zig).

### H3: Unsynchronized bitfield reads in handleTorrentsFiles

**Files:** `src/torrent/piece_tracker.zig`, `src/rpc/handlers.zig:470-484`

`handleTorrentsFiles` was reading `pt.complete.has(pidx)` directly without holding
the PieceTracker mutex. The event loop thread could be calling `completePiece` on
the same bitfield concurrently, which is a data race.

Added `PieceTracker.countCompleteInRange(start, end_exclusive)` that locks the mutex
once for the entire range scan, and updated the handler to use it.

### H4: handlePartialSend finds wrong buffer for multi-send peers

**Files:** `src/io/event_loop.zig`, `src/io/peer_handler.zig`, `src/io/protocol.zig`,
`src/io/peer_policy.zig`, `src/io/seed_handler.zig`

When multiple tracked sends were in-flight for the same slot (e.g., extension
handshake + piece response), `handlePartialSend` searched `pending_sends` by slot
and found the first match. If sends completed out of order, it would update the
wrong buffer's `sent` offset.

Added a monotonic `next_send_id` counter to EventLoop. Each `PendingSend` now carries
a unique `send_id`, which is encoded in the io_uring CQE's `context` field (u40,
never 0 since context=0 means untracked). `handlePartialSend` and `freeOnePendingSend`
now match on both `slot` AND `send_id`. Added `nextTrackedSendUserData(slot)` helper
that allocates the next send_id and returns the encoded user data.

## What was learned

- Zig 0.15 renamed `std.fmt.Formatter` to `std.fmt.Alt` (with `Formatter` as an
  alias). The `Alt` type uses `{f}` as the format specifier, not `{s}` or `{}`.
- io_uring CQEs do not carry the buffer pointer back, so matching sends to their
  buffers requires encoding an identifier in the user data field. The 40-bit
  `context` field in our `OpData` encoding is more than sufficient for this.

## Key file changes

- `src/torrent/piece_tracker.zig`: H1 fix (line ~293), H3 new method `countCompleteInRange`
- `src/rpc/json.zig`: new JSON escape formatter (H2)
- `src/rpc/handlers.zig`: H2 escape calls, H3 synchronized bitfield reads
- `src/rpc/sync.zig`: H2 escape calls
- `src/io/event_loop.zig`: H4 send_id in PendingSend, nextTrackedSendUserData helper
- `src/io/peer_handler.zig`: H4 send_id extraction from CQE context
- `src/io/protocol.zig`: H4 send_id in pending_sends.append
- `src/io/peer_policy.zig`: H4 send_id in pending_sends.append
- `src/io/seed_handler.zig`: H4 send_id in pending_sends.append
