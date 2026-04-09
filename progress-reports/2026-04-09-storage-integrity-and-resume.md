## What Was Done

- Reworked `ResumeWriter` to own its allocator and flush by swapping the pending batch out under the mutex, so pieces recorded during a SQLite flush are no longer lost when the writer clears the queue.
- Expanded `ResumeDb.clearTorrent()` into a real torrent-scoped cleanup operation: it now deletes piece completions, transfer stats, category/tag assignments, rate/share limits, v2 hash mappings, tracker overrides, and queue-position rows in one transaction.
- Tightened `verifyPieceBuffer()` for v2 multi-piece files so it fails closed with `error.DeferredMerkleVerificationRequired` instead of accepting arbitrary piece payloads without a Merkle proof.
- Added coverage for the broader `clearTorrent()` contract and updated the v2 multi-piece verification test to assert the new fail-closed behavior.

## What Was Learned

- The original `ResumeWriter.flush()` race was not about SQLite thread safety; it was about queue ownership. Taking a pointer to `pending.items`, unlocking, and later clearing the array meant new completions could disappear even if the DB write itself succeeded.
- `clearTorrent()` had drifted from its name: it only deleted piece rows, while the rest of the torrent-specific resume state survived in adjacent tables. That kind of partial cleanup is easy to miss because many call sites were compensating manually.
- The storage layer should not "optimistically succeed" on v2 multi-piece verification. If the Merkle proof is unavailable, the correct behavior is to defer trust, not silently accept the bytes.

## Remaining Issues / Follow-Up

- This change closes the obvious storage-side fail-open behavior, but it does not yet implement a full download-time acceptance path for pure-v2 multi-piece pieces. That belongs in the torrent-core / BEP 52 follow-through work.
- `zig build test` passed after these storage changes. The focused `zig build test-torrent-session` step still has the separate host-level Zig cache issue (`manifest_create Unexpected`).
- Wave 2 should next address torrent layout semantics, pure-v2 piece-hash APIs, tracker concurrency behavior, and protocol-side v2 correctness.

## Verification

- Ran `zig fmt src/storage/resume.zig src/storage/verify.zig src/daemon/torrent_session.zig`
- Ran `zig build test` successfully

## Key References

- `src/storage/resume.zig:403`
- `src/storage/resume.zig:1146`
- `src/storage/resume.zig:1169`
- `src/storage/resume.zig:1272`
- `src/storage/verify.zig:161`
- `src/storage/verify.zig:457`
- `src/daemon/torrent_session.zig:788`
- `src/daemon/torrent_session.zig:985`
- `src/daemon/torrent_session.zig:1747`
