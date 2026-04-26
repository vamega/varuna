# KRPC parser hardening + DHT untrusted-input audit

**Date:** 2026-04-26
**Track:** A (`parser-engineer`) — hardening run on the
correctness-2026-04-26 team
**Branch:** `worktree-krpc-hardening`
**Base:** main HEAD `8f605f3` (post-merge of Stage 4 + DHT BUGGIFY +
recheck followups; tests baseline 620/620)

## Summary

* **A1 — encoder bounds.** `writeByteString`/`writeInteger` (and every
  direct `buf[pos]=...` site in the encoder) rewritten through a new
  `Writer` cursor. Every byte is bounds-checked; encoders return
  `error.NoSpaceLeft` rather than panicking. Closes the bug filed by
  `progress-reports/2026-04-26-stage-4-and-buggify-exploration.md`.
* **A2 — adversarial-input audit on `src/dht/`.** Three real
  vulnerabilities surfaced beyond the encoder finding (length-prefix
  overflow in `parseByteString`, code-clamp overflow in `parseError`,
  digit-flood overflow in the compact peer-list parser inside
  `dht.handleResponse`). All three fixed in-place. One STYLE.md
  violation (recursive `skipValue`) filed as a follow-up rather than
  rewritten under the time budget per pattern #14.
* **A3 — fuzz harness extended.** `tests/dht_krpc_buggify_test.zig`
  grew from 7 tests to 29 (+22 new). Coverage now includes the
  encoder NoSpaceLeft contract (9 encoders), length-prefix overflow
  probes, integer-overflow probes, type-confusion probes, off-by-one
  node-id rejection, txn-id mismatch and short-txn-id paths,
  token-forgery fuzzing, error-code clamping, and a peer-list
  adversarial test that drives the engine end-to-end.
* **Track C** — deliberately deferred in this commit chain;
  out-of-budget once the audit work expanded. Two new audit findings
  filed instead.

## A1 — Encoder bounds checks

### Old shape

`src/dht/krpc.zig` had two low-level helpers:

```zig
fn writeByteString(buf: []u8, data: []const u8) usize {
    var len_buf: [20]u8 = undefined;
    const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{data.len}) catch return 0;
    @memcpy(buf[0..len_str.len], len_str);
    buf[len_str.len] = ':';
    @memcpy(buf[len_str.len + 1 ..][0..data.len], data);
    return len_str.len + 1 + data.len;
}
```

These wrote directly into the slice with no bounds check, panicking
in Debug and triggering UB in Release if `buf` was too small. The
direct `buf[pos] = 'd'` calls scattered through the eight `encode*`
functions had the same bug.

### New shape

A small `Writer` cursor centralises the "every byte goes through a
length check" invariant:

```zig
const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    fn writeByte(self: *Writer, b: u8) EncodeError!void { ... }
    fn writeAll(self: *Writer, data: []const u8) EncodeError!void {
        // Saturating-subtraction form: overflow-safe for any data.len.
        if (data.len > self.buf.len - self.pos) return error.NoSpaceLeft;
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }
    fn byteString(self: *Writer, data: []const u8) EncodeError!void { ... }
    fn integer(self: *Writer, value: i64) EncodeError!void { ... }
    fn dictBegin(self: *Writer) EncodeError!void { ... }
    fn listBegin(self: *Writer) EncodeError!void { ... }
    fn containerEnd(self: *Writer) EncodeError!void { ... }
};
```

All eight encoders (`encodePingQuery`, `encodeFindNodeQuery`,
`encodeGetPeersQuery`, `encodeAnnouncePeerQuery`, `encodePingResponse`,
`encodeFindNodeResponse`, `encodeGetPeersResponseValues`,
`encodeGetPeersResponseNodes`, `encodeError`) now route every write
through the `Writer`. The error type is named `EncodeError = error{NoSpaceLeft}`
so the public signature is precise.

### Test contract

`tests/dht_krpc_buggify_test.zig` adds nine tests of the form:

```zig
test "encoder: encodePingQuery returns NoSpaceLeft on tiny buffers" {
    // probe ok size, then assert every smaller size errors cleanly:
    for (0..ok_len) |i| {
        const result = krpc.encodePingQuery(tiny[0..i], ...);
        try testing.expectError(error.NoSpaceLeft, result);
    }
    // and the exact-size succeeds:
    const exact_len = try krpc.encodePingQuery(exact[0..ok_len], ...);
    try testing.expectEqual(ok_len, exact_len);
}
```

Plus a regression test confirming that valid round-trips still parse
after the rewrite.

## A2 — Audit of `src/dht/` parsing paths

The KRPC parser is the primary surface for adversarial UDP input from
arbitrary internet peers. I read every function that touches
attacker-controlled bytes — `parse`, `parseQuery`, `parseResponse`,
`parseError`, `parseByteString`, `parseInteger`, `skipValue`,
`handleIncoming`, `handleQuery`, `handleResponse`, `handleError`,
`findAndRemovePending`, plus `decodeCompactNode*`, `RoutingTable.addNode`,
and `TokenManager.validateToken` — with adversarial-input eyes.

Findings:

| # | Path | Verdict | Notes |
|---|------|---------|-------|
| 1 | `krpc.parseByteString` length prefix overflow | **Fixed in-place** | `i + len > data.len` overflowed `usize` for adversarial `len`; replaced with saturating-subtraction form `len > data.len - i` and a 20-digit cap on the prefix scan. |
| 2 | `krpc.parseInteger` digit run unbounded | **Fixed in-place** | Capped the digit run at 21 chars (max i64 = 19 digits + sign + slop). Cosmetic — `parseInt` would have errored on overflow regardless — but the bound is faster and clearer. |
| 3 | `krpc.parseError` code overflow | **Fixed in-place** | `@intCast(@max(code, 0))` panicked on `code > maxInt(u32)`. Now clamps both ends: `@intCast(@max(@min(code, maxInt(u32)), 0))`. |
| 4 | `dht.handleResponse` peer-list digit flood | **Fixed in-place** | The IPv4 / IPv6 peer-list parser had `dlen = dlen * 10 + d` and `vpos += dlen` with no bound. Both overflowed `usize` on a `999...:` prefix or a hostile `dlen`. Refactored into a dedicated `parseCompactPeers` helper with a 5-digit length-prefix cap and a saturating-remainder check. Fixes both wire variants in one place. |
| 5 | `krpc.skipValue` recursive | **Filed as follow-up** | Bounded by UDP MTU (~750 nesting depth max; 8 MiB stack accommodates it), but a STYLE.md "no recursion" violation. Rewrite to explicit stack is ~1-2 hours and out of this round's budget. |
| 6 | `krpc.parseQuery` 19/21-byte node ID | **Already safe; pinned with regression test** | `if (id.len != 20) return error.InvalidKrpc` was already present in three places (`id`, `target`, `info_hash`); test added so a future refactor can't drop it silently. |
| 7 | `krpc.handleResponse` for unsolicited txn | **Already safe; pinned with regression test** | `findAndRemovePending` returns `null` for unknown txns, and the handler early-returns *before* any state mutation. Test added. |
| 8 | `findAndRemovePending` short txn-id | **Already safe; pinned with regression test** | The `txn_id_bytes.len != 2` guard correctly rejects 0-, 1-, and 5-byte tids without panicking. Test added. |
| 9 | `TokenManager` token forgery | **Already safe; pinned with regression test** | Across 8 × 512 random forged-token / forged-IP probes, zero false positives. Cross-IP and cross-secret tokens both reject. |
| 10 | `RoutingTable.addNode` adversarial sender_id | Already safe (existing fuzz) | Existing `BUGGIFY: RoutingTable invariants under random insertions` covers ID = 0, ID = 0xFF...FF, near-self IDs. K-bucket invariant holds. |

The recursive `skipValue` finding is the most interesting. The
function is bounded by UDP MTU, so it cannot blow the stack on real
input — but the STYLE.md rule exists because adversarial expansion
of buffer size (e.g. someone building a TCP-framed KRPC variant) would
turn it into a remote crash. Filed in `STATUS.md` "Next" with
specifics; a short-stack rewrite using `std.ArrayListUnmanaged(u8)` as
an explicit container-stack is the canonical pattern.

## A3 — Extended fuzz coverage

### Tests added (`tests/dht_krpc_buggify_test.zig`)

* **Encoder NoSpaceLeft** (9 tests, one per encoder): every encoder
  returns `error.NoSpaceLeft` on every buffer size below the minimum,
  succeeds at the exact size.
* **Length-prefix overflow** (1 test): byte-string with claimed length
  > input size, with `maxInt(usize)`-ish prefix, with 21-digit
  prefix. All return `InvalidKrpc`.
* **Integer overflow probe** (1 test): announce_peer queries with
  21-digit port, negative-21-digit port, and empty integer. All return
  `InvalidKrpc`.
* **Error-code clamp** (1 test): error responses with `code` ≥
  `maxInt(u32)`, `code = -12345`, `code = maxInt(u32)`, and
  `code = maxInt(u32) + 1`. All return a clean `Message.@"error"`
  (clamped) with no panic.
* **Pathological-string-length truncation** (1 test): inputs that
  claim more bytes than remain. Reject cleanly.
* **Type confusion** (1 test): `a` as list, `r` as integer, `e` as
  dict, `y` as zero-length, `y` as multi-byte. All reject cleanly.
* **Node-id off-by-one** (1 test): 19-byte / 21-byte sender_id,
  target, info_hash. All reject cleanly.
* **Round-trip regression** (1 test): canonical ping/response/error
  still encode-then-parse cleanly under the hardened code.
* **Token forgery** (2 tests): random forged tokens against random IPs
  yield zero false positives across 4096 probes; cross-IP and
  cross-secret tokens reject.
* **Adversarial bencode-shaped envelope fuzz** (1 test): 32 × 256
  envelopes built with chosen adversarial bodies (huge lengths, huge
  ints, neg ints, empty ints, truncated bytes, unmatched 'e', dict with
  non-string key, random body). Asserts panic-free; rejection rate
  >50% as a vacuous-pass guard.
* **Compact peer-list adversarial input** (1 test): three
  `Response.values_raw` shapes that previously overflowed `dlen`. The
  test drives the engine end-to-end via `handleIncoming` to exercise
  the actual production path, not just the parser.
* **Unsolicited response is harmless** (1 test): unsolicited ping
  response leaves routing table and send queue unchanged.
* **Short txn-id is harmless** (1 test): 0-byte, 1-byte, 5-byte
  transaction ids all bypass `findAndRemovePending` cleanly.

Test count delta: **+22 tests** (from 7 to 29 in
`dht_krpc_buggify_test.zig`).

Total project tests: **620 → 642** (22 added).

## Validation

* `nix develop --command zig build test` green at every commit.
* `zig fmt` clean across all touched files.
* `zig build test-dht-krpc-buggify` green for the targeted bundle.

## Filed follow-ups

1. **`skipValue` recursion → explicit stack.** STYLE.md violation;
   bounded in production by UDP MTU but unsafe for any future
   TCP-framed KRPC variant. Estimated 1-2 hours. Reference:
   `src/dht/krpc.zig:312`.
2. **Track C — BUGGIFY exploration of one untouched system** (web
   seeds preferred). Time-boxed at 3-4 hours; out of this round's
   budget after the audit expanded into three real bug fixes. Carry
   over.

## Lessons

1. **Pattern #14 (investigation discipline) at the audit shape.** Two
   of the three new bugs (length-prefix overflow in `parseByteString`,
   peer-list digit flood) were found by *reading* the parser, not by
   running fuzz tests. The fuzz harness then *pinned* the fix as a
   regression guard, but the discovery was code-archaeology. The audit
   step is what's institutional; the test is what's mechanical.

2. **Saturating-subtraction is the correct overflow-safe form.**
   `if (i + len > data.len)` is the bug; `if (len > data.len - i)` is
   the fix, given the pre-existing `i <= data.len` invariant. This
   form should be a checklist item in every parser audit.

3. **Centralizing bounds-checks via a small `Writer`/cursor
   abstraction is high-leverage.** Eight `encode*` functions had
   the same bug pattern. One Writer struct fixes them all and makes
   adding new encoders self-correcting (you can't write a byte
   without going through the cursor). Pattern #16's
   panicking-allocator-vtable is the same idea applied to allocation;
   bounds-checked-cursor is the same idea applied to slice writes.

4. **The "audit found three more bugs than the brief named" outcome
   is the typical shape, not the exception.** The brief named the
   encoder bug; the audit found the parser overflow, the peer-list
   overflow, and the error-code clamp on top. Without the audit time
   the encoder fix would have shipped while the latent bugs sat in
   the codebase. Pattern #14 generalizes: the brief is a hypothesis;
   the code is the ground truth.

## Code references

* `src/dht/krpc.zig:271-298` — `parseByteString` length-prefix bound
  + saturating-remainder check.
* `src/dht/krpc.zig:301-318` — `parseInteger` digit-run cap.
* `src/dht/krpc.zig:269-281` — `parseError` u32 clamp.
* `src/dht/krpc.zig:340-410` — `Writer` cursor.
* `src/dht/krpc.zig:412+` — encoders refactored through `Writer`.
* `src/dht/dht.zig:879+` — `parseCompactPeers` extracted with bounded
  digit run + saturating remainder.
* `src/dht/dht.zig:524-535` — `handleResponse` peer-list call sites.
* `tests/dht_krpc_buggify_test.zig` — 15 new tests.

## Commit chain (on `worktree-krpc-hardening`)

* `dht: encoder bounds checks via Writer cursor (closes encoder bounds bug)`
* `dht: parser bounds checks for length prefixes, integer scans, error-code clamp`
* `dht: bounded compact peer-list parser (overflow-safe)`
* `dht: extend BUGGIFY harness with parser/encoder/token coverage`
