# 2026-05-01 Demo Swarm Baseline

## What changed

- No product code changed.
- Updated `STATUS.md` to close the stale `scripts/demo_swarm.sh` baseline regression entry after reproducing the current behavior.

## What was learned

- The real two-daemon swarm demo now completes on current `main` under the default io_uring backend.
- The script created a torrent, started opentracker, launched separate seeder/downloader daemons, downloaded the payload to `progress=1.0000`, and verified the transferred file with `cmp`.
- The earlier stalled-transfer note appears to have been made stale by subsequent peer-protocol / smart-ban / test-stability fixes rather than a dedicated demo-swarm patch.

## Remaining issues

- Cross-backend perf comparison can use `scripts/demo_swarm.sh` again as a smoke gate, but epoll backends still need separate validation.

## Key references

- `STATUS.md:306` - demo swarm baseline entry marked closed.
- `scripts/demo_swarm.sh` - real two-daemon transfer smoke test.

## Verification

- `env WORK_DIR=/tmp/varuna-swarm-debug-1 TRACKER_PORT=16969 SEED_PORT=16881 SEED_API_PORT=18081 DOWNLOAD_PORT=16882 DOWNLOAD_API_PORT=18082 LIBRARY_PATH=/nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2/lib nix shell nixpkgs#zig_0_15 nixpkgs#opentracker -c bash scripts/demo_swarm.sh`
- `env WORK_DIR=/tmp/varuna-swarm-debug-2 TRACKER_PORT=16970 SEED_PORT=16883 SEED_API_PORT=18083 DOWNLOAD_PORT=16884 DOWNLOAD_API_PORT=18084 LIBRARY_PATH=/nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2/lib nix shell nixpkgs#zig_0_15 nixpkgs#opentracker -c bash scripts/demo_swarm.sh`
