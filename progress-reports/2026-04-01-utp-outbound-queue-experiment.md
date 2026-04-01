# 2026-04-01: uTP Outbound Queue Cleanup Did Not Produce A Stable Win

What was done:
- Added two benchmark surfaces to the perf harness:
  - `seed_plaintext_burst` for the real plaintext seed send path through the event loop
  - `utp_outbound_burst` for the real outbound UDP send path
- Prototyped a uTP queue cleanup that removed the extra queue-to-send-buffer copy and replaced `orderedRemove(0)` with index-based queue advancement.

What was learned:
- The uTP cleanup did eliminate allocator churn in the synthetic loopback burst, but that was not the bottleneck on this host.
- The measured latency stayed noisy and roughly flat. That is not enough to justify carrying the extra queue state in production.
- The seed plaintext path still has obvious allocator churn, but the safe production version of scatter/gather needs explicit piece-buffer lifetime management. The benchmark surface is now available for that follow-up.

Measured effect:
- Baseline `utp_outbound_burst --iterations=200 --scale=64`: `81,276,385 ns`, `110,159,182 ns`
- Prototype cleanup runs: `98,260,821 ns`, `112,325,706 ns`, `106,118,442 ns`, `102,549,098 ns`
- The prototype removed allocs in the benchmark, but it did not show a convincing wall-clock improvement.
- `seed_plaintext_burst --iterations=500 --scale=8`: `30,384,358 ns`, `27,940,324 ns`, `28,669,060 ns`, `501` allocs, `65.6 MB` transient bytes

Remaining issues:
- If uTP matters in real swarms, revisit this with a design that can measure a real throughput or latency win, likely multiple in-flight sends or a different receive/send balance.
- If seed plaintext serving becomes hot, use `seed_plaintext_burst` as the A/B surface for a correct `sendmsg` or `sendmsg_zc` implementation.

Code references:
- `src/perf/workloads.zig:418`
- `src/perf/workloads.zig:1135`
- `src/perf/workloads.zig:1620`
