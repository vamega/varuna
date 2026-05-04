# Zig Automation Harness

## What Changed

- Added `src/automation/shell.zig`, a small repository automation helper inspired by TigerBeetle's `src/shell.zig` and attributed in the file header. It wraps checked subprocess execution, logged background processes, temp/work directories, TCP readiness checks, and blocking file helpers without importing daemon/core modules.
- Added `src/automation/main.zig` with three commands:
  - `swarm`: local opentracker + seeder daemon + downloader daemon transfer, replacing the build-facing `scripts/demo_swarm.sh` path.
  - `backend-swarm`: multi-backend local swarm matrix, replacing the build-facing `scripts/backend_swarm_matrix.sh` path.
  - `real-torrents`: public-torrent Varuna performance harness for Proxmox, Ubuntu 26, and Deepin by default.
- Rewired `zig build test-swarm`, `zig build test-swarm-backends`, and `zig build perf-swarm-backends` to run `zig-out/bin/varuna-automation` instead of shell scripts.
- Added `zig build perf-real-torrents -- ...` for repeatable real-swarm measurement under the Zig automation binary.
- Updated `AGENTS.md` and `perf/README.md` to document the preference for Zig automation over new shell scripts and to describe the new real-torrent harness.

## What Was Learned

- The old local swarm and backend matrix scripts were mostly process orchestration, config generation, API polling, and TSV writing. Those map cleanly to a standalone Zig automation binary without involving the daemon IO abstraction.
- Keeping automation outside `src/io` and outside the `varuna` module prevents tooling convenience APIs from leaking into daemon paths where blocking I/O would be unacceptable.
- qBittorrent control automation needs a separate pass because current qBittorrent versions generate temporary WebUI credentials unless a profile is configured carefully. The first real-torrent harness therefore measures Varuna and leaves qBittorrent as a documented follow-up rather than baking in fragile client setup.

## Remaining Issues

- The legacy shell scripts still exist for compatibility and manual fallback. They should be migrated or deleted incrementally as each workflow is proven under `src/automation/`.
- `real-torrents` depends on `curl` for downloading `.torrent` files and talking to the local API. That keeps the first pass small, but a future iteration can move the localhost API calls to a tiny Zig HTTP client.
- `perf-real-torrents` currently measures Varuna only. Add qBittorrent control runs once the profile/auth setup is deterministic.
- `test-swarm` and backend swarm steps still require `opentracker` on `PATH`, matching the previous shell-script dependency.

## Verification

- `nix run nixpkgs#zig_0_15 -- fmt src/automation build.zig`
- `nix run nixpkgs#zig_0_15 -- build --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `nix shell nixpkgs#opentracker nixpkgs#curl --command ./zig-out/bin/varuna-automation swarm --skip-build --payload-bytes 1048576 --timeout 60 --work-dir /tmp/varuna-automation-smoke`
- `nix shell nixpkgs#zig_0_15 nixpkgs#opentracker nixpkgs#curl --command zig build test-swarm --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `nix run nixpkgs#zig_0_15 -- build test --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`

## Key Code References

- `src/automation/shell.zig`
- `src/automation/main.zig`
- `build.zig`
- `AGENTS.md`
- `perf/README.md`
