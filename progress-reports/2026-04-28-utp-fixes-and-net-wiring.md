# uTP correctness fixes + net test wiring — 2026-04-28

Branch: `worktree-utp-fixes`. Four bisectable commits.

Closes three follow-ups filed during prior audits:

1. uTP reorder buffer indexing mismatch + dangling-slice UAF
   (`progress-reports/2026-04-26-audit-hunt-round3.md`).
2. uTP extension chain not consumed in production (same audit).
3. Wire `src/net/bencode_scanner.zig` + `src/net/web_seed.zig`
   inline tests (`progress-reports/2026-04-27-dark-test-audit-r2r3.md`).

`zig build test`: green at HEAD.

## 1. Reorder buffer indexing mismatch + slice-ownership UAF

### Before

`src/net/utp.zig:bufferReorder` indexed by *offset from `ack_nr+1`*:

```zig
const offset = seqDiff(seq, self.ack_nr +% 1);
if (offset <= 0 or offset >= max_reorder_buf) return;
const idx: usize = @intCast(@as(u16, @intCast(offset)) % max_reorder_buf);
self.reorder_buf[idx] = .{ .seq_nr = seq, .data = data, .present = true };
```

`deliverReordered` indexed by *absolute `seq_nr % max_reorder_buf`*:

```zig
const next_seq = self.ack_nr +% 1;
const idx: usize = @intCast(next_seq % max_reorder_buf);
if (!self.reorder_buf[idx].present or self.reorder_buf[idx].seq_nr != next_seq) break;
```

Trace: ack_nr=5, packet seq 8 arrives.

* bufferReorder: offset = 8-6 = 2; stored at idx 2.
* Later seq 6 arrives in-order; ack_nr → 6. deliverReordered loop:
  next_seq = 7, idx = 7 % 64 = 7. `reorder_buf[7].present` is false.
  Break. Returns count=0. Seq 7 and 8 are both still in the buffer
  but the deliverer never finds them.

So out-of-order packets were silently dropped — every uTP swarm
saw retransmits whenever a packet got reordered, and the BT framing
layer never recovered any state across the gap.

The compounding bug: `data` was a borrowed `[]const u8` slice into
`event_loop.utp_recv_buf` (`src/io/event_loop.zig:240` — a fixed
1500-byte buffer reused on every datagram). The next datagram
arrived and overwrote the buffer. With the indexing bug masking
the deliverer, this UAF was never actually triggered. But fixing
the indexing bug alone would have converted every out-of-order
delivery into a read of stale recv-buffer bytes.

### After

Both methods index by absolute `seq_nr % max_reorder_buf`.
`bufferReorder` allocates and copies the payload into per-slot
owned storage; the prior occupant (if any) is freed first so a
duplicate retransmit at the same slot doesn't leak. `deliverReordered`
transfers ownership from `reorder_buf[idx].data` to
`UtpSocket.delivered_payloads[count]`, marks the slot empty, and
emits the slice through `ProcessResult.reorder_data[count]`. The
slices remain valid until the next `deliverReordered` call on the
same socket, after which the previous batch is freed. `deinit` cleans
up both `reorder_buf` and `delivered_payloads`.

The `(0, max_reorder_buf)` offset bound on `bufferReorder` stays:
without it, a peer could send seq=ack_nr+64 to alias an in-window
slot via the modular indexing.

Production wiring: `PacketResult` now carries `reorder_data` and
`reorder_delivered` (the slices reference per-socket storage that
`UtpManager.processPacket` extracts before any `freeSlot`).
`src/io/utp_handler.zig` iterates and feeds each slice into
`deliverUtpData` immediately after the in-order packet — so the
production daemon now actually delivers reordered uTP packets to
the BT framing layer. On socket teardown (`.closed`/`.reset`)
`processPacket` clears `reorder_data` before `freeSlot` to avoid
dangling references.

### Tests (inline in `src/net/utp.zig`)

- "reorder buffer delivers buffered packets when gap is filled":
  buffer seq 8 and 7, then seq 6; assert reorder_delivered == 2,
  ack_nr advances to 8, content matches.
- "reorder buffer delivers reverse-ordered burst with correct content":
  seq 5, 4, 3, 2 buffered then seq 1; full content check
  PKT2/PKT3/PKT4/PKT5 in the right order.
- **"reorder buffer survives utp_recv_buf reuse (UAF regression)"**:
  the exact UAF scenario from the audit. Buffer seq 2 with payload
  "ORIGINAL" stored in a 16-byte buffer; mutate the buffer to
  "GARBAGE!" (simulating the next datagram); send seq 1 also reusing
  the buffer; assert the delivered seq 2 content is "ORIGINAL", not
  "GARBAGE".
- "reorder buffer delivers across multiple bursts without slot
  collision": two consecutive bursts that share `% 64` index slots,
  testing.allocator catches any leak.
- "reorder buffer slot eviction frees prior occupant": duplicate
  retransmit at the same slot; assert the latest copy wins and
  no leak.
- "reorder buffer fills 63 slots and delivers cleanly": full-window
  stress (the (0, 64) bound caps inclusive at 63).
- "reorder buffer deinit frees pending slots without leak": socket
  destroyed with reorder slots still occupied.
- "reorder buffer rejects out-of-window seq numbers": seq=ack_nr+69
  must not displace the legitimate ack_nr+5 entry that shares its
  modular slot.

Test-first protocol: a minimal failing test was committed first
(`14b1a5b net/utp: failing test for reorder buffer indexing
mismatch`) showing `expected 2, found 0` on the broken code. Then
the fix (`9ed7200`) lands the full eight-test suite and turns the
suite green.

## 2. uTP extension chain not consumed in production

### Before

`src/net/utp_manager.zig:85` (paraphrased):

```zig
const payload = if (data.len > Header.size) data[Header.size..] else &[_]u8{};
```

When `hdr.extension == .selective_ack`, the SACK extension
header (2 bytes) and bitmask (4..32 bytes) sit at the front of
`payload`. The manager passed the whole thing through to
`sock.processPacket`, which treated it as the BT framing layer's
input. So a peer sending a uTP DATA packet with a SACK extension
followed by 4 BT keepalive bytes would have its BT framing layer
read 6+ bytes of SACK header + 4 BT bytes and mis-frame the
keepalive (probably leading to a multi-MB nonsense `length`
prefix and a peer disconnect on `max_message_length`).

This isn't a memory-safety bug — the SelectiveAck.decode bound
fixed in commit `76a7043` already prevented out-of-bounds memcpy.
It's a protocol-correctness bug: a malicious peer can desync their
own BT stream but cannot crash the daemon.

### After

`processPacket` now calls `stripExtensions(hdr.extension, raw_payload)`
which walks the BEP 29 chain `(next_ext: u8, len: u8, [len]u8)*`
until a `next_ext == .none` terminator and returns the trailing
slice. Each iteration consumes ≥2 bytes (the per-extension header),
so the loop is bounded by `payload.len / 2` — no explicit iteration
cap is needed.

For `.selective_ack` specifically, `stripExtensions` rejects per-extension
`len > sack_bitmask_max` (32). This matches the bound on
`SelectiveAck.decode` from commit `76a7043` and prevents a peer
from sneaking a 252-byte SACK past as a generic-skip extension.

Truncated chains (`remaining.len < 2 + ext_len`) are rejected with
`null`; the manager drops the malformed datagram cleanly.

### Tests (inline in `src/net/utp_manager.zig`)

- "stripExtensions: no extension passes payload through"
- "stripExtensions: SACK extension is consumed before BT bytes"
- "stripExtensions: multi-hop chain consumes every extension"
  (selective_ack → unknown type 7 → none, with trailing BT bytes)
- "stripExtensions: truncated extension is rejected"
- "stripExtensions: missing per-extension header is rejected"
- "stripExtensions: SACK len > sack_bitmask_max is rejected"
- "stripExtensions: chain bounded by datagram length"
- **"manager processes SACK + BT keepalive correctly through full
  pipeline"**: end-to-end. SYN handshake, then DATA packet with
  `hdr.extension == .selective_ack`, SACK chain (next=none, len=4,
  [4]u8 bitmask), 4 zero BT keepalive bytes. Assert the BT layer
  receives only the 4 zero bytes — not 6 bytes (SACK header +
  keepalive) and not 10 bytes (SACK header + bitmask + keepalive).
- "manager rejects datagram with truncated extension chain"

## 3. Wire `bencode_scanner` + `web_seed` test discovery

`src/net/root.zig`'s `test {}` block now includes both files. The
round-2/3 dark-test audit had deferred them because
quick-wins-engineer was modifying them in parallel; their refactors
have since landed.

Test count delta: ~25 inline tests now reachable (9 in
`bencode_scanner.zig` + 16 in `web_seed.zig`).

Verification per the standard protocol:

- `bencode_scanner.parseBytes decodes bencoded string` —
  inserted `try testing.expect(false)`, ran `zig build test`,
  runner caught with the correct test name. Reverted.
- `web_seed.web seed manager init and deinit` — same.

## Test count delta

Inline tests added in this round:

- `src/net/utp.zig`: +8 reorder buffer regression tests.
- `src/net/utp_manager.zig`: +9 extension chain regression tests.
- Wired `bencode_scanner.zig` + `web_seed.zig`: +~25 already-existing
  tests now reachable.

Total ~42 new inline tests reachable through `mod_tests`. `zig
build test`: green.

## Validation

```
$ nix develop --command zig fmt .       # clean
$ nix develop --command zig build       # clean, daemon binary builds
$ nix develop --command zig build test  # green (one self-resolving
                                          flake of the pre-existing
                                          sim_smart_ban flake on
                                          first run, green on retry)
```

The daemon binary compiles (`zig build` produces
`zig-out/bin/varuna`). The `PacketResult` struct grew by ~1 KB
(the `[64]?[]const u8` reorder_data array). All callers compile
cleanly because the new field has a default initializer.

## Code references

- `src/net/utp.zig:78-119` — `sack_bitmask_max` constant and
  `SelectiveAck.decode` cap (unchanged from `76a7043`, but the
  same `sack_bitmask_max` is now also enforced in
  `UtpManager.stripExtensions`).
- `src/net/utp.zig:172-173` — `pub const max_reorder_buf = 64`
  (now `pub` so `utp_manager.zig` can size its `reorder_data`
  array against it).
- `src/net/utp.zig:213-225` — `ReorderEntry` (now owns its `data`).
- `src/net/utp.zig:264-280` — `UtpSocket.delivered_payloads` /
  `delivered_count`.
- `src/net/utp.zig:284-299` — `UtpSocket.deinit` cleans up both
  buffers.
- `src/net/utp.zig:401` — `result.reorder_delivered =
  self.deliverReordered(&result)` (now writes through `result`).
- `src/net/utp.zig:684-723` — `bufferReorder` + `deliverReordered`
  rewrite.
- `src/net/utp.zig:733-746` — `ProcessResult.reorder_data`.
- `src/net/utp_manager.zig:84-100` — `stripExtensions` invocation
  in `processPacket`.
- `src/net/utp_manager.zig:101-126` — `PacketResult` extraction
  with `reorder_data` cleared before `freeSlot`.
- `src/net/utp_manager.zig:283-318` — `stripExtensions` helper.
- `src/net/utp_manager.zig:351-362` — `PacketResult.reorder_data`.
- `src/io/utp_handler.zig:212-225` — drain loop in handler.

## Lessons

1. **Pattern #14 (test-first) for the reorder bug worked exactly
   as the team-lead's brief predicted.** Committing the failing
   state-only test first (`14b1a5b`) made the bug observable
   before any fix code was written. The first run printed
   `expected 2, found 0` from `result.reorder_delivered`, which
   is the smoking gun: the deliverer can see zero buffered
   packets where two existed. The fix (`9ed7200`) lands with
   confidence that the test was actually exercising the bug,
   not coincidentally passing for some unrelated reason.

2. **Pattern #15 (read existing invariants).** The `(0, 64)`
   offset bound on `bufferReorder` is not redundant after the
   indexing fix — without it, a peer could send seq=ack_nr+64
   to alias the slot at `ack_nr+0 % 64` and overwrite a
   legitimate in-window entry. The "rejects out-of-window seq
   numbers" test pins this.

3. **Two coupled bugs hide each other.** The indexing mismatch
   masked the UAF — the deliverer never read the stale slice,
   so the borrowed-buffer bug never triggered. The audit's
   "filed alongside the indexing fix" framing was correct: a
   test that fixes only the indexing would convert a silent drop
   into a use-after-free, which is strictly worse. Pattern is
   the same as round 1's "if you fix this without that, you
   make it worse" finds.

4. **Production data flow can be incidentally broken even after
   the layer-local fix.** Even with the reorder buffer correct,
   `result.reorder_delivered` was a count with no payload
   surface. Wiring the slices through `ProcessResult` →
   `PacketResult` → `deliverUtpData` was the actual delivery
   that the count was meant to represent. The audit identified
   the silent-drop symptom; the underlying flow was missing
   too.

## Filed follow-ups

None. The brief explicitly scoped this round to three tasks; no
new audit surface was opened. The remaining "Next" entries on
STATUS.md (e.g. uTP outbound queueing, multishot recv,
dynamic OutPacket buffer) are independent improvements not
surfaced by this work.

## Commit chain (on `worktree-utp-fixes`)

* `14b1a5b net/utp: failing test for reorder buffer indexing mismatch`
* `9ed7200 net/utp: fix reorder buffer indexing + slice ownership`
* `873ff44 net/utp_manager: walk and strip extension chain before BT framing`
* `1b6cfd1 net: wire bencode_scanner + web_seed into net/root.zig test discovery`
