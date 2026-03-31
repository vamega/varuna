# Async Merkle Tree Building for BEP 52

## What was done

Removed the 4096-piece limit and synchronous disk I/O from the BEP 52 Merkle tree
building path. Previously, `handleHashRequest` in `src/io/protocol.zig` read piece
data from disk and computed SHA-256 hashes inline on the event loop thread, blocking
for large files and rejecting files with more than 4096 pieces.

The fix offloads all disk reads and SHA-256 hashing to the existing Hasher threadpool
(`src/io/hasher.zig`), keeping the event loop non-blocking.

### Key changes

- **`src/io/hasher.zig`**: Added `MerkleJob` and `MerkleResult` types. Worker threads
  now handle Merkle tree building jobs alongside piece verification. The worker reads
  piece data via `pread` and computes SHA-256 hashes for every piece in a file's range.
  Results delivered through a separate queue (`drainMerkleResultsInto`), sharing the
  same eventfd wake mechanism. (`processMerkleJob`: line ~351, `submitMerkleJob`: line ~140)

- **`src/torrent/merkle_cache.zig`**: Added pending request tracking with coalescing.
  `addPendingRequest` returns whether a build job needs to be submitted (true for first
  request, false for subsequent requests to the same file). `takePendingRequests`
  collects all waiters when the build completes. `removePendingRequestsForSlot` cleans
  up when a peer disconnects. (lines ~103-150)

- **`src/io/protocol.zig`**: `handleHashRequest` now uses the async path. Cached tree
  hits are still served immediately (no change). For uncached files, the request is
  queued and a Merkle job submitted to the hasher. The synchronous `buildPieceHashesFromDisk`
  function was removed entirely. (line ~612)

- **`src/io/peer_policy.zig`**: Added `processMerkleResults` which runs each tick,
  drains completed Merkle results, builds and caches trees, and serves all pending
  requests (or sends hash rejects on failure). Disconnected peers are silently skipped.
  (line ~358)

- **`src/io/event_loop.zig`**: Added `merkle_result_swap` buffer, wired
  `processMerkleResults` into the tick loop, added Merkle cache cleanup to `removePeer`.

## What was learned

- Zig 0.15's `std.AutoHashMap` is a managed type (allocator at init, no `.empty`).
  For small sets, `std.ArrayList` with linear scan is simpler and avoids API mismatches.

- The Hasher's shared mutex/condvar pattern works well for adding new job types.
  Merkle jobs and piece verify jobs share the same queue_cond, so workers wake for
  either type. Merkle jobs are checked first since they are less frequent but higher
  value (one job serves multiple peers).

- v2 pieces are always file-aligned (exactly 1 span per piece), so the Merkle job
  worker thread logic is simpler than the general v1 multi-span case.

## Tests added

- `hasher.zig`: "merkle job hashes file pieces from disk" -- creates a temp file,
  submits a Merkle job, verifies SHA-256 hashes match.
- `hasher.zig`: "merkle job returns null hashes on bad fd" -- verifies graceful
  failure with invalid file descriptor.
- `merkle_cache.zig`: "merkle cache pending request tracking" -- tests addPendingRequest
  coalescing and takePendingRequests.
- `merkle_cache.zig`: "merkle cache pending request removal on disconnect" -- tests
  removePendingRequestsForSlot.
- `merkle_cache.zig`: "merkle cache coalesces multiple peers requesting same file" --
  verifies 4 peers coalesce into 1 build job.

## Remaining issues

- The Merkle job reads piece data using blocking `pread` on the hasher worker thread.
  This is acceptable (worker threads are background threads, not the event loop), but
  for very large files the single job holds up one worker thread for a while. A future
  optimization could split large files into per-piece jobs that run in parallel across
  the pool.

- No integration test yet for the full async round-trip (peer sends hash request,
  event loop submits job, hasher builds tree, event loop serves response). The unit
  tests cover each component independently.
