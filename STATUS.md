# Varuna Status

This file is the current implementation ledger for Varuna.
Update it whenever a milestone lands, the near-term backlog changes, or a new operational risk or compatibility issue is discovered.

## Done

- `.torrent` ingestion, bencode parsing, metainfo parsing, info-hash calculation, and piece/file layout mapping are implemented.
- Target files are created up front and verified pieces are written with piece-to-file span mapping.
- Startup resume works through full piece recheck and on-disk SHA-1 verification.
- HTTP tracker announce works with compact peer lists.
- Sequential single-peer download works end to end.
- Minimal seeding works for one inbound peer when the torrent data is already complete on disk.
- `varuna inspect` prints torrent metadata and info hash for scripting and tracker bootstrapping.
- Local tracker tooling exists:
  - `scripts/create_torrent.mjs` creates `.torrent` files.
  - `scripts/tracker.sh` wraps the Ubuntu `opentracker` package.
  - `scripts/demo_swarm.sh` verifies one `varuna seed` instance and one `varuna download` instance against that tracker.
- Profiling workflow exists through `strace`, `perf`, and `bpftrace` documentation and build helpers.
- Bencode/metainfo parsing returns errors instead of panicking on malformed untrusted input.
- Shared `Bitfield` type unifies `PieceSet` and `PieceAvailability`.
- Self-peers are filtered from tracker responses before connection attempts.
- Tracker lifecycle events: `completed` sent after download, `stopped` sent on seed exit and download failure.
- Block request pipelining (depth 5) reduces per-block RTT overhead.
- Benchmark suite covers kernel parsing, bencode parsing, SHA-1 hashing, and metainfo parsing.
- Multi-peer download: thread-per-peer workers with PieceTracker coordination, `--max-peers` option (default 5).
- io_uring is the I/O path for all hot-path file and network operations:
  - `src/io/ring.zig` wraps `std.os.linux.IoUring` with blocking convenience methods.
  - `PieceStore` read/write/sync routes through `Ring.pread_all`/`pwrite_all`/`fsync`.
  - Peer wire protocol send/recv routes through `Ring.send_all`/`recv_exact`.
  - TCP connect and accept use `Ring.connect`/`Ring.accept` via `src/net/transport.zig`.
  - Startup banner reports io_uring availability.

## Next

- ~~Filter or otherwise handle self-peers more cleanly~~ Done: `isSelfPeer` skips `127.0.0.1` and `0.0.0.0` on the client's own port.
- ~~Send `completed`/`stopped` tracker events~~ Done: best-effort `completed` after download, `stopped` on seed exit and download failure.
- Improve tracker lifecycle behavior:
  - handle stale peers and tracker edge cases more deliberately
  - validate behavior against more private-tracker expectations
- Widen peer behavior past the current minimal contract:
  - ~~more than one active peer~~ Done: thread-per-peer workers with PieceTracker coordination, --max-peers option
  - better piece selection than strict sequential download (rarest-first -- Cycle 2)
  - stronger peer/session state handling
  - ~~pipeline block requests~~ Done: pipeline depth of 5 outstanding requests per piece
- Replace full startup-only resume with persisted resume state (SQLite, background thread -- see [docs/io-uring-syscalls.md](docs/io-uring-syscalls.md) for constraints).
- ~~Begin the actual `io_uring` transition for storage and networking.~~ Done: file I/O, peer wire, connect, and accept all use io_uring.
- Transition remaining I/O to io_uring: HTTP tracker, file open/close, batched event loop for multi-peer.
- Add broader integration coverage around CLI workflows and tracker compatibility.

## Known Issues

- ~~In the verified local `opentracker` swarm demo, the downloader could receive its own announced endpoint back.~~ Resolved: self-peers are now filtered before connection attempts.
- The packaged Ubuntu `opentracker` build used by `scripts/tracker.sh` is not open-by-default for arbitrary torrents. It requires explicit info-hash whitelisting, so tracker demos must pass `--whitelist-hash`.
- Seeder behavior is intentionally narrow: one listening socket, one inbound peer, sequential serving, and exit after disconnect.
- Resume currently depends on full piece recheck, which is correct but can become expensive on large datasets.
- ~~The runtime still uses conventional syscalls.~~ Resolved: hot-path file and network I/O now routes through io_uring. HTTP tracker requests still use conventional I/O via `std.http.Client`.
- Some restricted or sandboxed environments can interfere with local tracker startup and socket behavior. Validate the swarm demo in a normal host shell when tracker setup looks suspect.

## Last Verified Milestone

- `torrent: add seeding and local swarm demo` (`2497989`)
- Verified with:
  - `mise exec -- zig build test`
  - `mise exec -- zig build`
  - `./scripts/demo_swarm.sh`
