# Strace Blocking Call Audit

**Date:** 2026-03-27
**Status:** Audit complete, remaining items documented

## Methodology

Ran `strace -f -c -e trace=read,write,pread64,pwrite64,io_uring_enter,futex,...` on both seed and download sides during 5MB transfers.

## Eliminated

| Call | Where | Fix Applied |
|------|-------|-------------|
| `futex` (98% of time) | Hasher threadpool condvar spinning in seed mode | Skip hasher for seed (hasher_threads=0) |
| `futex` (high rate) | Hasher condvar 100ms timeout waking threads idle | Increased to 1s timeout |

## Remaining Blocking Calls (TODO)

### 1. `pread64` in seed's servePieceRequest
**File:** `src/io/event_loop.zig:servePieceRequest` (~line 710)
**Impact:** Low per-call (page cache), but blocks event loop for ~2ms per 64KB piece read.
**Fix:** Replace with `IORING_OP_READ` (async pread via io_uring). Requires async state machine:
submit read SQE → on CQE, build piece message → submit send SQE.

### 2. `posix.write(eventfd)` in hasher worker threads
**File:** `src/io/hasher.zig:workerFn` (~line 178)
**Impact:** Negligible (8 bytes, instant). But technically a blocking write.
**Fix:** Could use `IORING_OP_WRITE` on the eventfd, but the worker threads don't have a ring. Not worth fixing -- the write is essentially free.

### 3. `posix.read(eventfd)` in processHashResults
**File:** `src/io/hasher.zig:drainResults` (~line 128)
**Impact:** Negligible. Non-blocking fd returns EAGAIN when empty.
**Fix:** Could poll eventfd via `IORING_OP_READ` on the event loop ring. Low priority.

### 4. `pwritev(stdout)` for progress/status logging
**File:** `src/torrent/client.zig:logStatus` (~line 447)
**Impact:** Negligible. Infrequent status messages.
**Fix:** Not needed. Logging is not hot path.

### 5. `pread64` during startup recheck
**File:** `src/storage/verify.zig:recheckExistingData` via PieceStore
**Impact:** One-time at startup. Uses io_uring Ring wrapper (pread_all).
**Note:** This already goes through io_uring. The strace shows it as pread64 because the Ring's blocking wrapper does submit+wait per operation. Not a problem since recheck runs before the event loop.

## Priority Order for Remaining Fixes

1. **Seed async pread** (#1 above) -- blocks event loop, affects throughput for multi-block pieces
2. Everything else is negligible and not worth fixing
