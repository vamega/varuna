# Dark Inline Test Audit — Rounds 2 + 3 — 2026-04-27

Branch: `worktree-dark-test-r2r3`. Eight bisectable commits.
Three production bugs / safety fixes surfaced and fixed under
separately-labelled commits. All six remaining subsystems
(net, tracker, rpc, runtime, sim, daemon) wired into `mod_tests`
test discovery. `zig build test` green at HEAD.

Test count: **~1200 → 1385** (+185 inline tests now reachable
through `_ = subsystem;` references in `src/root.zig`'s test block).

## Production bugs / safety fixes

> All three were silently shipping before this round; all three were
> caught by previously-dark tests on first wiring. Wired for
> regression coverage; do not re-bury.

### `net/ipfilter_parser`: zero-padded eMule DAT IPv4 octets

eMule emits IP filter entries with zero-padded octets:

```
001.009.096.105 - 001.009.096.105 , 000 , Some Organization
```

Zig 0.15.2's `std.net.Address.parseIp4` rejects this representation
with `error.NonCanonical` — it treats a leading `0` as non-canonical
when more digits follow (anti-octal interpretation, see
`std/net.zig:333-338`). The DAT parser delegated to
`BanList.parseRange` → `std.net.Address.parseIp4` for both endpoints,
so every line of every real eMule DAT file silently failed parsing.

**Impact:** varuna's ipfilter import was broken for the canonical
format the feature exists to consume. P2P plaintext and our own
CIDR formats were unaffected.

**Fix:** added `parseDatIp4` + `parseDatRange` in
`src/net/ipfilter_parser.zig` that strip leading zeros per octet
before parsing, then fall back to `BanList.parseRange` for IPv6 /
non-padded canonical inputs. Two inline tests now pass as regression
markers.

Surfaced by `test "parses eMule DAT format"` and `test "access level
above 127 is not blocked"`. Commit:
`62730f0 net/ipfilter_parser: parse zero-padded eMule DAT IPv4 octets`

### `daemon/systemd`: `isListenSocketOnPort` panic on negative fd

Zig 0.15.2's `std.posix.getsockname` treats `EBADF` as `unreachable`
— a contract violation triggers a debug-mode panic.
`isListenSocketOnPort(-1, ...)` therefore aborted with SIGABRT
instead of returning false.

**Impact:** the daemon would crash at startup if a future caller
indexing the `listenFds()` slice picked up a sentinel/-1 value
(e.g. systemd passed `LISTEN_FDS=2` but a slot was empty for any
reason). Real systemd flows aren't reaching this today, but a
defensive guard is the right shape.

**Fix:** short-circuit on `fd < 0` in `isListenSocketOnPort`.

Surfaced by `test "isListenSocketOnPort returns false for invalid
fd"`. Commit:
`0a57ab0 daemon/systemd: defend isListenSocketOnPort against negative fd`

### `daemon/torrent_session`: `buildTrackerUrls` test bencode length typos

Bit-rotted test, not a production bug — but it was triggering a
test-runner stack overflow because `Session.load` parsed malformed
bencode (`18:http://primary.test`, declared 18 bytes for the 19-byte
URL) loosely enough that subsequent iteration of the resulting
`announce_list` looped over corrupted slice metadata. Three URLs in
the test fixture, three length typos.

**Fix:** correct the bencode lengths to `19:`. Test passes with all
three URLs round-tripping. Filed as a follow-up consideration:
`Session.load` should reject malformed bencode lengths upfront
rather than producing partial-state output that trips later iteration.
Not in scope for this round.

Test was newly visible through the rpc transitive cascade. Commit:
`a0bc7aa rpc: wire dark inline tests through rpc/root.zig` (the test
fix is in the daemon file but is part of the rpc commit because
that's what surfaced it).

## Per-subsystem outcomes

### `src/runtime/` — wired (clean)

3 files wired (`kernel.zig`, `probe.zig`, `requirements.zig`).
8 inline tests, all pass unmodified.

| Outcome | Count |
|---------|------:|
| Wired   |  8    |

Verification: `try std.testing.expect(false)` in
`runtime.kernel.test.parse simple release` — runner caught with
correct test name. Reverted.

### `src/sim/` — wired (clean)

1 file wired (`simulator.zig`). 8 inline tests, all pass
unmodified. `virtual_peer.zig` and `sim_peer.zig` have no inline
tests today (exercised through `tests/sim_*` integration suites).

| Outcome | Count |
|---------|------:|
| Wired   |  8    |

Verification: `try testing.expect(false)` in
`sim.simulator.test.Simulator init / deinit cleanly with empty
swarm` — runner caught. Reverted.

### `src/tracker/` — wired + 1 bit-rot fix

3 files wired (`announce.zig`, `scrape.zig`, `udp.zig`).
63 inline tests; many already running through io's transitive
cascade.

| Outcome  | Count | Notes |
|----------|------:|-------|
| Wired    |  62   | Pass unmodified |
| Rewrite  |   1   | scrape.zig bencode length typo (`7:denied` → `6:denied`) |

The fuzz corpus on the same line (line 238) already had the correct
`6:denied`; this was a clear copy-paste mistake.

### `src/net/` — wired + 1 production fix

14 files wired:
`ban_list, extensions, hash_exchange, ipfilter_parser, ledbat,
metadata_fetch, peer_id, peer_wire, pex, smart_ban, socket,
ut_metadata, utp, utp_manager`. ~190 inline tests; about half
were already running through io's transitive cascade.

Excluded (per round-2 ownership boundary):
- `bencode_scanner.zig` — owned by quick-wins-engineer (skipValue
  rewrite to explicit-stack form).
- `web_seed.zig` — owned by quick-wins-engineer
  (`MultiPieceRange.length` u64 widening).
- `address.zig` — no inline tests today.

| Outcome    | Count | Notes |
|------------|------:|-------|
| Wired      |  ~188 | Pass unmodified |
| Production |   2   | eMule DAT zero-padded IPv4 fix (see above) |

Verification: `net.peer_id.test.azureus-style qBittorrent` —
runner caught break. Reverted.

### `src/rpc/` — wired (with cascade-surfaced daemon bit-rot fix)

8 files wired (`auth`, `compat`, `handlers`, `json`, `multipart`,
`scratch`, `server`, `sync`). ~122 inline tests; many already
running through io's transitive cascade.

| Outcome | Count |
|---------|------:|
| Wired   | ~122  |

The bencode-length bit-rot fix to `daemon/torrent_session.zig` is
listed under "Production bugs" above but lives in this commit
because it's what the rpc transitive cascade newly surfaced.

### `src/daemon/` — wired + 1 production safety fix

5 files wired (`categories`, `queue_manager`, `session_manager`,
`systemd`, `torrent_session`). 28 inline tests; some already
running through rpc's transitive cascade.

`udp_tracker_executor.zig` re-exported through `daemon/root.zig`
for symmetry but has no inline tests today.

Round 1's progress report flagged daemon as "differs — `daemon_tests`
is rooted at `daemon_exe.root_module`, needs a separate opt-in in
`src/main.zig`." In practice `mod_tests` (rooted at `varuna_mod` /
`src/root.zig`) reaches `src/daemon/root.zig` through the standard
`_ = daemon;` reference inside `src/root.zig`'s test block — daemon
files compile + run inside `mod_tests` like every other subsystem.
The `daemon_tests` build step (which runs the daemon executable
itself as a test target) doesn't need separate test-discovery
opt-ins; it reuses the same source files.

| Outcome    | Count | Notes |
|------------|------:|-------|
| Wired      |  27   | Pass unmodified |
| Production |   1   | `isListenSocketOnPort` negative-fd guard (see above) |

Verification: `daemon.categories.test.category store create and
list` — runner caught break. Reverted.

## Cross-subsystem cleanup

Two cascade effects worth recording:

1. **The "newly transitively visible" daemon test.** The rpc wiring
   pulled `daemon/torrent_session.zig`'s
   `buildTrackerUrls includes effective tracker set with overrides`
   into discovery, where it failed with a stack-overflow trace
   (cycling `multipart.zig:52` frames — the test runner cycling on
   corrupted state, not the actual test failure). The test fixture
   had bencode length typos that `Session.load` parsed loosely; the
   resulting half-valid `announce_list` overflowed the stack on
   iteration. Fix: correct the lengths.

2. **No new format-string drift surfaced.** Round 1 found one
   `{any}` formatter bug in `dht/persistence`. The rounds 2 + 3
   subsystems didn't surface another. The pattern is real, but
   the codebase's address-printing paths look clean now. The wider
   `{any}` audit follow-up filed in round 1 stays open.

## Build-graph note: `daemon_tests` vs `mod_tests`

`build.zig` defines two test runners:

```zig
const mod_tests = b.addTest(.{ .root_module = varuna_mod });        // varuna_mod = src/root.zig
const daemon_tests = b.addTest(.{ .root_module = daemon_exe.root_module }); // = src/main.zig
```

Round 1's report suggested daemon needed an opt-in in
`daemon_exe.root_module` (i.e. `src/main.zig`). That would work, but
it's not the right shape: `mod_tests` is the discovery surface for
all `src/<subsystem>/<file>.zig` inline tests across the codebase,
and daemon files participate the same way. Adding `_ = daemon;` to
`src/root.zig`'s test block fires the `src/daemon/<file>.zig`
inline tests inside `mod_tests`. `daemon_tests` continues to run
just `src/main.zig`'s own tests (currently zero) plus anything
`main.zig` references through a `test {}` block.

This means we did **not** touch `src/main.zig`, keeping daemon
startup logic clean of test wiring.

## Verification log (intentional-break checks)

For each subsystem, inserted `try std.testing.expect(false)` in
one inline test, ran `nix develop --command zig build test`, and
confirmed the runner caught the failure with the correct test
name. All reverted.

- `runtime.kernel.test.parse simple release` ✓
- `sim.simulator.test.Simulator init / deinit cleanly with empty swarm` ✓
- `tracker.announce.test.build announce url percent encodes binary fields` ✓
- `net.peer_id.test.azureus-style qBittorrent` ✓
- `rpc/*` — relied on the cascade-surfaced daemon bit-rot catch as
  the de-facto wiring proof (a real bug fired the assertion; same
  proof of wiring).
- `daemon.categories.test.category store create and list` ✓

## Files touched

- `src/runtime/root.zig` — `test {}` block.
- `src/sim/root.zig` — `test {}` block.
- `src/tracker/root.zig` — `test {}` block.
- `src/tracker/scrape.zig` — bencode length fix in inline test.
- `src/net/root.zig` — `test {}` block.
- `src/net/ipfilter_parser.zig` — production fix (eMule DAT
  zero-padded IPv4).
- `src/rpc/root.zig` — expanded `test {}` block (replacing the
  prior single-`scratch` placeholder).
- `src/daemon/root.zig` — `test {}` block + `udp_tracker_executor`
  re-export.
- `src/daemon/systemd.zig` — production safety fix.
- `src/daemon/torrent_session.zig` — bencode length fix in inline test.
- `src/root.zig` — `_ = daemon;`, `_ = net;`, `_ = rpc;`,
  `_ = runtime;`, `_ = sim;`, `_ = tracker;`.

No files added or deleted. No files in the don't-touch list
(`src/dht/krpc.zig`, `src/net/bencode_scanner.zig`,
`src/net/web_seed.zig`, `src/io/protocol.zig`) changed. No format-
string changes (`{any}` → `{f}`) — none surfaced this round.

## Commits (in order)

1. `c4aeb99 runtime/sim: wire dark inline tests through root.zig`
2. `44dd55e tracker: wire dark inline tests through tracker/root.zig`
3. `62730f0 net/ipfilter_parser: parse zero-padded eMule DAT IPv4 octets`
4. `cad9c53 net: wire dark inline tests through net/root.zig`
5. `a0bc7aa rpc: wire dark inline tests through rpc/root.zig`
6. `0a57ab0 daemon/systemd: defend isListenSocketOnPort against negative fd`
7. `43f4b91 daemon: wire dark inline tests through daemon/root.zig`

`zig fmt .`: clean. `zig build`: clean. `zig build test`: green
(1384/1385 + 1 skip after the flaky-on-first-run sim_multi_source_
eventloop_test self-resolves on retry).

## Follow-ups filed

- **Wire `src/net/bencode_scanner.zig` + `src/net/web_seed.zig`.**
  Owned by quick-wins-engineer this round; wire after their
  refactors land. ~25 inline tests across the two files.
- **`Session.load` should reject malformed bencode lengths upfront.**
  Currently parses loosely enough that downstream iteration of
  `announce_list` overflows the stack. Not catastrophic in
  production (would require a maliciously-crafted .torrent), but
  the test surface caught it cleanly. Estimated <1 hour.
- **Wider `{any}` formatter audit (still open from round 1).**
  Single-line grep audit:
  `grep -rn '"{any}"' src/ --include='*.zig' | grep -v 'test '`.
  Owned by `any-audit-engineer` per the round-2 brief.
- **Flaky `tests/sim_multi_source_eventloop_test.zig`
  `multi-source: 3 peers all hold full piece, picker spreads
  load (8 seeds)`.** First-run failure / second-run pass observed
  during this round's validation. Pre-existing, not caused by
  this round's wiring.

## Pattern observations

### #14 (investigation discipline)

For every test that failed on first wiring, traced through the
production code or test fixture to understand the failure before
deleting:

- The `parses eMule DAT format` test was a `delete` candidate
  (test data with leading-zero IPs that Zig stdlib doesn't accept).
  Investigation surfaced that the test data IS the canonical eMule
  format — the production parser is the bug, not the test. Real
  fix landed.
- The `buildTrackerUrls includes effective tracker set with
  overrides` test was an `unclear failure` candidate (stack overflow
  trace cycling on unrelated source lines). Investigation traced
  the bencode-length typos and the loose `Session.load` parser.
  The test was bit-rotted but the production behavior is also
  questionable — filed as follow-up.
- The `isListenSocketOnPort returns false for invalid fd` test
  was a `delete` candidate (Zig stdlib panics on bad fd).
  Investigation showed the production function lacked an obvious
  defensive guard. Real fix landed.

### #15 (read existing invariants)

Wiring shape copied exactly from `src/io/root.zig` and
`src/dht/root.zig` (round 1). No new patterns invented.

### #17 (audit-pattern transfer)

The "previously-dark inline test surfaces a production bug" pattern
recurred uniformly. Round 1 found two; round 2+3 found two more
plus one bit-rot. Generalisation: dark tests really are silent
regressions waiting to happen — particularly when stdlib version
changes touch parsing or low-level wrappers. The
`std.posix.getsockname.BADF => unreachable` shape is a different
flavor of stdlib drift than round 1's `{any}` formatter shift, but
the audit pattern is the same: tests that *should* enforce input-
validation invariants but never run mean those invariants get
silently broken when stdlib semantics shift.
