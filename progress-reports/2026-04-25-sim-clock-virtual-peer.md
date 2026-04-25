# Deterministic simulation: clock injection + VirtualPeer (Steps 1–2)

## What changed and why

Adopted the first two steps of a FoundationDB/TigerBeetle-style deterministic simulation
approach for the EventLoop's peer I/O layer.

**Step 1 — injectable clock (`src/io/clock.zig`)**

Introduced `Clock`, a tagged union with `.real` (delegates to `std.time.timestamp()`) and
`.sim` (returns a test-controlled `i64`).  Added a `clock: Clock = .real` field to
`EventLoop` and replaced every bare `std.time.timestamp()` call in the daemon's I/O layer
with `self.clock.now()` (or `el.clock.now()`).  Files touched:
`peer_handler.zig`, `peer_policy.zig`, `protocol.zig`, `utp_handler.zig`,
`web_seed_handler.zig`, `dht_handler.zig`.

The default is `.real` so all production paths and existing inline tests are unaffected.

**Step 2 — VirtualPeer over AF_UNIX socketpair (`src/sim/virtual_peer.zig`)**

A synthetic seeder that runs in a background thread and drives the full BitTorrent wire
protocol over an `AF_UNIX` socketpair.  The EventLoop owns one non-blocking fd via
io_uring; the test thread does blocking reads/writes on the other.  Kernel socket buffers
decouple the two sides, so there is no deadlock risk.

Added `EventLoop.addConnectedPeer(fd, torrent_id)` to inject a pre-connected fd, bypassing
the async socket/connect chain.  Made `peer_handler.sendBtHandshake` public so the method
can be called from `addConnectedPeer`.

**Integration test (`tests/sim_swarm_test.zig`)**

Exercises the full piece-download path — handshake, bitfield, unchoke, request, piece,
SHA-1 verification, disk write — without a real network stack or second daemon process.
The clock is set to `10_000` seconds so all interval gates (unchoke, keepalive, PEX) open
immediately.  The EventLoop is initialised with `initBare(allocator, 0)` (no hasher
threads), relying on the synchronous inline-SHA-1 + io_uring write fallback in
`completePieceDownload`.

**Nix devshell (`flake.nix`)**

Added a `flake.nix` using [zig-overlay](https://github.com/mitchellh/zig-overlay) to pin
Zig 0.15.2 on NixOS, replacing the previous `mise`-based toolchain setup for this project.
Packages: `zig 0.15.2`, `sqlite` (dev headers), `liburing` (dev headers), `pkg-config`,
`git`.  Enter with `nix develop`.

## What was learned

- `std.posix.socketpair` was removed in Zig 0.15.2; use `std.c.socketpair` instead.
- `posix.O` is a packed struct in 0.15.2, not an integer — to pass `O_NONBLOCK` to
  `fcntl` use `@as(usize, @bitCast(posix.O{ .NONBLOCK = true }))`.
- The `zig build test-sim` step exits 0 even when cached from a prior failure; run the
  binary directly (`.zig-cache/o/<hash>/test`) to confirm the current binary actually passes.

## Key code references

- `src/io/clock.zig` — Clock tagged union
- `src/io/event_loop.zig` — `clock` field, `addConnectedPeer`
- `src/sim/virtual_peer.zig` — VirtualPeer and Request types
- `tests/sim_swarm_test.zig` — end-to-end sim swarm test
- `flake.nix` — Nix devshell

## Remaining issues / follow-up

- Step 3 (BUGGIFY-style fault injection): randomly drop/corrupt messages in VirtualPeer,
  inject disk errors via a fault-injectable PieceStore wrapper.
- Step 4 (deterministic scheduler): drive the EventLoop tick-by-tick from a single-threaded
  simulation loop, replacing the io_uring timeout with a virtual time source and removing
  the seeder background thread.
