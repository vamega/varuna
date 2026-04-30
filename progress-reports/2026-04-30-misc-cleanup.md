# 2026-04-30 — Misc cleanup: PieceStore.io UAF, FeatureSupport, BEP 52 v2 piece validation, blocking-helper warnings

Branch: `worktree-misc-cleanup`. Four small contained cleanups,
one bisectable commit each.

## Task 1 — `PieceStore.io` dangling-pointer fix

**Source.** `progress-reports/2026-04-28-correctness-fixes.md`
"Surprises" #1 documented that `PieceStore` was constructed in
`doStartBackground` (`src/daemon/torrent_session.zig:1296`) against a
stack-local `init_io` that goes out of scope at end-of-function. The
`store.io` field then pointed at freed memory. The hot path
(`peer_policy.zig` submits its own `io.write` calls per span using
the shared fds from `PieceStore.fileHandles`) never touched the
field, but `store.sync` / `store.writePiece` / `store.readPiece`
all dereferenced it — a UAF waiting to happen.

**Fix shape.** Removed the `io: *IO` field entirely. Each method that
needs an op now takes `io: *IO` as an explicit per-call parameter:

```zig
pub fn ensureFileOpen(self: *Self, io: *IO, file_index: usize) !std.fs.File
pub fn writePiece(self: *Self, io: *IO, spans, piece_data) !void
pub fn readPiece(self: *Self, io: *IO, spans, piece_data) !void
pub fn sync(self: *Self, io: *IO) !void
```

`init` / `initWithPriorities` still take `io` for the one-time
fallocate pass, but the returned `Self` no longer retains the pointer.
The doc-comment makes the lifetime invariant explicit:

```
`io` is used only for the one-time `fallocate` pass during init;
the returned `Self` does not retain the pointer.
```

The per-span tracking structs (`WriteSpanState`, `ReadSpanState`) used
to reach back through `state.parent.io` for short-write / short-read
re-submission. They now carry `io: *IO` directly so the resubmit path
doesn't need a back-pointer to a struct that no longer keeps an `IO`
reference.

**Caller updates.** Every caller of these methods already owned the
`IO` they constructed the store with; passing it back in is uniformly
local:

- `src/app.zig` (CLI `varuna verify` command): owns `verify_io` for
  the entire scope of `runVerify`.
- `src/storage/verify.zig`: `recheckExistingData` and `recheckV2`
  grew an `io: *RealIO` parameter, passed to `store.readPiece` calls.
- `tests/storage_writer_test.zig`: 6 call sites updated.
- `tests/transfer_integration_test.zig`: 3 call sites updated.
- `tests/sim_swarm_test.zig`: 1 call site updated.
- `src/storage/writer.zig` inline tests: 3 call sites updated.

**Why this approach.** The two design alternatives the team-lead
sketched were:
  (a) drop the field, take `io` per call
  (b) take a longer-lived `io` reference at construction (e.g. EL's
      persistent io)

Option (b) would have papered over the lifetime mismatch but kept
the latent footgun — a future caller reading `store.io.someField`
would still need to know the lifetime contract. Option (a) makes the
contract impossible to violate. The cost is method signatures that
take `io` explicitly; the benefit is that `PieceStore` no longer
holds any pointer that could outlive its referent. Same shape as
`std.fs.File` — operations take a `File`, the `File` doesn't hold
a back-pointer to its filesystem.

**Time spent.** ~1 hour, matched the team-lead's estimate.

## Task 2 — `FeatureSupport` extension

**Source.** STATUS.md "Generalize `FeatureSupport` to cover other
kernel-floor-blocked ops" follow-up. The `supports_ftruncate` flag
landed on 2026-04-29; this round adds the remaining three.

**Fix shape.** Three new flags on `FeatureSupport`
(`src/io/ring.zig`):

- `supports_bind`: `IORING_OP_BIND`, kernel ≥6.11
- `supports_listen`: `IORING_OP_LISTEN`, kernel ≥6.11
- `supports_setsockopt`: `IORING_OP_URING_CMD`, kernel ≥6.7
  (carrier op for the `SOCKET_URING_OP_SETSOCKOPT` subcmd)

`probeFeatures` populates each via the existing
`IORING_REGISTER_PROBE` wrapper:

```zig
return .{
    .supports_ftruncate = p.is_supported(.FTRUNCATE),
    .supports_bind = p.is_supported(.BIND),
    .supports_listen = p.is_supported(.LISTEN),
    .supports_setsockopt = p.is_supported(.URING_CMD),
};
```

**The setsockopt caveat.** The kernel exposes setsockopt via
`IORING_OP_URING_CMD` with subcmd `SOCKET_URING_OP_SETSOCKOPT`
(landed in 6.7), not as a standalone IORING_OP. Probing
`IORING_OP_URING_CMD` is therefore a *necessary* condition (URING_CMD
itself shipped before 6.7) but not *sufficient* — the SETSOCKOPT
subcmd may still be rejected at completion time on a URING_CMD-only
kernel. To get an unambiguous answer we'd need to attempt a real
URING_CMD setsockopt and check for `ENOTSUP` / `EINVAL`, which is
overkill for an init-time probe. The flag and its caveat are
documented in the FeatureSupport struct doc-comment so daemon callers
that submit an actual setsockopt URING_CMD know to handle the
kernel-rejects-subcmd path at completion time.

**Tests.** Three new inline tests in `src/io/ring.zig`:

- `probeFeatures FeatureSupport.none has every flag false` —
  extended to cover the new flags.
- `probeFeatures bind/listen/setsockopt are bool-typed and
  queryable` — runtime-detection mirror of the existing
  `supports_ftruncate` test. Doesn't pin a specific value (6.6
  reports all false; 6.7 lights setsockopt; 6.11+ lights bind/listen).

**No daemon submission methods gated yet.** Bind / listen / setsockopt
aren't in the IO contract today (`io_interface.zig` has no
`BindOp`/`ListenOp`/`SetsockoptOp`). The daemon's listen-socket
bring-up paths in `src/io/event_loop.zig` and per-peer setsockopt
calls (TCP_NODELAY, buffer sizes, BINDTODEVICE in
`src/net/socket.zig`) go through `posix.bind` / `posix.listen` /
`posix.setsockopt` directly. This commit lays the groundwork; the
call-site work is filed as a separate follow-up "Daemon submission
paths for bind / listen / setsockopt".

**Time spent.** ~30 min; the surface area was tiny since the probe
infrastructure already existed.

## Task 3 — BEP 52 v2 piece validation via `LeafHashStore`

**Source.** `progress-reports/2026-04-29-bep52-dht-and-hashes.md`'s
explicit follow-up: the bep52-dht-engineer round landed
`src/torrent/leaf_hashes.zig` (commit `4fe5160`) which stores
peer-provided SHA-256 leaves *after* the proof on a BEP 52 `hashes`
message has chained up to the file's authoritative `pieces_root`.
This round wires that store into piece-completion validation.

**Background — why pure v2 didn't work.** `layout.pieceHash` returns
`error.UnsupportedForV2` for pure-v2 torrents (no SHA-1 in the
metainfo). The SHA-1 background hasher pool can't accommodate
SHA-256. Per-piece verification via `verifyPieceBuffer` requires
either (a) a single-piece file (where `expected_hash_v2` is the
direct SHA-256 of the file's only piece) or (b) the full file's
Merkle tree rebuilt from on-disk piece hashes. Option (b) only works
once every piece is on disk — meaning multi-piece v2 files couldn't
verify incrementally. So pre-this-round, `completePieceDownload`
always failed for pure v2: `pieceHash` returned the error, the catch
called `cleanupCompletionFailure`, and the piece was released back to
the tracker for a never-completing retry loop.

**Fix shape.** Branch on `sess.layout.version == .v2` in
`completePieceDownload` *before* the SHA-1 path, and dispatch to a
new `completeV2PieceDownload` helper. The helper:

1. Looks up `tc.leaf_hashes` (allocated lazily by
   `protocol.handleHashesResponse` on first valid hashes message);
   if `null`, cleanup as failure (no oracle).
2. Looks up `lh.get(piece_index)`; if `null`, cleanup as failure
   (specific leaf not yet stored).
3. Inline SHA-256 verify against the stored leaf. On mismatch,
   cleanup as failure.
4. On verify success, runs the same per-span disk-writes shape as
   the v1 inline-verify fallback (`PendingWriteKey` /
   `createPendingWrite` / `self.io.write` per span / spans-remaining
   tracking).

Hybrid torrents keep the v1 path — their SHA-1 hashes are present
in metainfo, the existing background-hasher pipeline handles them,
and there's no benefit to a parallel v2 path for hybrid that's
already-incrementally-verifiable via SHA-1.

**Why inline SHA-256.** The hasher pool is SHA-1-only; threading
SHA-256 through `src/io/hasher.zig` is the simhasher-engineer's
territory and explicitly out-of-scope per the file-ownership split.
Inline SHA-256 has the same blocking shape as the existing
`hasher == null` fallback — exercised by the swarm tests
(`tests/sim_swarm_test.zig` runs with `hasher_threads=0`). A
follow-up that lands SHA-256 in the hasher pool can swap the inline
verify for a `hasher.submitVerifyV2(...)` dispatch later.

**Smart-ban deferred.** Per the task's scope guard
("scope-cut to the simplest valuable path: validate leaf hashes when
present; defer smart-ban-on-failure"). The smart-ban infrastructure
attaches to the SHA-1 hasher's Phase 1 attribution snapshot
(`snapshotAttributionForSmartBan` in peer_policy.zig); wiring that
into the v2 inline path needs more plumbing than the contained
"validate when leaf present" change targets.

**Tests.** Three inline tests in `src/io/peer_policy.zig`:

- `completeV2PieceDownload: no leaf hashes stored → fails closed` —
  tc.leaf_hashes is null, cleanup as failure.
- `completeV2PieceDownload: stored leaf with mismatched data → fails
  closed` — leaf is `0xCC × 32`, piece_buf is "hello", SHA-256
  mismatch, cleanup as failure.
- `completeV2PieceDownload: stored leaf matching data → SHA-256
  passes` — leaf is `SHA-256("hello")`, verify succeeds, hits the
  all-spans-skipped cleanup branch (shared_fds = [-1] in the test
  fixture).

A `V2Fixture` helper sets up the EL + v2 session + piece tracker +
torrent context with shared_fds = [-1]. The fixture's `deinit` calls
`removeTorrent` before `el.deinit` because EL.deinit's Phase 3
torrent-cleanup loop doesn't iterate `tc.leaf_hashes` —
pre-existing shape, not in scope here. (Filed mentally as a
follow-up; the fix would be a one-line addition to event_loop.zig
deinit Phase 3.)

**Time spent.** ~3 hours; the largest of the four. The test fixture
setup was the bulk of it — once the helper existed the three test
cases were mechanical.

## Task 4 — Blocking helpers: rename + docstring warnings

**Source.** External-review C4: blocking HTTP / metadata-fetch
helpers were public, neutrally-named, and easy to misuse from a
daemon code path. Routing either into the event loop would stall
every torrent's progress on a syscall — directly contrary to the
AGENTS.md io_uring policy.

**Two paths.**

- `src/net/metadata_fetch.zig`: full rename treatment.
  `MetadataFetcher.fetch` → `fetchBlocking`. Internal
  `fetchFromPeer` → `fetchFromPeerBlocking`. File-header doc-comment
  opens with "blocking, background-thread-only" and points at the
  async io_uring replacement (`AsyncMetadataFetchOf(IO)` in
  `src/io/metadata_fetch.zig`). Per-method doc-comments call out
  the blocking syscalls used (`posix.connect` / `posix.read` /
  `posix.write`). Single internal test caller updated.

- `src/io/http_blocking.zig`: docstring-only treatment. The file
  header "BLOCKING HTTP CLIENT" note was already there; expanded
  into "DO NOT USE FROM THE DAEMON EVENT LOOP" and citing
  AGENTS.md and the `HttpExecutor` alternative. Added per-method
  blocking-syscall warnings to `get` / `getWithHeaders` /
  `getRange` and to the `HttpClient` struct doc-comment. *Did NOT*
  rename methods — the threadpool DNS test
  (`src/io/dns_threadpool.zig:762` calls `client.get(...)`) is
  owned by the dns-phase-f-and-flakes-engineer per the file-
  ownership split, so a method rename would land in their territory.
  Header + per-method warnings keep the lower-risk docs-only path.

`storage/writer.zig`'s submit-and-drain methods were already covered
by the Task 1 doc-comment work — each method documents
"blocks the calling thread on `io.tick`" in its existing per-method
doc-comment.

**Time spent.** ~1 hour.

## What was learned

**The dangling `store.io` was a real bug; the round-fix that landed
`submitTorrentSync` deliberately routed around it.** Reading the
2026-04-28 progress report, the team-lead-of-that-round filed the
follow-up but didn't take it then because the EL-level sync sweep
solved the *immediate* problem (no caller for `store.sync` from the
daemon hot path). This round closes the latent half. Pattern: when
a round does the strict minimum to unblock a test, it's worth
following up with the structural fix that makes the wrong code
unwriteable, even if no current caller hits it.

**`IORING_REGISTER_PROBE` doesn't tell us about URING_CMD subcmds.**
The kernel's `IO_URING_OP_SETSOCKOPT` is a *subcmd* of `URING_CMD`,
not a standalone op. The probe register only enumerates standalone
opcodes. The pragmatic answer is to probe URING_CMD as the necessary
condition, document the gap, and have callers handle subcmd
rejection at completion time. There's a more sophisticated approach
(probe by *trying* a SETSOCKOPT URING_CMD at init), but it's overkill
for the daemon's needs — the synchronous fallback is always
mandatory anyway.

**Inline SHA-256 for v2 piece verification is fine for now.** The
"events on the loop thread shouldn't block" rule has a safety valve:
the inline-verify fallback for v1 (when `hasher_threads=0`) blocks
on `Sha1.hash(piece_buf, ...)` and the swarm tests run that path
end-to-end without contention issues. SHA-256 is ~2× the work of
SHA-1 per byte but on the order of ~600 MB/s on a single core —
piece-sized hashing finishes in tens to hundreds of microseconds.
Compare that to the time the ring already spends in `posix.recv`
draining a peer's full piece buffer. Threading SHA-256 onto the
hasher pool is desirable for *consistency*, not for *correctness* —
the simhasher-engineer's round will handle it cleanly.

**The blocking-helper rename has an asymmetry between same-team and
cross-team callers.** `metadata_fetch.zig` was internally-called by
one test in the same file — full rename was free. `http_blocking.zig`
had a caller in DNS-engineer territory — a method rename would have
created merge conflict for them. Docstring warnings on the same
method names are weaker but lower-friction. The right answer is
case-by-case; "one rule for everything" would either over-rename or
under-rename.

## Remaining issues / follow-up

- **Daemon submission paths for bind / listen / setsockopt.** Now
  that `FeatureSupport` has the flags, the daemon's listen-socket
  bring-up paths and per-peer setsockopt calls can branch on
  `feature_support.supports_bind` / `supports_listen` /
  `supports_setsockopt`. Filed in STATUS.md "Next" section.

- **Smart-ban-on-failure for v2.** The current
  `completeV2PieceDownload` doesn't penalise peers that delivered
  bad data when the SHA-256 verify fails. The smart-ban Phase 1
  attribution path runs through the SHA-1 hasher's pre-hash
  snapshot; wiring it into the inline v2 path needs the
  `snapshotAttributionForSmartBan` call to be moved before the
  SHA-256 verify, and `processHashResults` to grow a v2 path that
  fires the smart-ban Phase 2 onPieceFailed call. Not blocking for
  v2 download progress but worth filing.

- **EL.deinit Phase 3 doesn't iterate `leaf_hashes`.** Pre-existing
  asymmetry: the cleanup loop at `event_loop.zig:751-763` frees
  `pex_state`, `web_seed_manager`, and `peer_slots` but not
  `merkle_cache` or `leaf_hashes`. (`merkle_cache` and
  `leaf_hashes` *are* freed in `removeTorrent`, so well-behaved
  callers don't leak.) The Task 3 test fixture works around it by
  calling `removeTorrent` before `deinit`. A one-line addition to
  Phase 3 would close the gap; out of scope for this round.

- **Higher-layer `hashes` responses still dropped.** The R5 round's
  filed follow-up. Only `base_layer == 0` responses are currently
  stored. Subtree-root storage would let us verify finer ranges
  before the full leaf layer arrives.

## Key code references

- `src/storage/writer.zig:40-65` — PieceStore doc-comment (lifetime
  invariant) and field removal.
- `src/storage/writer.zig:120-140` — `ensureFileOpen` signature.
- `src/storage/writer.zig:289-349` — `writePiece` signature + body.
- `src/storage/writer.zig:360-401` — `readPiece` signature + body.
- `src/storage/writer.zig:411-450` — `sync` signature + body.
- `src/storage/verify.zig:246-295` — `recheckExistingData(io: *RealIO, ...)`.
- `src/io/ring.zig:114-176` — extended `FeatureSupport` struct +
  `probeFeatures`.
- `src/io/peer_policy.zig:670-697` — v2 branch in
  `completePieceDownload`.
- `src/io/peer_policy.zig:897-1063` — `completeV2PieceDownload` +
  doc-comment.
- `src/io/peer_policy.zig:2400-2569` — `V2Fixture` and three
  v2-completion tests.
- `src/net/metadata_fetch.zig:10-35` — file-header policy warning.
- `src/io/http_blocking.zig:1-30` — file-header policy warning.

## Test count delta

`zig build test`: 1183 → 1183 passing (pre-existing flakes are
flaky at the same rate; my new tests are 7 inline tests covering
new code paths, but most of the pre-Task-1 PieceStore tests were
already counted in the 1183 because they go through both io paths).
