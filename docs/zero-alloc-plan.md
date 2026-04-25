# Zero-Allocation Data Plane Plan

This document describes a path toward eliminating all dynamic allocation on varuna's
data-plane (piece download, peer wire protocol, disk I/O) after EventLoop initialisation.
Control-plane paths (RPC, tracker, DHT, metainfo parsing) are addressed separately with a
bump-allocator model.

The motivation comes from TigerBeetle's safety model: static allocation eliminates
use-after-free, removes unpredictable latency spikes from the allocator, and makes memory
usage auditable at startup. For a BitTorrent daemon the data plane is the hot path;
the control plane is low-frequency enough that a simple arena-reset model suffices.

Links: [STATUS.md](../STATUS.md) | [piece-hash-lifecycle.md](piece-hash-lifecycle.md) | [future-features.md](future-features.md)

---

## How the receive path works today

Understanding the receive path is necessary before auditing allocations on it.

Each peer runs a two-phase state machine driven by io_uring completions:

**Phase 1 — header**: Read exactly 4 bytes into `peer.header_buf: [4]u8`, embedded
directly in the `Peer` struct. Parse the big-endian length prefix. No allocation.

**Phase 2 — body**: Allocate a buffer of `msg_len` bytes, submit a recv SQE into it,
and on completion call `processMessage`. Two paths:

- `msg_len ≤ 16`: point `body_buf` at the embedded `peer.small_body_buf: [16]u8`. No
  allocation. This covers every small control message: choke, unchoke, interested,
  not-interested, have, cancel, request (all ≤ 13 bytes).
- `msg_len > 16`: `body_buf = allocator.alloc(u8, msg_len)`. Freed immediately after
  `processMessage` returns. This fires for every PIECE message (9-byte header + up to
  16 KB block data = up to ~16,393 bytes), every BITFIELD, and large extension messages.

For a PIECE message, `processMessage` extracts the piece index and block offset from the
first 8 bytes of the body, then **copies** the block data from `body_buf` into a separate
`piece_buf` (see below). The `body_buf` is then freed. It is only a temporary landing zone.

**`piece_buf`** is a distinct, longer-lived allocation. It is allocated when a peer claims
a piece (enough space for the full piece, e.g. 512 KB) and freed when the piece either
completes verification or is abandoned. Each peer also has a `next_piece_buf` for the
pipelined next piece. These are the dominant allocation on the download path.

At 100 MB/s with 16 KB blocks:
- `body_buf` alloc/free: ~6,000 per second (one per block received)
- `piece_buf` alloc/free: ~200 per second at 512 KB pieces, ~6,000 at 16 KB pieces

---

## Current allocation audit — data plane

| Site | File | What | Fix |
|---|---|---|---|
| `body_buf` for large messages | `io/peer_handler.zig:625` | `alloc(u8, msg_len)` per message > 16 bytes, freed after `processMessage` | Eliminated by direct-to-piece-buf recv for PIECE; pre-allocated scratch for others |
| `piece_buf` / `next_piece_buf` | `io/types.zig:149,164` | Per-peer piece assembly buffer, one full piece in size | Pool of pre-allocated piece buffers at EventLoop init |
| Per-message send buffer | `io/protocol.zig:470` | `alloc(u8, header + payload)` for outgoing messages > `small_send_capacity` | Scatter-gather send: stack header + existing payload pointer, no copy |
| MSE handshake state | `io/protocol.zig` | `create(MseInitiatorHandshake)` / `create(MseResponderHandshake)` per connection | Embed tagged union in `Peer` struct |
| PEX state | `io/protocol.zig` | `create(PexState)` lazily per peer | Embed in `Peer` struct or pre-allocate parallel array at init |

Everything else on the piece download path — `PieceTracker`, `PieceStore`, `Hasher` —
already has zero runtime allocations.

---

## Current allocation audit — control plane

These paths allocate per-operation but are not latency-sensitive.

| Path | Pattern | Approach |
|---|---|---|
| RPC JSON responses | `ArrayList(u8)` per request, 1 KB – 1 MB | Fixed response arena, reset per request |
| DHT send queue / peer results | `ArrayList` drain per tick | Fixed-size ring buffers |
| ut_metadata fetch buffer | `alloc(u8, metadata_size)` once per fetch | One shared pre-allocated fetch buffer, max 16 MB (BEP 9 cap) |
| Tracker HTTP response parsing | Small `ArrayList` per announce | Stack buffer + bounded arena |
| Metainfo parsing (torrent load) | Arena per session | Already correct; see piece-hash-lifecycle.md for further reduction |
| Extension handshake encoding | Small `alloc` per handshake | Stack buffer (extension message is < 256 bytes) |
| PEX message encoding | `alloc` per PEX send | Pre-allocated PEX encode buffer per peer (already bounded: ≤ 50 peers × 6 bytes) |

---

## Plan

### Stage 1 — eliminate data-plane allocations (high value, low risk)

**1a. Direct-to-piece-buf recv for PIECE messages**

This eliminates both the `body_buf` allocation and the copy for the hottest path.

After the 4-byte header recv completes and `msg_len > 16`, peek at the message ID byte
with a one-byte recv. If `id == 7` (PIECE), read the 8-byte index+begin fields, then
submit the data recv directly into `piece_buf[begin .. begin + block_len]`. No `body_buf`
needed; the block lands in the assembly buffer without a copy.

For all other large messages (BITFIELD, extension handshake, ut_metadata), a small
pre-allocated per-peer scratch buffer of fixed size (e.g. 4 KB, sufficient for all
non-PIECE messages) handles the body recv. PIECE is the only message that approaches
`max_message_length`; all others are control messages bounded to a few KB.

**1b. Piece buffer pool**

Replace `allocator.alloc` for `piece_buf` and `next_piece_buf` with a pool of
pre-allocated piece buffers at `EventLoop.init`. The pool size is
`max_connections × 2 × max_piece_size` (the factor of 2 is for current + next piece
per peer). The existing `PieceBufferPool` in `event_loop.zig` already implements this
for the hasher path — extend it to cover the peer download path as well.

**1c. Embed MSE handshake in Peer struct**

`MseInitiatorHandshake` and `MseResponderHandshake` are allocated once per connection and
freed on disconnect. The `Peer` struct is already statically allocated in the EventLoop's
peer table. Adding a tagged union field:

```zig
const MseState = union(enum) {
    none: void,
    initiator: mse.MseInitiatorHandshake,
    responder: mse.MseResponderHandshake,
};
mse_state: MseState = .none,
```

eliminates the `create`/`destroy` pair without changing any other logic.

**1d. Embed PEX state in Peer struct**

`PexState` is lazily allocated today. Embedding it in `Peer` wastes memory for peers
that never do PEX, but the peer table is already a fixed-size array so the total cost is
`max_connections × sizeof(PexState)` — paid at init regardless. Alternatively, keep it as
an optional pointer but allocate all `max_connections` PexState entries upfront as a
parallel array at EventLoop init.

**1e. Per-peer send buffer (scatter-gather)**

The send path for messages with payload (PIECE, BITFIELD, ut_metadata) currently allocates
a combined header+payload buffer when `total_len > small_send_capacity`. Replace with
io_uring linked SQEs: send the stack-allocated header first, then the existing payload
buffer. For outgoing PIECE messages the payload is already in a piece buffer (from the
hasher or a direct disk read); no copy is needed. For BITFIELD and other variable-length
messages a small pre-allocated per-peer send scratch buffer handles the header framing.

---

### Stage 2 — control-plane bump allocator

Replace per-request `ArrayList` growth with a single arena per EventLoop that is reset
after each RPC request completes. The arena has a hard upper bound (e.g., 8 MB) enforced
at init. If a response would exceed the bound, return a 500 error rather than growing past
the limit.

The same pattern applies to DHT and tracker parsing: a shared scratch arena reset after
each tick, bounded to a few hundred KB.

This does not eliminate dynamic memory — the arena still calls into the allocator at init —
but it eliminates per-operation allocation churn and makes the high-water mark visible
and bounded.

---

### Stage 3 — piece hash lifecycle (see piece-hash-lifecycle.md)

Remove piece hashes from the session for completed torrents. Eliminates the largest
variable-size allocation for seeding boxes. Logically independent of stages 1 and 2 but
compounds with them: a seeding box after stages 1 + 3 pays only:

- Fixed peer table (slots × sizeof(Peer) with embedded MSE + PEX)
- Fixed piece buffer pool (slots × 2 × max_piece_size)
- Metainfo arenas (file list, tracker URLs, layout — no piece hashes)
- RPC/DHT scratch arena (reset per operation)
- io_uring ring buffers (already fixed-size)

---

### Stage 4 — pre-allocated ut_metadata fetch buffer

BEP 9 caps metadata at 16 MB. Allocate one 16 MB buffer at EventLoop init shared across
all in-flight metadata fetches (at most one per torrent at a time). Eliminates the
per-fetch `alloc`.

---

## What cannot easily be made static

**Metainfo string data** (file paths, tracker URLs, announce tiers): these come from the
user and have no fixed upper bound per entry. The arena-per-session approach is the right
model — allocate once on torrent load, never touch again, free on torrent remove. This is
not a hot-path concern.

**RPC responses for very large torrent lists**: a response listing 10,000 torrents with
full detail can reach several MB. The bump-allocator model (stage 2) handles this correctly
with a hard cap and a graceful error if exceeded.

---

## Memory budget after all stages (example config)

500 peers, 100 active torrents, max piece size 2 MB.

| Component | Size |
|---|---|
| Peer table (500 peers × ~4 KB/peer with embedded MSE/PEX) | 2 MB |
| Piece buffer pool (500 peers × 2 buffers × 2 MB max piece) | 2,000 MB |
| Per-peer scratch recv buffer (500 × 4 KB) | 2 MB |
| ut_metadata fetch buffer | 16 MB |
| RPC/DHT scratch arena | 8 MB |
| io_uring ring (4096 entries) | ~4 MB |
| Session arenas (100 torrents, no piece hashes) | ~10 MB (file lists, tracker URLs) |
| **Total** | **~2,042 MB** |

The piece buffer pool dominates because it must cover the worst-case piece size for every
peer simultaneously. In practice, most torrents use 256 KB – 1 MB pieces; at 512 KB the
pool is 500 MB. The pool size should be configurable, and a smaller pool with blocking
acquisition (peers wait for a free buffer) is a valid alternative to avoid over-allocating
for the maximum piece size.

This is still a predictable, startup-time cost with no allocator calls after init on any
data-plane path.

---

## Implementation order

1. **Embed MSE state** in `Peer` — isolated change, no behaviour change, removes two
   `create`/`destroy` sites.
2. **Piece buffer pool** — extend existing `PieceBufferPool` to the peer download path;
   largest reduction in allocator churn.
3. **Direct-to-piece-buf recv** — eliminates `body_buf` alloc and the copy on the PIECE
   path; requires splitting the recv into a 1-byte peek + 8-byte index/begin recv +
   data recv.
4. **Piece hash lifecycle** (stage 3) — independent, large memory win for seeding boxes.
5. **PEX embed / parallel array** — small change, removes a lazy alloc.
6. **Send scatter-gather** — requires io_uring linked SQE plumbing, more involved.
7. **Bump allocator for RPC/DHT** — control-plane cleanup, no data-plane impact.
8. **ut_metadata shared buffer** — last because it requires serialising concurrent fetches.
