# Real Torrent Performance Tuning

## What Changed

- Fixed a DHT lookup crash seen while downloading the Proxmox torrent. Active DHT lookups now store heap-owned `*Lookup` values instead of staging and copying large lookup payloads through tick-stack locals (`src/dht/dht.zig:269`, `src/dht/dht.zig:620`, `src/dht/dht.zig:1260`).
- Fixed a ReleaseFast-only DHT fanout bug: `RoutingTable.findClosest` cast the routing-table candidate count to `u8` before clamping. A table with 257 nodes wrapped to 1 in optimized builds, so fresh Ubuntu DHT searches queried one node and found no peers. The clamp now stays in `usize` until the final bounded result (`src/dht/routing_table.zig:180`).
- Kept uTP unconfirmed connect timeout collection independent of the retransmit batch so large batches cannot strand half-open peer slots (`src/net/utp_manager.zig:203`).
- Improved web-seed throughput by matching libtorrent's 16 MiB URL-seed request size and allowing 3 parallel requests per seed (`src/io/event_loop.zig:433`, `src/net/web_seed.zig:6`, `src/net/web_seed.zig:23`).
- Reused HTTPS web-seed connections through the HTTP executor TLS pool instead of handshaking each range request. This was the main Deepin web-seed speedup (`src/io/http_executor.zig:280`, `src/io/http_executor.zig:313`, `src/io/http_executor.zig:334`).
- Accounted web-seed downloaded bytes and derived visible completed bytes from verified piece state, so web-seed-only downloads report real progress and speed (`src/io/web_seed_handler.zig:429`, `src/torrent/piece_tracker.zig:518`, `src/daemon/torrent_session.zig`).
- Added peer diagnostics for request target depth and web-seed active request state to make live swarm runs easier to interpret (`src/io/types.zig:130`, `src/daemon/session_manager.zig:1361`, `src/daemon/session_manager.zig:1981`).

## What Was Learned

- DHT lookup ownership was a real stability issue. Proxmox uTP-only previously crashed in `Lookup.seed`; after heap-owned active lookups it completed 1.48 GB in 149s.
- Deepin's web seed was bottlenecked by HTTPS connection setup. After HTTPS pooling plus 16 MiB/3-way web-seed ranges, Deepin uTP-only completed 6.80 GB in 178s.
- Ubuntu mixed TCP+uTP is now fast: 6.52 GB completed in 119s, comparable to the qBittorrent mixed control at 111s.
- Ubuntu uTP-only is near the target band under current network conditions. Varuna's plaintext uTP probe downloaded 3.26 GB in 240s; a same-window qBittorrent uTP-only control downloaded 4.05 GB in 242s, about 19% faster.
- Raising uTP request depth to 256 was tested and rejected. Live diagnostics showed request queues were already full and the run slowed down, so the immediate uTP-only limiter is not request starvation.
- In a 3-torrent mixed run, Varuna downloaded 14.19 GB in 240s: Proxmox complete, Ubuntu 99.8%, Deepin 91.3%. The matching qBittorrent multi run finished Proxmox and Deepin quickly but starved Ubuntu almost completely under the temporary harness, so that control is not a clean aggregate comparison yet.
- The ReleaseFast DHT wraparound exactly explained the fresh Ubuntu zero-progress run: diagnostics showed `dht_nodes=257`, but the daemon log reported `get_peers ... 1 nodes queried`. After the clamp fix, the same Ubuntu uTP-only case started downloading within 20 seconds and completed 6.52 GB in 547s. A same-window qBittorrent control completed in 576s.
- After the DHT fix, a 3-torrent Varuna mixed run completed all requested torrents in 350s: Proxmox in ~56s, Deepin in ~259s, Ubuntu in ~350s. The matching qBittorrent multi control had Proxmox and Deepin complete quickly but only reached about 75% on Ubuntu by 422s.

## Remaining Issues

- The temporary qBittorrent multi-torrent harness needs better settings before it can serve as a strict fairness control; it appears to concentrate connection work on two torrents and leave Ubuntu nearly idle.
- uTP-only now meets the under-10-minute Ubuntu target in the measured same-window run. The next likely payoff is uTP loss recovery/LEDBAT parity with libtorrent, not larger request queues.
- uTP seeding/upload still has extra allocation and copy layers compared with libtorrent's write-buffer path; this matters for uTP-only swarms and future seeding benchmarks.
- The one-off benchmark helpers currently live under `/tmp/varuna-real-torrents`. If this workflow continues, move a cleaned-up version into `src/perf/` or `scripts/` and expose it through `build.zig`.

## Verification

- `nix run nixpkgs#zig_0_15 -- build test-dht test-dht-krpc-buggify test-transport test-utp test-web-seed test-api --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `nix run nixpkgs#zig_0_15 -- build test-dht --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `nix run nixpkgs#zig_0_15 -- build -Doptimize=ReleaseFast --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `nix run nixpkgs#zig_0_15 -- build test --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
