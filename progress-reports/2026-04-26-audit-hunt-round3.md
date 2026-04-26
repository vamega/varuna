# Untrusted-input parser audit hunt — round 3

**Date:** 2026-04-26
**Track:** 1 (`parser-engineer`) — round 3 follow-up to round 1
(`worktree-krpc-hardening`, commit `3108167`).
**Branch:** `worktree-parser-audit-roundN`
**Base:** main HEAD `3108167` plus Track 3's `69c9287`
(`metadata_fetch: parameterise AsyncMetadataFetch over IO backend`).

## Summary

Audited five untrusted-input parsers per the standdown brief: uTP
(`src/net/utp.zig`, `src/net/utp_manager.zig`, `src/io/utp_handler.zig`),
MSE (`src/crypto/mse.zig`), HTTP tracker response
(`src/tracker/announce.zig`, `src/tracker/scrape.zig`), UDP tracker
response (`src/tracker/udp.zig`, `src/daemon/udp_tracker_executor.zig`),
and BEP 9 metadata-fetch network glue (`src/net/metadata_fetch.zig`).
Spot-checked adjacent code paths reachable from the daemon hot path
(`src/net/extensions.zig`, `src/net/pex.zig`, `src/io/http_parse.zig`).

**Critical finding (every-peer-trivial, fixed in-place):**
`src/net/ut_metadata.zig:decode` carried two BT-PIECE-shape
vulnerabilities reachable for every connected peer.

* **Length-prefix overflow** in `skipByteString` (`idx + length`
  computed directly; `length` parsed up to `maxInt(u64)` from the
  literal digit string `"18446744073709551615"`). Triggers
  `panic: integer overflow` in safe builds (Debug / ReleaseSafe).
* **Unbounded recursion** in `skipBencodeValue` (recursed once per
  `l`/`d` byte). With the BEP 10 extension-message ceiling at
  1 MiB (`peer_wire.max_message_length`), a payload of `lll...l`
  would blow the native call stack.

Both paths are entered from `src/io/protocol.zig:handleUtMetadata` —
invoked for *every* BEP 10 ut_metadata extension message a connected
peer sends. Same shape and reachability as the round-1 BT PIECE crash.

**Defense-in-depth fix:** `src/net/utp.zig:SelectiveAck.decode`
accepted a peer-controlled `len ∈ {36, 40, …, 252}` (multiple of 4,
> 32) and panicked the `@memcpy` into the 32-byte `bitmask`. Not yet
peer-reachable because uTP packets currently bypass the SACK
extension chain entirely, but pinned now so it can't regress when
SACK parsing lands.

## Subsystems audited

| Subsystem | Files | Verdict |
|-----------|-------|---------|
| uTP wire codecs | `src/net/utp.zig`, `src/net/utp_manager.zig` | One DoS (SelectiveAck), fixed. Header decode is bounded. |
| uTP receive path | `src/io/utp_handler.zig` | `data_len = @intCast(payload.len)` is u16 from a 1500-byte recv buffer — safe. |
| MSE handshake | `src/crypto/mse.zig` | All `pad_b/c/d_len`, `ia_len`, `pad_c_len` are bounded before use; `remaining_buf` and `ia_buf` are sized to the bound. No findings. |
| HTTP tracker announce | `src/tracker/announce.zig` | Goes through hardened `bencode.parse` + `dictGet` + `expectU32/U64` with explicit overflow rejection. No findings. |
| HTTP tracker scrape | `src/tracker/scrape.zig` | Same surface, same hardening. No findings. |
| UDP tracker | `src/tracker/udp.zig`, `src/daemon/udp_tracker_executor.zig` | Fixed-size structured records (16/20/98 bytes). Each decoder validates `buf.len < N` upfront. `recv_buf[max_response_size = 4096]` keeps `n: usize = @intCast(cqe.res)` safe. No findings. |
| BEP 9 metadata fetch (legacy) | `src/net/metadata_fetch.zig` | Calls `ut_metadata.decode` (now hardened). `msg_len > 1024 * 1024` cap matches `peer_wire.max_message_length`. Slice `msg_buf[2 + meta_msg.data_offset ..]` is now bounds-safe via the hardened scanner. No further findings. |
| BEP 9 ut_metadata wire codec | `src/net/ut_metadata.zig` | **Two production-reachable bugs fixed in-place** (see above). |
| BEP 10 extension handshake | `src/net/extensions.zig` | Already routes through the hardened `BencodeScanner`. Spot-checked: no findings. |
| ut_pex | `src/net/pex.zig` | Goes through `bencode.parse` + `dictGet`. Compact-peer block size is `bytes.len / compact_ipv4_size` (bounded). No findings. |
| HTTP body framing | `src/io/http_parse.zig` | `parseContentLength` uses `parseInt(usize, ...)`. No `+ length` arithmetic; no findings. |

## Bugs found

| # | Subsystem | Severity | Status |
|---|-----------|----------|--------|
| 1 | `ut_metadata.skipByteString` length-prefix overflow | **production-reachable, every-peer-trivial; safe-mode panic** | Fixed in-place (commit `199a0b6`). |
| 2 | `ut_metadata.skipBencodeValue` unbounded recursion | **production-reachable, every-peer-trivial; stack overflow** | Fixed in-place (commit `199a0b6`). |
| 3 | `utp.SelectiveAck.decode` len > 32 byte memcpy panic | Theoretical (decoder not yet wired into hot path); reachable today only via the fuzz harness in `utp.zig:1068` | Fixed in-place (commit `76a7043`). |
| 4 | `ut_metadata.zig` source-side test silently dark | Pre-existing bug surfaced during audit: the `findDictEnd` test asserted `findDictEnd("d1:ai1ee") == 12` for an 8-byte string. Test passed because `src/net/` source-side tests aren't reached through the test hierarchy (Task #7). | Replaced with `decode`-based test that exercises the same invariant through the public surface. |

## Fix shape

The `ut_metadata.decode` rewrite is a textbook
**"replace hand-rolled with hardened-scanner"** transformation. The
inline `findDictEnd` / `skipByteString` / `skipBencodeValue` helpers
were dropped entirely and replaced with a single
`Scanner.skipValue()` call over the
`src/net/bencode_scanner.zig:BencodeScanner` instance. The scanner
already enforces:

* 20-digit cap on length-prefix scans (`parseBytes`)
* 21-char cap on integer scans (`parseInteger`)
* `max_depth = 64` recursion bound on `skipValue`

The `dict_end` boundary used to flag where the trailing raw piece
data starts is now `scanner.pos` after `skipValue` — semantically
identical to the old `findDictEnd` return value but
overflow-safe and depth-bounded by construction.

The `SelectiveAck.decode` fix is the same shape as round 1's
adversarial-length finds: pull out a named constant
(`sack_bitmask_max = 32`), use it for both the array size and the
input cap, and add the explicit `len > sack_bitmask_max` check
*before* the size-of-buffer check so the failure path can't be
sequence-dependent.

## Test coverage

New `tests/ut_metadata_buggify_test.zig` (wired through
`zig build test-ut-metadata-buggify` and rolled into
`zig build test`):

* **ut_metadata.decode random-byte fuzz**: 32 seeds × 1024 random
  buffers (length 0..2048) = 32 768 probes. Asserts panic-free.
* **ut_metadata adversarial corpus (10 tests)**:
  - `maxInt(u64)` length-prefix → `error.InvalidMessage`
  - 21-digit length flood → `error.InvalidMessage`
  - 1024-deep `l` recursion → `error.InvalidMessage`
  - 65-deep `d` recursion → `error.InvalidMessage`
  - truncated input (claimed length > remaining bytes)
  - negative `msg_type` → `error.InvalidMsgType`
  - negative / out-of-u32 `piece` → `error.InvalidMessage`
  - non-dict top-level → `error.InvalidMessage`
  - request / reject / data round-trips (data exercises
    `data_offset` correctness, the production hot path's slice
    indexing relies on it)
* **uTP SACK adversarial probe**: every `len ∈ [0, 255]` against a
  257-byte buffer. Accepted iff `len ∈ {4, 8, 12, …, 32}`. Killer
  inputs (36 and 252) pinned as named regression tests.
* **uTP SACK roundtrip pinning**: every legal `len` in the inline
  `[4, 8, ..., 32]` set round-trips through encode/decode and
  `isAcked`/`setBit`.
* **uTP SACK random-byte fuzz**: 32 seeds × 512 random buffers.

## Test count delta

The `ut_metadata_buggify_test.zig` file adds **17 tests** to the
project suite. No existing tests were removed; the silently dark
`findDictEnd basic cases` test was replaced with an equivalent
public-surface test plus three adversarial-input regression tests
inside `src/net/ut_metadata.zig` itself.

## Validation

* `nix develop --command zig build test` — green at every commit on
  `worktree-parser-audit-roundN`.
* `zig build test-ut-metadata-buggify` — green standalone.
* `zig fmt .` — clean across all touched files.

## Remaining audit surface

* **uTP extension chain not consumed in production**
  (`src/net/utp_manager.zig:85`): when `hdr.extension != .none`, the
  code feeds `data[Header.size..]` into the BT framing layer
  unchanged, treating extension-header bytes as BT message bytes.
  Cosmetic / protocol-correctness bug, not a memory-safety bug — a
  malicious peer can de-sync their own BT stream but cannot crash
  the daemon. **Filed as STATUS.md "Next" follow-up rather than
  fixed in this round** because wiring extension-chain consumption
  cleanly requires touching `processPacket` semantics, which is a
  larger surface than this audit budget allows.
* **uTP reorder buffer indexing mismatch** (`utp.zig:bufferReorder`
  vs `deliverReordered`): the buffer indexes packets by offset from
  `ack_nr+1`, but the deliverer indexes by absolute `seq_nr % 64`.
  Stored entries are unreachable, so the bug currently presents as
  "out-of-order packets are silently dropped at the uTP layer" —
  not a security issue but a correctness issue. **Filed.**
* **uTP reorder buffer slice ownership** (`utp.zig:bufferReorder`):
  the stored `data: []const u8` slice points into
  `event_loop.utp_recv_buf`, which is reused on the next datagram.
  The current indexing-mismatch bug *masks* this UAF — `deliverReordered`
  never actually reads `data` — but it would become a real UAF if
  the indexing bug were fixed without addressing ownership. **Filed
  alongside the indexing fix.**
* **HTTP tracker dictionary-form peer parser**
  (`src/tracker/announce.zig:parsePeerList`): trusts
  `std.net.Address.parseIp(ip, port)` to reject bogus IPs. Spot-check
  shows `parseIp` errors on malformed input cleanly. No findings, but
  worth pinning with a fuzz test in a future round.
* **MSE simultaneous-handshake crash** (deferred per brief).

## Lessons

1. **Audit-pattern-transfer worked again, exactly as round 1
   predicted.** The `i + len` overflow in `skipByteString` and the
   unbounded recursion in `skipBencodeValue` are *the same two bug
   shapes round 1 found in `krpc.zig` and the BT PIECE handler*.
   The fix was even more mechanical: drop the hand-rolled helpers
   entirely and route through the already-hardened
   `BencodeScanner`.
2. **Hand-rolled bencode helpers are technical debt.** Two of three
   bugs this round were in code paths that pre-dated
   `bencode_scanner.zig`. The scanner exists *because* round 1
   found these shapes; the fix is to use it everywhere we parse
   peer-controlled bencode. A targeted `grep -rn "fn skip" src/`
   audit would surface any remaining lookalikes.
3. **Source-side tests can be silently dark.** The `findDictEnd
   basic cases` test asserted a value that was provably wrong, and
   `zig build test` reported green. The test hierarchy issue is
   already filed as Task #7; this audit gives one concrete
   data-loss case to motivate the fix.
4. **Round-1's `BencodeScanner` is already paying interest.** Three
   files (`extensions.zig`, `ut_metadata.zig` post-rewrite, and the
   new round) all share the same overflow-safe length-prefix
   parsing without each carrying its own bug-prone implementation.
   The Pattern #16 / #17 lesson generalises: centralise adversarial-
   input parsing into one hardened helper and the bug count
   collapses.

## Code references

* `src/net/ut_metadata.zig:97-154` — hardened `decode` via Scanner.
* `src/net/utp.zig:78-119` — `sack_bitmask_max` constant and
  `SelectiveAck.decode` cap.
* `tests/ut_metadata_buggify_test.zig` — 17 new tests.

## Commit chain (on `worktree-parser-audit-roundN`)

* `199a0b6 ut_metadata: harden BEP 9 parser via shared bencode_scanner`
* `76a7043 utp: bound SelectiveAck.decode len to bitmask capacity`
* `c026158 tests: BUGGIFY harness for ut_metadata parser + uTP SACK decoder`
