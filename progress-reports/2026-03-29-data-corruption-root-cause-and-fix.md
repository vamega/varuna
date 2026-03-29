# Data Corruption: Root Cause Analysis and Fix

**Date:** 2026-03-29
**Supersedes:** 2026-03-28-async-pread-and-corruption.md (which documented the symptom but not the fix)

## The Problem

The transfer test matrix showed intermittent data mismatches. Tests passed individually but failed 70% of the time when run in sequence. The original symptom was corruption at ~17MB with 64KB pieces, but the root cause affected all piece sizes under certain timing conditions.

## Root Causes (Three Bugs)

### Bug 1: Hasher TOCTOU Race Condition (PRIMARY)

**Location:** `src/io/hasher.zig` — `drainResults()` + `clearResults()`

The event loop called `drainResults()` to get completed hash results, processed them, then called `clearResults()`. Between these two calls, a worker thread could:
1. Dequeue a job from the queue
2. Complete the hash
3. Append the result to `completed_results`

When `clearResults()` ran, it wiped ALL results including the one just appended — that piece was never written to disk.

**Fix:** Replaced `drainResults()` + `clearResults()` with an atomic `drainResultsInto()` that swaps the result list with a caller-owned buffer under the lock. Added `in_flight` atomic counter to track jobs being processed by worker threads.

**Why intermittent:** Depends on exact timing between hasher worker threads and event loop tick. More likely with many pieces (more hash jobs) and fast peers (shorter window between piece completion and drain).

### Bug 2: Incomplete Drain Loop (SECONDARY)

**Location:** `src/torrent/client.zig` — drain loop after download completes

When all pieces were received from the network but the hasher was still verifying the last few, the download loop exited because `peer_count == 0` (seeder disconnected). The drain loop was supposed to wait for remaining hashes and writes, but it used an arbitrary 50-iteration grace period with `sleep(10ms)` that was often insufficient.

**Fix:** Restructured the drain loop to use `hasher.hasPendingWork()` and `pending_writes.count()` to wait until ALL in-flight work completes. The event loop keeps ticking (processing hash results and disk write CQEs) even after peers disconnect.

**Why intermittent:** Depends on whether the last piece hash completes within the 500ms grace window (50 × 10ms). Fast CPUs usually win; loaded systems lose.

### Bug 3: Broken Inline SHA-1 Fallback (LATENT)

**Location:** `src/io/event_loop.zig` — `completePieceDownload()` else branch

The fallback path (used when hasher thread creation fails) computed SHA-1 but:
- Never compared the hash to the expected value
- Never wrote the piece to disk via io_uring
- Leaked the piece buffer

**Fix:** Added proper hash comparison, disk write submission, and buffer ownership tracking.

**Why not caught earlier:** The hasher threadpool always succeeded in tests, so this path was never exercised. Would bite users on systems where thread creation fails (resource limits, containers).

## Additional Hardening (Not Yet Merged)

Four additional fixes were identified but couldn't be cleanly cherry-picked:

1. **timeout_pending tracking** — prevents SQE accumulation from repeated `submitTimeout` when previous timeout hasn't completed
2. **Write error checking in handleDiskWrite** — checks `cqe.res` for disk errors instead of blindly marking pieces complete
3. **Endgame duplicate write skip** — avoids double PendingWrite entries when two peers complete the same piece in endgame mode
4. **c_allocator in tools** — Zig's GPA debug allocator fills freed memory with 0xAA, which exposed a latent use-after-free in io_uring buffer lifecycle

## Key Lessons

### 1. Drain + Clear is an antipattern for concurrent queues
Separating "read results" from "clear results" into two operations creates a window where producers can add items that get cleared without being consumed. Always use atomic swap (drain-into) or consume-and-remove-one-at-a-time.

### 2. Grace periods are unreliable
`sleep(N)` loops for waiting on async work are fragile. Always use explicit completion tracking (counters, flags) instead of time-based assumptions. The hasher's `hasPendingWork()` combined with `in_flight` counter is the correct approach.

### 3. Test reliability reveals real bugs
The test matrix's 70% failure rate was NOT a test infrastructure problem (though port cleanup helped). It was real data integrity bugs. Running tests many times in sequence is valuable for finding timing-dependent issues.

### 4. Fallback paths need testing
The inline SHA-1 path was completely broken but never caught because the happy path (hasher threadpool) always worked. Consider forcing fallback paths in tests.

## Verification

After fixes:
- Transfer test matrix: 24/24 pass
- 5 consecutive runs with ReleaseSafe: 5/5 pass (0 failures)
- Previous failure rate: 7/10 runs had at least one data mismatch
