# DNS Thread Pool Queue Size Evaluation

**Date:** 2026-04-05
**Context:** Concurrent TrackerExecutor refactor (async event loop)

## Background

The DNS threadpool backend (`src/io/dns_threadpool.zig`) uses a bounded ring buffer
of 16 slots for pending DNS jobs, processed by 4 worker threads. When the queue is
full, `DnsQueueFull` is returned as a hard error (no retry). This evaluation was
prompted by the TrackerExecutor refactor from a single serial worker to an async
event loop with up to `max_concurrent` in-flight requests, which increases
concurrent DNS demand.

## Analysis

With the new TrackerExecutor configuration:
- **max_concurrent = 8** (default): up to 8 request slots active simultaneously
- Each slot performs at most one DNS lookup at a time (via `resolveAsync`)
- Maximum concurrent DNS submissions from tracker executor: **8**

DNS thread pool capacity:
- 4 worker threads actively resolving
- 16-slot pending queue
- **Total capacity: 20 concurrent DNS requests** (4 active + 16 queued)

Other DNS callers:
- `resolveOnce()` for UDP tracker (infrequent, ~1 concurrent)
- DHT bootstrap bypasses DNS module entirely (uses `std.net.getAddressList` directly)

**Worst case: 8 executor slots + 1 UDP tracker = 9 concurrent DNS submissions.**
This is well within the 20-request capacity. Even assuming all requests are cache
misses (cold start), the queue cannot overflow.

After the initial burst, the DNS cache (5-minute TTL, 64 entries) absorbs most
lookups. Tracker hostnames are reused across torrents, so even 1000 torrents
typically resolve to a few dozen unique hostnames.

## Options Evaluated

| Option | Pros | Cons | Verdict |
|--------|------|------|---------|
| Keep 16-slot queue | Simple, sufficient for N=8 | Could overflow if N>12 | **Chosen** |
| Increase to 64 slots | More headroom, cheap (384 bytes) | Masks real problems (broken cache, dead DNS) | Not needed |
| Block caller when full | No hard failures | Cascading stalls if DNS is slow | Worse behavior |
| Dynamic ArrayList | Unbounded | No backpressure, over-engineering | Not needed |

## Decision

**Keep the 16-slot bounded queue as-is.** No changes to `src/io/dns_threadpool.zig`.

The hard `DnsQueueFull` error is preferable to silent blocking because:
1. It surfaces DNS infrastructure problems quickly
2. Tracker announce failures are retried at the next announce interval (30-60 min)
3. It prevents cascading stalls where blocked workers can't serve cache-hit requests

## Future Considerations

If `max_concurrent` is ever raised above 12, the DNS pool should be resized
proportionally (both worker count and queue depth). The relationship is:
`max_concurrent` should be ≤ `dns_queue_size + dns_worker_count - margin`.
