# Quick wins: 4 round-2/3 audit follow-ups closed

Date: 2026-04-27
Branch: `worktree-quick-wins`
Base: `812e104`

Resolved the four short-tail follow-ups filed under the round-2 and
round-3 untrusted-input audits. Each is one bisectable commit. All
green at HEAD.

## Tasks closed

### Task #4 — `krpc.skipValue` explicit-stack rewrite

Commit: `61e8a17 krpc: rewrite skipValue with explicit container stack`

The recursive form at `src/dht/krpc.zig:312` was bounded by UDP MTU
(~750 nesting depth max with the default 8 MiB stack), but a future
TCP-framed KRPC variant or any caller buffering >MTU would expose it
as a remote crash. Replaced with a fixed-size container stack:

```zig
var stack: [skip_max_depth]ContainerKind = undefined;
var depth: u32 = 0;
```

`skip_max_depth = 64`, matching `src/torrent/bencode.zig` and the
sibling `src/net/bencode_scanner.zig`. Same observable behaviour
(rejects beyond depth 64 with `null`), but structurally cannot blow
the native call stack regardless of input size — satisfies STYLE.md's
"no recursion" rule.

The control flow turned out to be the trickiest part. Each iteration
of the main loop needs to:
1. If the innermost container is a dict, peek for `'e'` (close) or
   parse a key.
2. If the innermost container is a list, peek for `'e'` (close).
3. Otherwise dispatch on the next byte: integer / list-open /
   dict-open / byte-string.

I sketched the dispatch as a single `consume:` loop with three small
guarded blocks, mirroring how the recursive form interleaved
"peek-for-close" with "consume one item." Mirrored exactly into
`bencode_scanner.skipValue` (Pattern #17 audit-pattern-transfer).

**Surprise**: I drafted the rewrite using `std.BoundedArray`, which
the team-lead briefing suggested. Zig 0.15.2's stdlib does not export
`std.BoundedArray` from the public root — the compiler's internal
`aro` uses it but it isn't reachable from user code. Hand-rolled the
same shape (`[N]T` + `len: u32`) instead. No semantic difference.

Regression test: `tests/dht_krpc_buggify_test.zig` — 4096-deep `l`
chain inside a real KRPC envelope, expects `error.InvalidKrpc`. If
the recursion bound is removed in the future, this test would
stack-overflow under any normal stack budget.

### Task #10 — `bencode_scanner.skipValue` explicit-stack rewrite

Commit: `89df10c bencode_scanner: rewrite skipValue with explicit container stack`

Same rewrite shape applied to the shared BEP 10 / BEP 9 scanner. The
recursive-with-counter form already had a `max_depth = 64` defensive
bound, so this is purely a structural cleanup — but applying the same
shape uniformly across both parsers (Pattern #17) is the whole point.

The pre-rewrite `depth: u32` field on the scanner is now gone — the
explicit stack is a local in `skipValue`, not scanner state.

Regression test: `tests/bencode_scanner_buggify_test.zig` — 1024+
deep `l` chain, expects `error.InvalidMessage`.

### Task #5 — `web_seed.MultiPieceRange.length` u32 truncation

Commit: `5b63065 web_seed: reject multi-piece runs > maxInt(u32) bytes`

`computeMultiPieceRanges` (`src/net/web_seed.zig:273`/`:303`) wrote
a u64 byte span into the u32 `length` field via `@intCast`, panicking
on runs > 4 GiB. Production today is bounded by the
`web_seed_max_request_bytes` config knob (default 4 MB), so it never
fires in normal operation — but a misconfigured value (e.g.
`web_seed_max_request_bytes = 8 GiB`) crashes the daemon on the first
multi-piece request. One config typo, one DoS vector.

**Investigation (Pattern #14)**: the team-lead briefing offered two
fix shapes — (a) widen `length: u64` and ripple, or (b) clamp `count`
upstream. Reading downstream callers in `src/io/web_seed_handler.zig`
showed:

- `MultiPieceRange.length` is **never read** by the production
  handler. The handler uses `range_start`, `range_end`, `buf_offset`,
  `file_index` — the byte count is implicit in `range_end -
  range_start + 1`.
- The rest of the pipeline is u32-byte-bounded: `WebSeedSlot
  .total_bytes: u32`, `MultiPieceRange.buf_offset: u32`,
  `target_offset: u32`, the `run_buf` allocation is u32.

Widening `length` to u64 would force ripple changes through several
fields that nothing reads, and break the consistent u32 byte-count
discipline. The cleaner fix: validate at function entry, return
`error.RunTooLarge`. Same outcome a misconfigured cap deserves —
caller fails the request and surfaces a config error to the operator
rather than crashing the daemon.

Regression test: `tests/web_seed_buggify_test.zig` — 65 × 64 MB
pieces (4.0625 GiB run) expects `error.RunTooLarge`; 16 × 64 MB
(1 GiB run) verifies the happy path is unbroken.

### Task #9 — BT PIECE block_index regression test

Commit: `7e13b8e protocol: regression test for BT PIECE block_index u16 cast`

Round-3 hardening at `src/io/protocol.zig:166-178` shipped without an
inline regression test because `src/io/` source-side tests were dark
in `mod_tests` at the time. Round-1 dark-test audit subsequently
landed `src/io/root.zig`'s `test {}` block, so inline tests in
`src/io/protocol.zig` now run.

Added two inline tests using the existing `setupTestPeer` /
`setupTestTorrent` helpers:
1. `block_offset = 1 GiB` (= 65536 × 16384) — the exact pre-fix
   panic value where `block_index_u32 = maxInt(u16) + 1`.
2. `block_offset = maxInt(u32)` — the absolute upper bound of the
   wire field, the most hostile input the protocol can express.

Both verify `processMessage` returns cleanly without panic;
`piece_buf` untouched; `blocks_received` unchanged. No production
code changes — the fix shipped already; this just pins it.

## Test count delta

Baseline at `812e104`: ~1203 tests passing (1 pre-existing flaky
sim-eventloop test that flickers between
`recheck_test.AsyncRecheckOf(SimIO)` and
`sim_smart_ban_phase12_eventloop_test.phase 2B` depending on seed —
unrelated to my changes).

Post-quick-wins: ~1208 tests passing.

- +1 `bencode_scanner_buggify_test`: deeply-nested `l` chain
- +1 `dht_krpc_buggify_test`: 4096-deep KRPC list
- +1 `web_seed_buggify_test`: misconfigured-cap regression
- +2 `src/io/protocol.zig`: 1 GiB block_offset, maxInt(u32) block_offset

## Methodology notes

- **Pattern #15 (read existing invariants)**: I read both
  `bencode_scanner.skipValue` (with its `max_depth = 64` recursion
  bound) and the recursive `krpc.skipValue` before drafting either
  rewrite. The shared shape made it a copy-paste-adjust task instead
  of a "design two explicit-stack APIs" task.

- **Pattern #14 (investigation discipline)**: the web_seed fix
  decision turned on reading downstream callers, not on guessing
  which option was simpler. Once I confirmed `length` is unused, the
  entry-validation form was obviously cleanest.

- **Pattern #17 (audit-pattern-transfer)**: `krpc.skipValue` and
  `bencode_scanner.skipValue` share the same algorithmic shape. Both
  rewrites use the same `ContainerKind` enum, the same fixed-size
  stack, the same `consume:` loop with the same dict-key-or-close
  guard. Diverging APIs would be a future maintenance burden.

- **Pattern #8 (bisectable commits)**: 4 commits, one per task. Each
  compiles cleanly and passes `zig build test` independently.

## Surprises

1. **`std.BoundedArray` is not exported from the Zig 0.15.2 public
   stdlib.** The compiler's internal `aro` uses it but it isn't
   reachable from user code. Hand-rolled the same shape. The
   team-lead briefing suggested using it — flagging here for future
   briefings.

2. **`MultiPieceRange.length` is dead in production.** I went into
   Task #5 expecting to either widen u32→u64 or clamp count, both of
   which would have rippled downstream. The grep showed `range.length`
   is never read by the handler. Validation-at-entry was the
   minimal-disturbance fix.

3. **The flaky sim-eventloop test flickers.** First run hit
   `recheck_test`; second run hit `sim_smart_ban_phase12_eventloop_test
   .phase 2B`; later runs were green. Both are pre-existing flakes;
   neither is caused by these changes (they don't touch sim-eventloop
   code paths).

## Key references

- `src/dht/krpc.zig:318-413` — explicit-stack `skipValue`
- `src/net/bencode_scanner.zig:106-181` — same shape, generic over
  ErrorSet
- `src/net/web_seed.zig:262-271` — the `error.RunTooLarge` validation
- `src/io/protocol.zig:1557-1650` — the two new regression tests
- `tests/dht_krpc_buggify_test.zig:202-237` — 4096-deep KRPC test
- `tests/bencode_scanner_buggify_test.zig:152-172` — 1024+ deep test
- `tests/web_seed_buggify_test.zig:373-422` — misconfigured-cap test
