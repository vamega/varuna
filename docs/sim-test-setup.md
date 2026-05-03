# Writing sim tests against `EventLoop(SimIO)`

This document captures what a test author needs from the daemon's
`EventLoop` once it's parameterised over its IO backend (Stage 2 #12),
so that the same `Simulator` + `SimSwarm` + `SimPeer` infrastructure that
already runs the protocol-only smart-ban regression
(`tests/sim_smart_ban_protocol_test.zig`) can drive the real
`EventLoop(SimIO)`.

The design here is a *requirements list*, not a finished API. It exists
so migration-engineer can land the EventLoop changes with the right
shape baked in, rather than retrofitting hooks into the production code
later.

---

## What the simulator gives the EventLoop

A `Simulator` configured with `Driver = EventLoop(SimIO)` provides:

- `*SimIO` — the IO backend. EventLoop submits all recv/send/connect/etc
  through this. `SimIO.createSocketpair()` provides ready-paired fds the
  test driver can plug into peer slots.
- A seeded `std.Random.DefaultPrng` — the simulator's RNG. EventLoop
  doesn't see this directly; behaviours that depend on randomness
  (peer-id generation, jitter) should derive from `SimIO.config.seed`
  or from a separate `EventLoop.config.seed` the test plumbs through.
- A logical `clock_ns` — `Simulator.step` keeps `SimIO.now_ns` in
  lockstep. EventLoop's `Clock` must read from the same source so
  timeouts fire on simulated time, not wall time.
- `Driver.tick(*EventLoop, *SimIO)` — called once per simulator step,
  *before* `SimIO.tick`. The EventLoop should drain any internal queues
  and submit fresh ops; their completions fire on the subsequent
  `io.tick`.

## What the test needs from `EventLoop(SimIO)`

A real EventLoop boots a torrent runtime that, in production, also wires
up tracker announces, DHT, RPC server, peer listener, signal handlers,
piece hashing thread pool, and the SQLite resume DB. None of that is
useful in a simulator test — most of it has no SimIO equivalent and the
parts that do (DHT, trackers) need their *own* SimPeers to drive against.

### 1. Disable-everything-but-peers config

Add a `simulator_mode: bool = false` (or equivalent) to `EventLoop.Config`
that, when set, disables:

- The TCP/uTP listener (no `accept` SQE submitted; no listen socket fd).
- All tracker announces (HTTP and UDP). Trackers are a separate test
  surface; the smart-ban swarm test does not need them.
- DHT engine (no UDP socket, no bootstrap, no kbucket persistence).
- The signal-fd / signalfd poll. Sim runs synchronously on the test
  thread and never receives signals.
- The SQLite resume thread. Resume state is irrelevant in a sim test;
  the test's torrent registry is in-memory.
- The hasher thread pool — *or* run the SHA-1 hasher inline on the test
  thread. The simulator has no real disk; piece data lives in
  test-owned memory and SHA-1 is fast enough to compute synchronously
  per piece-complete event.

The `simulator_mode` flag is a marker config bit, not a fork. The
production path stays unchanged when the flag is false.

### 2. Test-only torrent registration

The daemon today loads torrents from disk via `Session.load`. For a sim
test, the test owns the torrent's metainfo (it's just a struct of
piece hashes + a layout) and the test owns the storage (no real disk —
the test buffers piece bytes in memory).

Surface a path like:

```zig
pub const TestTorrentSpec = struct {
    info_hash: [20]u8,
    piece_count: u32,
    piece_size: u32,
    piece_hashes: []const [20]u8,
    /// In-memory storage; EventLoop reads/writes against this slice
    /// instead of going through PieceStore. The sim's SimIO read/write
    /// ops would resolve against this directly via a synthetic fd.
    storage: []u8,
};

pub fn addTestTorrent(self: *EventLoop, spec: TestTorrentSpec) !u32; // returns torrent_id
```

The simplest implementation: when `simulator_mode` is true, `addTestTorrent`
shortcuts the load pipeline (no SQLite, no metainfo file parse, no
fallocate), wires up an in-memory `PieceStore`-like adapter against the
provided `storage` slice, and registers the torrent with the rest of the
event-loop machinery.

### 3. Test-only inbound peer slot wiring

For each SimPeer in the swarm, the test calls `SimIO.createSocketpair()`
to get two paired fds. One side is owned by the SimPeer; the other side
needs to land in an `EventLoop` peer slot.

Today's flow is `accept_multishot` → `EventLoop.acceptComplete` allocates
a peer slot and arms peer-recv. For a sim, we want to skip the listener
and inject the fd directly:

```zig
pub fn addInboundPeer(
    self: *EventLoop,
    torrent_id: u32,
    fd: posix.fd_t,
    peer_addr: std.net.Address,
) !u16; // returns peer slot
```

Internally this just runs the post-accept path: pick a free slot, set
`peer.fd = fd`, run the existing per-peer handshake setup (which is
already an inbound flow because the SimPeer drives the handshake from
its side as the seeder).

For outbound peers (the EventLoop initiating to a SimPeer that's
acting as a downloader, not yet implemented): same idea but uses an
`addOutboundPeer(torrent_id, fd, peer_addr)` path that bypasses
`io.connect`.

### 4. Read-only test assertions

The test asserts on:
- `trust_points` and `hashfails` per peer slot.
- Whether a piece is complete.
- Whether a peer is banned.

These are already on `Peer` and the piece tracker. Just expose
read-only views:

```zig
pub fn getPeerView(self: *const EventLoop, slot: u16) ?PeerView; // null if slot unused

pub const PeerView = struct {
    address: std.net.Address,
    trust_points: i8,
    hashfails: u8,
    is_banned: bool,
    bytes_downloaded: u64,
    bytes_uploaded: u64,
};

pub fn isPieceComplete(self: *const EventLoop, torrent_id: u32, piece_index: u32) bool;
```

These are pure-read helpers; no internal state changes. Easy to add and
trivially safe.

### 5. Smart-ban dependency wiring

Phase 0 EL tests (single-source corrupt peer over many pieces) get by
with just `BanList` installed via `el.ban_list = &ban_list`. Phase 0's
`peer_policy.penalizePeerTrust` accumulates trust-point hits across
hash failures and bans at the threshold; the corrupt peer typically
stays connected long enough for the threshold to fire.

**Phase 2 tests require BOTH `BanList` AND `SmartBan` installed** —
without `el.smart_ban = &smart_ban`, the `SmartBan.snapshotAttribution`
/ `onPieceFailed` / `onPiecePassed` chain doesn't fire and Phase 2's
per-block discriminating power is bypassed entirely. A
disconnect-mid-piece corrupt peer escapes attribution because Phase 0
alone needs 4 hash failures before banning, and the peer leaves
after 1-2.

```zig
var ban_list = BanList.init(allocator);
defer ban_list.deinit();
var smart_ban = SmartBan.init(allocator);
defer smart_ban.deinit();

var el = try EL_SimIO.initBareWithIO(allocator, sim_io, hasher_threads);
defer el.deinit();

el.ban_list = &ban_list;
el.smart_ban = &smart_ban;
```

**Declaration order matters**: `defer` runs LIFO. The EL's
`deinit → drainRemainingCqes` can fire `processHashResults` →
`SmartBan.onPieceFailed` / `onPiecePassed` for residual late CQEs. If
`smart_ban` or `ban_list` is declared AFTER `el`, their defer runs
FIRST, freeing the dependencies while EL is still draining → UAF
panic in the hashmap header() pointer math. Always declare
`ban_list` and `smart_ban` BEFORE `el` so LIFO defer order runs
`el.deinit` first (with both still alive), then `smart_ban.deinit`,
then `ban_list.deinit`.

This pattern was diagnosed during Phase 2B test landing
(commit `112dd5c` on `worktree-sim-engineer`); see
`docs/multi-source-test-setup.md` section A6 for the deeper context.

---

## Test skeleton (after Stage 2 #12 lands)

```zig
const Simulator = varuna.sim.Simulator;
const SimulatorOf = varuna.sim.SimulatorOf;
const SimPeer = varuna.sim.SimPeer;
const EventLoop = varuna.io.event_loop.EventLoop;

test "smart-ban swarm vs. real EventLoop" {
    var sim = try SimulatorOf(EventLoop(SimIO)).init(testing.allocator, .{
        .swarm_capacity = 6,
        .seed = 0xDEADBEEF,
        .sim_io = .{ .socket_capacity = 16 },
    }, try EventLoop(SimIO).init(testing.allocator, .{
        .simulator_mode = true,
        // ... EventLoop config that disables tracker/DHT/listener/etc.
    }));
    defer sim.deinit();

    const tid = try sim.driver.addTestTorrent(.{
        .info_hash = .{0xab} ** 20,
        .piece_count = 4,
        .piece_size = 1024,
        .piece_hashes = &computed_hashes,
        .storage = &storage_buf,
    });

    // Spin up 5 honest + 1 corrupt SimPeer; for each, create a socketpair,
    // hand one fd to SimPeer, call sim.driver.addInboundPeer(tid, other_fd, ...)
    // for the EventLoop side.
    var peers: [6]SimPeer = ...;
    var slots: [6]u16 = ...;
    for (&peers, 0..) |*peer, i| {
        const fds = try sim.io.createSocketpair();
        try peer.init(.{ ... .fd = fds[0] ... });
        try sim.addPeer(peer);
        slots[i] = try sim.driver.addInboundPeer(tid, fds[1], synthetic_addr_for(i));
    }

    // Drive until done or max steps.
    const ok = try sim.runUntilFine(struct {
        fn cond(s: *@TypeOf(sim)) bool {
            return s.driver.isPieceComplete(tid, 0)
               and s.driver.isPieceComplete(tid, 1)
               and s.driver.isPieceComplete(tid, 2)
               and s.driver.isPieceComplete(tid, 3);
        }
    }.cond, 4096, 1_000_000);

    try testing.expect(ok);

    // Smart-ban assertions.
    const corrupt_view = sim.driver.getPeerView(slots[5]).?;
    try testing.expect(corrupt_view.is_banned);
    try testing.expect(corrupt_view.trust_points <= -7);

    var i: usize = 0;
    while (i < 5) : (i += 1) {
        const v = sim.driver.getPeerView(slots[i]).?;
        try testing.expect(!v.is_banned);
        try testing.expectEqual(@as(u8, 0), v.hashfails);
    }
}
```

The production EventLoop version now lives in
`tests/sim_smart_ban_eventloop_test.zig`. It replaced the earlier
hand-rolled downloader scaffold and should be the smart-ban swarm
integration reference going forward.

---

## What `addTestTorrent` actually needs to do

To pin down the API requirement: the daemon's EventLoop expects each
torrent to provide:

- Piece-grid layout (file offsets, piece size, piece count).
- Piece hashes (canonical SHA-1 per piece).
- Bitfield (what's already-have vs. need-to-download).
- A piece store (read-existing-block / write-new-block / fsync).
- A way to receive completed pieces back into the daemon (hash result
  → `markPiecePassed` / `markPieceFailed` flow).

The test-only path can satisfy each:

| Production path | Sim test path |
|---|---|
| `Metainfo.parseFromBytes(allocator, metainfo_bytes)` | Test passes the layout directly via `TestTorrentSpec` |
| `PieceStore.init(layout, save_path)` (creates files, fallocate) | `InMemoryStore` adapter against the test's `storage: []u8` slice |
| Hash result via `Hasher.thread_pool` | Inline `Sha1` on the test thread |
| Bitfield from disk recheck | Test passes `initial_bitfield` (or zero, downloader starts from scratch) |

The InMemoryStore would provide:

```zig
pub const InMemoryStore = struct {
    storage: []u8,
    pub fn read(self: *@This(), piece_index: u32, offset: u32, dst: []u8) void;
    pub fn write(self: *@This(), piece_index: u32, offset: u32, src: []const u8) void;
    pub fn fsync(self: *@This()) void; // no-op
};
```

`EventLoop.PieceStore` becomes a polymorphic interface (or a comptime
`PieceStore: type` parameter on EventLoop) selected by `simulator_mode`.

---

## Coordination

This doc is a checklist for migration-engineer to consult when Stage 2
#12 finishes. Each requirement here is independent and can land in
separate commits. The minimum viable swarm test needs (1), (2), (3),
and a thin `getPeerView` from (4); the rest of (4) can grow as the
sim suite expands.

Open questions worth asking before the implementation lands:
- Does `simulator_mode` need to disable peer state-machine timing
  (chokes/unchokes that depend on wall clock) or do those already
  read from `EventLoop.Clock`?
- Does the production `Hasher` thread pool need an inline-sync mode,
  or is it cleaner to inject a `HasherStrategy` interface and let the
  sim use a synchronous one?
- For multi-source piece assembly tests (eventually): how is per-block
  peer attribution surfaced? `peer_policy.zig:smartBan` already records
  `BlockRecord{peer_address, digest}` — is that read-only-exposable too?

Ping sim-engineer when each of (1)/(2)/(3)/(4) is in flight; happy to
iterate on shape.
