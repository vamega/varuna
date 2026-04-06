# 2026-04-05: Codebase Review Fixes, DHT Persistence, and Bootstrap Speedup

## Overview

Two comprehensive code reviews were conducted (6 agents each), identifying
45 issues across security, performance, protocol, organization, robustness,
and testing. 23 issues were fixed. Additionally, DHT persistence was
implemented and cold bootstrap was optimized from 3-5 minutes to ~1 second.

## What Was Done

### Code Review Fixes (Round 1 — 16 items)

All critical and high items from the first review were fixed in one commit:

**Security:**
- u32 overflow in `block_offset + block_length` seed request validation → u64 arithmetic
- Max block_length capped at 128 KiB on incoming REQUESTs
- Bencode parser: max nesting depth (64) and max container elements (500K)

**Memory safety:**
- Disk write error: defers buffer free until all io_uring spans complete
- Background announce thread joined on shutdown (was detached → use-after-free)
- `announce_result_peers` handoff protected by mutex (was non-atomic pointer race)

**Correctness:**
- `removeBitfieldAvailability()` called on peer disconnect (counters only grew)
- `completePiece` clears `in_progress` bit (scan_hint and endgame were broken)
- CANCEL message (id=8) handler added with `cancelQueuedResponse()`
- Choking algorithm: tit-for-tat for both download and seed mode, 10s interval, optimistic unchoke rotation
- Keep-alive messages sent after 90s inactivity

**Performance:**
- TCP_NODELAY on all peer sockets (eliminated Nagle's 40ms delay)
- io_uring COOP_TASKRUN + SINGLE_ISSUER flags (with kernel fallback)
- `send_pending` gate removed from `tryFillPipeline`
- Pending disk writes flushed on shutdown

### Code Review Fixes (Round 2 — 7 items)

**Security:**
- Config TOML use-after-free: `load()` now returns `LoadedConfig` that owns the parse tree

**Protocol:**
- BITFIELD validation: length check, spare-bits check, bad peers disconnected
- UNCHOKE after CHOKE: calls `tryFillPipeline` to resume interrupted piece

**Robustness:**
- `startPieceDownload` errdefer cleans up piece_buf on failure
- Multi-file write skips fd=-1 for do_not_download files
- SO_RCVBUF 2MB / SO_SNDBUF 512KB on all peer sockets

**Testing:**
- Shell scripts (`demo_swarm.sh`, `test_transfer_matrix.sh`) rewritten for daemon + varuna-ctl

### Testing Additions (134 new tests)

| File | Tests | Coverage |
|------|-------|----------|
| `protocol.zig` | 23 | All message types: choke, unchoke, have, bitfield, piece, cancel |
| `peer_policy.zig` | 17 | Unchoke algorithm, timeouts, keep-alive, piece promotion |
| `handlers.zig` | 31 | Parameter extraction, JSON serialization, torrent info |
| `auth.zig` | 15 | Session store edge cases, header extraction |
| `bencode.zig` | 5 | Nesting depth limits, container element limits |
| `piece_tracker.zig` | 2 | completePiece clearing in_progress |
| `adversarial_peer_test.zig` | 73 | Rewritten: real malformed input through bencode, KRPC, extensions |

### Architecture: Standalone Download Path Removed

Deleted `src/torrent/client.zig` (1161 lines) — the separate event loop that
duplicated daemon functionality without DHT, PEX, WebAPI, or session management.
All downloads now go through the daemon. `varuna-tools` retains only offline
utilities: `inspect`, `verify`, `create`.

### DHT/PEX Runtime Toggles

- Config: `[network] dht = true/false`, `pex = true/false`
- API: `POST /api/v2/app/setPreferences` with `dht=true` or `pex=false`
- CLI: `varuna-ctl set-pref dht false`

### UDP Tracker Timeout (BEP 15)

The UDP tracker path had no recv timeout — lost packets blocked the tracker
executor thread forever. Fixed with SO_RCVTIMEO and retry with exponential
backoff (15 × 2^n seconds, n=0..3). After 4 failures, returns `TrackerTimeout`.

### DHT Multi-Torrent Fix

Two bugs prevented reliable multi-torrent DHT discovery:
1. Retrigger mechanism created duplicate lookups, filling all 16 slots
2. `requestPeers()` was only called after tracker announce (7+ min for UDP timeouts)

Fixed with per-hash search state tracking and early DHT registration in the
main loop (before tracker finishes).

### DHT Persistence

Routing table persisted to `~/.local/share/varuna/dht.db` (separate from
resume DB — can be deleted independently). On shutdown, saves all nodes and
the node ID. On restart, loads them and skips DNS bootstrap.

- Uses `PRAGMA synchronous = OFF` and `journal_mode = MEMORY` since DHT data
  is ephemeral (worst case: cold bootstrap ~1s)
- Cold start: 103 nodes saved → loaded in milliseconds on next start
- Warm start: DHT immediately ready, no bootstrap round-trips

### Cold Bootstrap Speedup (3-5 min → 1s)

- Two parallel `find_node` lookups: own ID + random ID (doubles discovery rate)
- Full fan-out: queries K=8 candidates instead of alpha=3 during bootstrap
- Routing table reaches 100+ nodes within seconds

## What Was Learned

### Ubuntu Tracker Limitation
`torrent.ubuntu.com` returns exactly 1 peer in announce responses regardless
of client, numwant, or frequency. The scrape endpoint reports 2200+ seeders
but they are not returned to clients. DHT is the only way to find Ubuntu peers.

### DHT Timing Is Critical for Multi-Torrent
When adding multiple torrents simultaneously, the first ones to complete their
tracker announce get DHT lookups immediately. Torrents with slow/broken trackers
(UDP timeout) were starved because `requestPeers()` was deferred until after
the tracker finished. Early registration in the main loop fixed this.

### Zorin OS Torrent
All 10 trackers returned 0 peers. DHT `get_peers` completed but found 0 peers.
The torrent appears to have no active seeders in either the tracker network or
the DHT. This is not a varuna bug.

## Benchmark Results

| Torrent | Speed | Peers | Source |
|---------|-------|-------|--------|
| Debian ISO (790 MB) | 12-17 MB/s | 920+ | Tracker |
| Linux Mint ISO (3 GB) | 10-11 MB/s | 40 | Tracker + DHT |
| Ubuntu ISO (5.7 GB) | 5-8 MB/s (DHT) | 10-45 | DHT only (tracker gives 1) |
| Zorin OS ISO (3.8 GB) | 0 | 0 | Dead swarm |

## Code References

- Review results: `opus_review_results.md`
- Config lifetime fix: `src/config.zig:90-135` (LoadedConfig)
- DHT persistence: `src/main.zig:95-175`, `src/dht/dht.zig:87-112` (export/load)
- Bootstrap speedup: `src/dht/dht.zig:665-700` (parallel lookups + full fan-out)
- UDP tracker retry: `src/tracker/udp.zig:40-90` (SO_RCVTIMEO + exponential backoff)
- E2E test: `scripts/test_e2e_downloads.sh`
