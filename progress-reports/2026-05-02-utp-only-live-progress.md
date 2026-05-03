# uTP-only live progress path

## What changed and why

- Fixed tracker-discovered peer integration to call `addPeerAutoTransport` instead of the TCP-only `addPeerForTorrent`, so `utp_only` sessions actually initiate outbound uTP for tracker peers.
- Tightened auto-transport fallback so uTP setup failures only fall back to TCP when outbound TCP is enabled.
- Wired `TRANSPORT_MODE` through `scripts/demo_swarm.sh` so the live swarm harness can generate `transport = "utp_only"` configs instead of always using legacy `enable_utp = true`.
- Added focused regression coverage for tracker peer integration and strict uTP-only fallback behavior.

## What was learned

- The live no-progress path was not in the uTP byte stream itself. Tracker announce results entered `TorrentSession.addPeersToEventLoop`, which bypassed transport selection and always scheduled TCP outbound peers.
- The default live harness command did not prove uTP-only behavior because `TRANSPORT_MODE` was ignored by the generated daemon TOML.
- With `transport = "utp_only"` in both daemon configs, the io_uring live swarm completes and logs outbound/inbound uTP establishment.

## Remaining issues or follow-up

- The live command requires `opentracker` on `PATH`; in this worktree it passed when run inside `nix shell nixpkgs#opentracker`.
- Some uTP listener tests still emit expected cancel/close warnings on teardown; not changed here.
- Epoll large-payload behavior was not touched.

## Key references

- `src/daemon/torrent_session.zig:682` - tracker peers now enter the auto-transport path.
- `src/io/event_loop.zig:1182` - uTP setup fallback now respects `outgoing_tcp`.
- `tests/torrent_session_test.zig:17` - regression for tracker peers in `utp_only`.
- `tests/transport_disposition_test.zig:133` - regression for strict uTP-only fallback behavior.
- `scripts/demo_swarm.sh:161` - live harness validates and emits `TRANSPORT_MODE`.
- `scripts/demo_swarm.sh:233` - seeder config writes the resolved transport line.
- `scripts/demo_swarm.sh:254` - downloader config writes the resolved transport line.
