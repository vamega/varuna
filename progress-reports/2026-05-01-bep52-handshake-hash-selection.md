# BEP 52 Handshake Hash Selection

## What changed and why

- Outbound peers now carry a selected 20-byte swarm hash through TCP/uTP peer creation and into MSE SKEY plus the BitTorrent handshake. Default selection stays v1 for v1 and hybrid torrents, and uses the truncated v2 SHA-256 hash for pure-v2 torrents.
- DHT peer results now pass their lookup target into the outbound peer pipeline, preserving a v2-selected swarm hash for hybrid or v2 peers discovered from v2 lookups.
- Inbound TCP and uTP handshake responses echo the info-hash variant the remote peer used after the existing v1/v2 match succeeds.
- Added exact handshake-byte tests for v1, hybrid-default, pure-v2, and DHT-selected hybrid behavior, plus a direct DHT-result preservation test.

## What was learned

- `TorrentContext.info_hash_v2` already stores the 20-byte truncated v2 hash needed for BEP 52 handshakes.
- `DhtEngine.PeerResult.info_hash` is the selected lookup target, so no DHT engine shape change was needed; the loss happened when `dht_handler` converted results back to only `torrent_id`.
- This environment has no `zig` or `mise` on `PATH`. A temporary Nix shell with `zig_0_15`, `sqlite`, `liburing`, and `pkg-config` was used. The repository flake defaults to `x86_64-linux`, while this host is `aarch64`.

## Remaining issues or follow-up

- Outbound `hash_request` and v2 recheck remain intentionally out of scope for later BEP 52 work.
- Full `zig build test -Dcrypto=stdlib -j1 --summary failures` is still blocked by existing unrelated failures: `src/storage/sqlite3.zig:76` `SQLITE_TRANSIENT` pointer alignment compile errors across API/storage tests, plus existing `sim_multi_source_eventloop_test` and `sim_smart_ban_phase12_eventloop_test` failures.
- The repo default crypto backend still hits an unrelated AArch64 assembly issue here; focused tests were run with `-Dcrypto=stdlib`.

## Key code references

- `src/io/event_loop.zig:1090` selects and validates default/explicit swarm hashes.
- `src/io/event_loop.zig:1134` and `src/io/event_loop.zig:1429` preserve selected hashes through TCP/uTP outbound peer creation.
- `src/io/peer_handler.zig:280` uses the selected hash for MSE SKEY, and `src/io/peer_handler.zig:325` writes it into the TCP BitTorrent handshake.
- `src/io/peer_handler.zig:766` and `src/io/utp_handler.zig:503` echo the inbound hash variant in server-side handshake responses.
- `src/io/dht_handler.zig:80` forwards DHT lookup-selected hashes into outbound peer creation.
- `tests/event_loop_health_test.zig:269` covers exact handshake bytes for v1/hybrid/pure-v2/DHT-selected cases, and `tests/event_loop_health_test.zig:292` covers DHT result hash preservation.
