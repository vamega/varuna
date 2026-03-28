# Transfer Test Matrix and Pipeline Fix

**Date:** 2026-03-28

## Test Matrix Results

Created `scripts/test_transfer_matrix.sh` — comprehensive transfer verification covering:
- Small files (1KB-64KB) with 16KB and 64KB pieces
- Medium files (100KB-10MB) with 16KB, 64KB, 256KB pieces
- Large files (20MB-100MB) with 64KB and 256KB pieces
- Multi-file torrents (various configurations)

### Results after fixes: 18/18 single-file tests pass

| Category | Tests | Result |
|----------|-------|--------|
| Small (1-64KB) | 4 | All pass |
| Medium (100KB-10MB) | 11 | All pass |
| Large (20-50MB) | 3 | All pass |
| Multi-file | 5 | Skip (seed announce issue) |

## Pipeline Stall Bug (256KB pieces)

**Symptom:** All downloads with 256KB pieces (16 blocks per piece at 16KB block size) would hang after receiving the first 5 blocks.

**Root cause:** `tryFillPipeline()` was only called from `handleSend()` (after a send CQE), not from the piece message handler (after receiving a block). With `pipeline_depth=5`:
1. 5 block requests sent
2. 5 blocks received, `inflight_requests` decremented
3. Nobody calls `tryFillPipeline` → blocks 6-16 never requested

This worked for smaller pieces because all blocks fit in the initial pipeline burst (64KB = 4 blocks < 5 pipeline depth).

**Fix:** Call `tryFillPipeline(slot)` in the piece message handler after decrementing `inflight_requests`, so the pipeline refills as responses arrive.

**Location:** `src/io/event_loop.zig`, piece message handler (msg id 7)

## Multi-file Skip Issue

Multi-file torrent tests skip because the standalone seeder fails to announce. This is likely because `varuna-tools seed` passes the directory path to the tracker announce, but the Session/PieceStore path handling expects a root directory matching the torrent's internal structure. Needs investigation.
