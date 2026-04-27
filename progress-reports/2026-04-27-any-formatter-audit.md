# `{any}` formatter audit (round 2)

## Why this exists

The 2026-04-27 round-1 dark-test audit accidentally surfaced one
instance of a Zig 0.15.2 stdlib semantic shift: `{any}` no longer
delegates to a type's `format` method. For aggregate types it now
emits a generic struct dump. `src/dht/persistence.zig:formatAddress`
was using `"{any}"` on `std.net.Ip6Address` and silently dropping every
IPv6 node from routing-table snapshots because the dump overflowed the
46-byte caller buffer (commit `d340bc8`).

This audit is the systematic follow-up: find every other `{any}` site
and decide whether it's safe, verbose, or a real bug.

## Methodology

```
grep -rn '{any}' src/ tests/ build.zig
```

23 hits. Categorised, then verified the actual `{any}` behaviour by
running a `bufPrint(buf, "{any}", .{addr})` against
`std.net.Address.initIp4(...)`:

```
{any} (len=642): .{ .any = .{ .family = 2, .data = { 31, 144, 127, 0, 0,
    1, 0, 0, 0, 0, 0, 0, 0, 0 } }, .in = .{ .sa = .{ .family = 2,
    .port = 36895, .addr = 16777343, .zero = { ... } } },
    .in6 = .{ .sa = .{ .family = 2, .port = 36895, .flowinfo = 16777343,
    .addr = { ... }, .scope_id = 0 } }, .un = .{ .family = 2,
    .path = { 31, 144, ... 108 bytes ... } } }
{f}   (len=14): 127.0.0.1:8080
```

`std.net.Address` is an `extern union`, so `{any}` walks every
overlapping field — including the 108-byte sockaddr_un path — for a
~640-byte dump per address. `{f}` (which calls the type's `format`
method in 0.15.2) gives the expected `IP:port` form.

## Findings

### 1. Production bug — qBittorrent peer-list JSON

`src/daemon/session_manager.zig:1791` (now 1825) used
`std.fmt.allocPrint(allocator, "{any}", .{peer.address})` to build the
`ip` field of every entry returned from `getTorrentPeers`, which feeds
the qBittorrent-compatible `/api/v2/sync/torrentPeers` JSON in
`src/rpc/sync.zig:serializePeerObject`. Every peer's `ip` field was
therefore a 600+ byte struct dump, breaking the qBittorrent web UI's
peer table since the Zig 0.15.2 upgrade.

Fix: extracted into a `formatPeerIp` helper that uses `{f}` and strips
the trailing `:port` and any IPv6 brackets so the JSON `ip` field
contains just the bare address. Three regression tests assert the bare-
IP form for IPv4, IPv6, and explicitly that the output never contains
struct-dump tokens (`.{`, `.family`).

This is the **same class of bug** as the round-1 IPv6 persistence drop,
just on a different fixed-format consumer (JSON instead of a 46-byte
buffer).

Commit: `377c216 session_manager: fix peer-list IP becoming a 642-byte struct dump`.

### 2. Log-verbosity fixes (10 sites, 4 files)

All log-only sites that printed `std.net.Address` via `{any}`. No
fixed-buffer truncation (log writers grow), so no correctness impact —
purely verbosity. But these were turning every smart-ban warning into
a 700-byte multi-line dump that buried the real signal:

```
[event_loop] (warn): banning peer .{ .any = .{ .family = 2,
    .data = { 0, 0, 10, 0, 0, 6, 0, 0, 0, 0, 0, 0, 0, 0 } },
    .in = .{ .sa = .{ .family = 2, .port = 0, .addr = 100663306,
    .zero = { ... } } }, .in6 = .{ ... }, .un = .{ ... 108 bytes ... } }
    (slot 5): trust_points=-8, hashfails=4
```

After:

```
[event_loop] (warn): banning peer 10.0.0.6:0 (slot 5):
    trust_points=-8, hashfails=4
```

Sites:

- `src/io/utp_handler.zig:245` — outbound uTP connection established
- `src/io/utp_handler.zig:333` — inbound uTP connection accepted
- `src/io/event_loop.zig:1351` — initiating outbound uTP connection
- `src/io/event_loop.zig:1950` — disconnecting banned peer
- `src/dht/dht.zig:180` — malformed KRPC from sender
- `src/dht/dht.zig:446` — accepted announce_peer
- `src/dht/dht.zig:462` — response for unknown txn
- `src/dht/dht.zig:550` — KRPC error from sender
- `src/io/peer_policy.zig:1080` — banning peer (trust)
- `src/io/peer_policy.zig:1677` — smart-ban announce

The session_manager regression test covers the underlying invariant
(`{f}` on `std.net.Address` does not produce a struct dump) for all
ten of these call sites; per-site tests would be redundant.

Commit: `763c831 io,dht: replace {any} with {f} on std.net.Address log lines`.

### 3. Test diagnostics — kept (12 sites)

All `{any}` usages in `tests/` are formatting `anyerror` values for
debug printlns — `err={any}` produces `err=error.OutOfMemory` (not a
struct dump; `printErrorSet` handles error sets specially in Zig
0.15.2's writer). Verified by the same demonstration program. No
correctness or verbosity impact, no change.

Files:

- `tests/sim_smart_ban_protocol_test.zig:497`
- `tests/sim_multi_source_eventloop_test.zig:362,397`
- `tests/rpc_arena_buggify_test.zig:124`
- `tests/sim_smart_ban_eventloop_test.zig:420,461`
- `tests/recheck_buggify_test.zig:267`
- `tests/sim_smart_ban_swarm_test.zig:487`
- `tests/recheck_live_buggify_test.zig:322,393,464`

## Outcome breakdown

| Category | Count |
| --- | --- |
| **Production bug fixed** (struct dump shipped to user-facing JSON) | **1** |
| Log-verbosity reduction (`{any}` → `{f}` on `std.net.Address`) | 10 |
| Comment / test-name reference (no code change) | 1 (`src/dht/persistence.zig:238` round-1 explainer comment) |
| Test diagnostics on `anyerror` (kept; benign) | 12 |
| **Total `{any}` sites audited** | **24** |

Note: the audit grep returned 23 hits at start; the new regression-test
name in `session_manager.zig` ("…regression: `{any}` on Address") is
the 24th and last remaining production-source mention (in a comment).

## Lessons

The Zig 0.15.2 stdlib shift in `{any}` semantics is the kind of change
where existing callers don't fail to compile — they keep working but
silently emit very different output. The round-1 IPv6 bug shape (fixed
buffer overflow → silent drop) was the most obvious consequence. The
round-2 session_manager bug shape (right-sized buffer, wrong-format
output) is harder to spot but just as user-visible.

Adding a regression test for the formatter output (not just "does the
caller code path execute") is the cheap way to lock this in. The
formatter test in `dht/persistence.zig` (round 1) and the new
`formatPeerIp` tests (round 2) together cost ~30 lines and would have
caught both bugs at the 0.15.2 upgrade.

## Code references

- Production fix: `src/daemon/session_manager.zig:1735-1761`
  (helper), `:1825` (call site), `:1899-1944` (regression tests)
- Round-1 reference: `src/dht/persistence.zig:226-263`
- Behavioural reference (verifies `{any}` semantics): the
  `formatPeerIp does not emit a struct dump` test in
  `src/daemon/session_manager.zig`
