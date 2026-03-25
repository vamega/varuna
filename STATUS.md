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

## Next

- Filter or otherwise handle self-peers more cleanly so the downloader does not first attempt its own advertised endpoint in the local tracker workflow.
- Improve tracker lifecycle behavior:
  - send `completed`/`stopped` events where appropriate
  - handle stale peers and tracker edge cases more deliberately
  - validate behavior against more private-tracker expectations
- Widen peer behavior past the current minimal contract:
  - more than one active peer
  - better piece selection than strict sequential download
  - stronger peer/session state handling
- Replace full startup-only resume with persisted resume state.
- Begin the actual `io_uring` transition for storage and networking, then re-run syscall profiling to confirm fallback syscalls are disappearing.
- Add broader integration coverage around CLI workflows and tracker compatibility.

## Known Issues

- In the verified local `opentracker` swarm demo, the downloader can receive its own announced `127.0.0.1:<download-port>` endpoint back in the compact peer list. The current client tolerates this by failing that self-connection and then trying the next peer.
- The packaged Ubuntu `opentracker` build used by `scripts/tracker.sh` is not open-by-default for arbitrary torrents. It requires explicit info-hash whitelisting, so tracker demos must pass `--whitelist-hash`.
- Seeder behavior is intentionally narrow: one listening socket, one inbound peer, sequential serving, and exit after disconnect.
- Resume currently depends on full piece recheck, which is correct but can become expensive on large datasets.
- The runtime still uses conventional syscalls. `io_uring` is a project goal, not current behavior.
- Some restricted or sandboxed environments can interfere with local tracker startup and socket behavior. Validate the swarm demo in a normal host shell when tracker setup looks suspect.

## Last Verified Milestone

- `torrent: add seeding and local swarm demo` (`2497989`)
- Verified with:
  - `mise exec -- zig build test`
  - `mise exec -- zig build`
  - `./scripts/demo_swarm.sh`
