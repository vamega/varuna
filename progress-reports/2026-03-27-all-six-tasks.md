# Completed: All Six Priority Tasks

**Date:** 2026-03-27

## Tasks Completed

### 1. Fix send buffer leak in seed servePieceRequest
- Allocated single buffer for complete piece message (header + data)
- Tracked in `pending_sends` list, freed when send CQE completes
- Fixed context=1 flag in user_data for tracked sends

### 2. Multi-piece multi-file real swarm test
- Verified with 1KB/4 pieces, 64KB/4 pieces, 1MB/64 pieces
- All sizes pass with correct data verified by `cmp`
- Progress reporting works: 1%, 3%, ... 100%

### 3. Test daemon end-to-end via varuna-ctl add
- Daemon starts, accepts API requests
- `varuna-ctl add` triggers TorrentSession creation
- Session downloads, verifies, transitions to seeding
- `varuna-ctl list` shows state=seeding, progress=1.0

### 4. Peer request timeout
- 30-second timeout per peer based on last_activity timestamp
- Updated on: connect, unchoke, piece data received
- Timed-out peers removed, pieces released to pool
- Seed peers exempt

### 5. UDP tracker support (BEP 15)
- Full connect + announce protocol over UDP via io_uring
- Auto-detection: fetchAuto() selects HTTP or UDP by URL scheme
- URL parsing for udp://host:port/path

### 6. Choking algorithm (tit-for-tat)
- Recalculate every 30 seconds
- Sort interested peers by bytes_downloaded_from
- Unchoke top 4 + 1 optimistic, choke the rest
- Per-peer upload/download byte tracking

## Key Fix: Hasher Drain Loop

The most subtle bug was the hasher drain timing. When the download completes (all pieces received from network), the hasher threadpool may still be computing SHA-1 hashes. The pending disk write CQEs haven't arrived yet. Without draining:
1. Download loop exits because `isComplete()` or `peer_count == 0`
2. EventLoop deinit runs, but hasher results haven't been processed
3. piece_buf leaks because it was handed to the hasher but never freed

Fix: after main loop exits, repeatedly poll `processHashResults()` and `tick()` until all `pending_writes` are cleared. Sleep between polls to give the hasher time.

## Stats

102 commits, 9,056 lines of Zig.
