# Real Torrent Parity Harness

## What Changed

- Added `varuna-automation real-torrent-parity`, a committed Zig harness that runs the same public torrent set through Varuna and qBittorrent.
- Added `zig build perf-real-torrent-parity -- ...` as the repeatable entry point. Defaults cover Proxmox, Ubuntu 26, and Deepin across mixed TCP+uTP and uTP-only transports for both clients.
- The parity harness writes per-client `samples.tsv` / `summary.tsv` files and a top-level aggregate `summary.tsv` with client, transport, completion count, downloaded bytes, elapsed seconds, and average MiB/s.
- Added `qbittorrent-nox` to the Nix `performance-tools` shell and documented the split between Varuna-only and qBittorrent-control public-swarm runs.

## What Was Learned

- qBittorrent's WebAPI transport preference is `bittorrent_protocol`: `0` for TCP+uTP, `1` for TCP-only, and `2` for uTP-only. This matches `reference-codebases/qbittorrent/src/base/bittorrent/session.h`.
- Current qBittorrent-nox prints a temporary WebUI password on first launch when a fresh profile has no configured password. The harness handles that by parsing the startup logs and logging in through the WebAPI rather than relying on a pre-baked profile.

## Remaining Issues

- The harness gives a reproducible comparison surface, but real public swarms are still noisy. Treat one run as evidence, not a permanent ranking.
- The qBittorrent control uses the stock client settings plus explicit transport/fairness preferences. If future evidence shows torrent starvation again, tune qBittorrent preferences in the harness rather than comparing against ad hoc runs.

## Key References

- `src/automation/main.zig:219` - `real-torrent-parity` command dispatch.
- `src/automation/main.zig:918` - parity matrix runner.
- `src/automation/main.zig:969` - qBittorrent WebAPI runner.
- `build.zig:1391` - `perf-real-torrent-parity` build step.
- `perf/README.md:41` - documented parity command.
