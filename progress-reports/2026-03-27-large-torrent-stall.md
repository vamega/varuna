# Large Torrent Download Stalls

**Date:** 2026-03-27
**Status:** Known issue, root cause identified

## Symptom

Downloads work for up to ~1MB (64 x 16KB pieces) but stall for larger torrents (5MB+, 320+ pieces). The file is pre-allocated at the correct size but contains zeros.

## Root Cause

The seed's `servePieceRequest` (event_loop.zig:~700) does a **blocking `posix.pread`** to read piece data from disk. For each block request (16KB), it reads the entire piece from disk synchronously. This blocks the seed's event loop for the duration of the disk read.

For small torrents (1MB, 64 pieces), the reads are fast (data in page cache). For larger torrents, the reads become slower and the seed can't keep up with the download's request pipeline. The download pipeline fills up, stops getting responses, and eventually the peer timeout fires.

## Fix

Replace `posix.pread` in `servePieceRequest` with io_uring `IORING_OP_READ`. This requires:
1. Submit a read SQE for the piece data
2. When the read CQE completes, build the piece message and submit a send SQE
3. Track the async state (which slot, which piece, which block)

This is the same pattern as the download side's `completePieceDownload` -> hasher -> processHashResults -> disk write chain, but in reverse (disk read -> build message -> send).

## Workaround

For now, larger torrents with larger piece sizes work better because:
- Fewer total pieces = fewer `servePieceRequest` calls
- But each piece has more blocks, so the blocking read per-request is still an issue

The real fix is async disk reads in the seed path.

## Verified Working

- 29 bytes / 1 piece: OK
- 1KB / 4 x 256B pieces: OK
- 64KB / 4 x 16KB pieces: OK
- 1MB / 64 x 16KB pieces: OK
- 1000 bytes / 4 x 256B multi-file: OK

## Failing

- 5MB / 5 x 1MB pieces: stalls (30s timeout)
- 5MB / 320 x 16KB pieces: stalls (60s timeout)
- 10MB / 640 pieces: stalls
- 100MB / 800 pieces: stalls
