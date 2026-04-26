# src-tests Bit-Rot Cleanup (Task #9) — 2026-04-26

Followup to Task #6's deeper finding: Zig 0.15.2's test-discovery
mechanism requires `test { _ = X; }` from a test-context import to pull
in inline `test "..."` blocks; `pub const X = @import(...)` is not enough.
Pulling the subsystems in via the proper pattern unblocks **+249 source-
side tests** that were silently uncovered, surfaces 2 production bugs
that had drifted (one double-deinit, one uninitialized-memory access),
and fixes ~10 stale test expectations to match current production logic.

## Test count progression

| Milestone | Test count |
|---|---|
| Pre-Track-A (current main, `507c6bd`) | 223/223 |
| After Track A (piece hash lifecycle + 15 dedicated tests) | 238/238 |
| After Task #6 (5 unwired test files brought into `test_step`) | 262/262 |
| After Task #9 (subsystem `test { _ = ... }` blocks + bit-rot fixes) | **511/511** |

**+288 net tests since Track A merge base.** Stable across 5 back-to-back runs.

## What landed

### Discovery + STYLE.md note

The empirically-verified gotcha (failing-test injection in
`src/crypto/rc4.zig` doesn't run despite `src/crypto/root.zig`'s
`test { _ = ... }` block — because `src/root.zig` doesn't pull crypto
into a test context) is now documented in STYLE.md "The Test Hierarchy"
so future subsystem authors don't repeat the assumption-trap.

### Mechanical compile-error fixes (mostly bit-rot)

* `src/crypto/mse.zig` — `std.posix.socketpair` removed in Zig 0.15;
  added local `testSocketPair` helper wrapping `std.os.linux.socketpair`
  syscall. Three call sites updated.
* `src/crypto/sha1.zig` — switch on `Accel` enum needed exhaustiveness:
  added `.undetected => return error.TestUnexpectedResult` arm.
* `src/torrent/metainfo.zig` — `files: []File` → `[]const File`. Production-
  clean; production code never mutates the slice contents post-parse.
  Unblocks test struct literals using `const` array → slice coercion.
* `src/torrent/blocks.zig`, `src/torrent/file_priority.zig`,
  `src/torrent/layout.zig` — added missing `.comment = null` field to
  `Metainfo` struct literals (the `comment` field was added 2026-04-25).
* `src/torrent/bencode.zig` — `_ = err;` no longer valid for discarding
  error sets; rewrote loop body to use explicit `catch continue`.
* `src/torrent/piece_tracker.zig` — `tracker.completePiece(0, 4)`
  return value (`bool`) needs explicit discard via `_ =`.
* `src/config.zig` — 9 instances of `const cwd = ...openDir()` →
  `var cwd = ...` so `cwd.close()` (which now requires `*Dir`) compiles.
* `src/app.zig` — 2 inline tests rewritten to use new
  `std.Io.Writer.Allocating` API (the `GenericWriter.interface` field
  was removed in Zig 0.15).

### Production bug fixes (surfaced by re-enabled tests)

* **`src/torrent/merkle_cache.zig:buildAndCache`** — double `tree.deinit()`
  on `error.MerkleRootMismatch`: both an `errdefer tree.deinit()` AND
  an explicit `tree.deinit()` fired on the same value, causing
  `MerkleTree.deinit` to free already-freed `layers` → SIGABRT.
  Removed the explicit deinit; let `errdefer` cover the cleanup.
  Surfaced by `merkle cache rejects wrong root` test once it actually
  ran.

* **`src/storage/manifest.zig:build`** — function-level `errdefer`
  iterated `files[0..layout.files.len]` reading `file.relative_path.len`
  on uninitialized memory when an early span failed validation. Fix:
  track an `initialized: usize` counter, errdefer iterates only
  `files[0..initialized]`. Surfaced by `reject path traversal
  components in torrent paths` test once it actually ran.

### Stale test expectations updated to match production

* `torrent.bencode.test.reject deeply nested lists` — production added
  depth check; updated to expect `error.NestingTooDeep` (was
  `UnexpectedEndOfStream`).
* `torrent.bencode.test.reject deeply nested dicts` — depth limit
  applies to dicts too; switched from `try parse` to `expectError`.
* `torrent.blocks.test.split large pieces` — fixed `pieces` length
  to match `total_size / piece_length` (was off by 2 hashes).
* `torrent.create.test.create single file torrent and parse it back` —
  expected `totalSize == 43` but actual file is 42 bytes; updated.
* `torrent.layout.test.map piece across multiple files` — expected
  `piece2.len == 2` (beta+gamma) but production correctly maps
  piece 2 entirely within gamma (1 span). Updated.
* `torrent.magnet.test.reject invalid hex characters` — input was 41
  chars (wrong length), failed with `InvalidInfoHashLength` before the
  hex check. Updated to exactly 40 chars to reach the validation.
* `torrent.metainfo.test.parse multi file torrent metainfo`,
  `torrent.session.test.load multi file torrent session`,
  `storage.manifest.test.build manifest for multi file torrent` — all
  three had identical bencode `eee` trailing-data issue; trimmed one
  trailing 'e'.
* `torrent.metainfo.test.reject non-dictionary torrent root` —
  `info_hash.findInfoBytes` now runs before bencode parse and rejects
  with `UnexpectedByte` instead of `UnexpectedBencodeType`.
* `torrent.metainfo.test.parse url-list as string` / `url-list as list`
  / `parse httpseeds` — bencode length prefixes mismatched URL
  lengths (e.g. `25:` for 26-char URL). Updated each to match.
* `torrent.piece_tracker.test.wanted mask skips unwanted pieces` —
  expected `null` from a third `claimPiece` call; production endgame
  mode correctly returns a duplicate in-progress piece for retry.
  Updated to allow either of the two wanted pieces.

## Subsystems pulled in via `src/root.zig`

```zig
test {
    _ = bitfield;
    _ = crypto;
    _ = torrent;
}
```

Crypto's `test { _ = ... }` block in `crypto/root.zig` was already
correct — just needed top-level reach via `_ = crypto;`. Torrent gets
its own `test { _ = ... }` block in `torrent/root.zig`. Bitfield is
referenced directly since it's a single-file module.

Storage, dht, net, io, runtime, sim, tracker, rpc, daemon are pulled
in transitively via the closure of crypto + torrent imports. No
additional `_ = subsystem;` needed (verified empirically: adding them
explicitly didn't change the test count).

## Subsystems left out (filed as Task #10 follow-up)

`app` and `config` were attempted last — their compile errors are
fixed in this commit (so the per-file tests are clean), but pulling
them in via `_ = app; _ = config;` triggers a *separate* comptime-
evaluation error in `src/io/io_interface.zig:392` (a comptime check
on `Operation`/`Result` union tags becomes runtime-evaluated when
these modules join the test compilation). Likely a Zig 0.15.2
quirk around test-context-vs-non-test-context evaluation order;
needs investigation. The mechanical test fixes are landed so
re-enabling is a one-line change in `src/root.zig` once the
comptime issue is understood.

## Files touched

| File | Reason |
|---|---|
| `STYLE.md` | Add Zig 0.15 test-discovery note to "Test Hierarchy" section. |
| `src/root.zig` | Add `test { _ = bitfield; _ = crypto; _ = torrent; }` block. |
| `src/torrent/root.zig` | Add `test { _ = ... }` listing all 15 torrent modules. |
| `src/crypto/mse.zig` | `testSocketPair` helper + 3 call-site updates. |
| `src/crypto/sha1.zig` | Add `.undetected` arm to switch. |
| `src/torrent/metainfo.zig` | `files: []const File`; trim trailing 'e' in test input; update non-dict-root error expectation; URL-list length-prefix fixes; httpseeds length-prefix fix. |
| `src/torrent/bencode.zig` | Discarded-err pattern fix; depth-error expectations updated. |
| `src/torrent/blocks.zig` | `.comment = null` (×2); pieces length fix. |
| `src/torrent/create.zig` | totalSize expectation 43 → 42. |
| `src/torrent/file_priority.zig` | `.comment = null` (×3). |
| `src/torrent/layout.zig` | `.comment = null` (×10); piece-2 mapping expectation update. |
| `src/torrent/magnet.zig` | hex-test input length 41 → 40. |
| `src/torrent/merkle_cache.zig` | **PRODUCTION**: remove redundant `tree.deinit()`. |
| `src/torrent/piece_tracker.zig` | `_ = tracker.completePiece(...)`; endgame-claim expectation update. |
| `src/torrent/session.zig` | Trim trailing 'e' in test input. |
| `src/storage/manifest.zig` | **PRODUCTION**: track `initialized` counter for errdefer; trim trailing 'e' in test input. |
| `src/config.zig` | `const cwd` → `var cwd` (×9). |
| `src/app.zig` | Migrate 2 inline tests to `std.Io.Writer.Allocating`. |

## What was learned

1. **Zig 0.15.2 test discovery is non-obvious**. The `test { _ = ... }`
   pattern in subsystem root files looked correct but was decorative
   without top-level reach. Empirical verification (failing-test
   injection) is the only reliable way to confirm tests are running.
   Documented in STYLE.md so future authors don't repeat the
   assumption-trap.

2. **Bit-rotted tests can hide real production bugs**. Two production
   bugs (merkle_cache double-deinit, manifest errdefer UAF) had been
   silently shielded for an unknown duration because the tests that
   would trip them weren't running. Re-enabling exposed both
   immediately. The audit's value compounds: each newly-running
   test is now a guard against future regressions.

3. **"Tests live next to the code" works**. With the test-discovery
   gap fixed, source-side `test "..."` blocks exercise their sibling
   code without test-file boilerplate. ~250 tests (mostly in torrent
   + crypto) now run on every `zig build test` instead of being
   silently dead.

4. **Some test failures are stale expectations, not bugs**. Most of
   the runtime failures fixed here were tests whose expectations
   pre-dated production drift (different error type returned, off-by-
   one in length count, structural change in how pieces map across
   files). These are *test maintenance* issues, not production
   regressions. The shape of the fix — read the failure, look at
   what production currently returns, decide if the production
   behavior is correct (it usually is), update the test expectation
   to match — is worth codifying as a habit.

## Follow-up filed (Task #10)

Re-enable `_ = app;` and `_ = config;` in `src/root.zig` once the
comptime-eval issue in `io_interface.zig:392` is understood. The
per-test fixes are already landed; just needs the one-line
re-enable plus the comptime fix. Estimated 30 minutes once the
diagnosis is clear.
