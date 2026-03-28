# Async Pread Implementation and Data Corruption Issue

**Date:** 2026-03-28

## Async Pread (Option B) - Implemented

Replaced blocking `posix.pread` in `servePieceRequest` with `IORING_OP_READ`.

Flow:
1. Block request received
2. Check piece cache → hit: send immediately, miss: submit io_uring read SQE
3. Read CQE completes → update cache → `sendPieceBlock`

Results:
- 10 pieces × 64KB: works instantly
- 100 pieces × 64KB (6.4MB): 1 second
- 1200 pieces × 16KB (19MB): 4 seconds (no corruption)

## Data Corruption at ~17MB with 64KB Pieces

**Symptom:** 300+ pieces at 64KB, file diverges at byte ~17,629,185 (piece 269 boundary). First ~260 pieces are correct.

**Not the cause:**
- Same data volume with 16KB pieces (1200 pieces, 19MB): works perfectly
- async pread itself: 100 pieces at 64KB works

**Suspected cause:** Something in the multi-block download assembly or the pending_sends tracking when handling 300+ pieces with 4 blocks each (1200 block responses). Possible race in CQE completion order or buffer lifetime.

**Next steps:**
1. Compare SHA-1 hashes of each piece between seed and download to find which piece is corrupted
2. Check if the corruption is in the piece data or in the wrong piece being written to the wrong offset
3. Investigate pending_sends tracking for buffer lifetime issues with many concurrent sends

## Option C TODO

Batch all block responses for a piece into one send. Instead of 4 separate sends (one per block), build one buffer with all 4 piece messages concatenated. This reduces io_uring overhead 4x and eliminates the per-block send/CQE cycle.
