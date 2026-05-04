# Zig Script Migration

## What changed

- Replaced the remaining repository shell entrypoints with `varuna-automation` commands and `zig build` steps.
- Kept the Python helpers (`tcp_proxy.py`, `web_seed_server.py`) because they are test servers/helpers rather than shell orchestration.
- Extended `varuna-automation swarm` to cover the old live-swarm debug knobs: explicit port overrides, `TRANSPORT_MODE=all` compatibility, optional strace wrapping, tracker log paths, failure log tails, and perf matrix run logs.
- Added Zig automation commands for tracker startup, worktree setup, strace-summary validation, large transfer stress, daemon swarm, daemon seed serving, web seed e2e, selective download, and public-torrent e2e.
- Ported the Docker qBittorrent cross-client conformance runner to `zig build test-docker-conformance`.
- Moved current docs from shell paths to `zig build` commands, and made the Nix dev shell expose Python + opentracker for the migrated e2e commands.

## What was learned

- The web seed Python helper needed to be threaded. A single kept-alive web-seed connection from the daemon could block `_reset`/`_stats` control requests in the migrated harness, so it now uses `ThreadingHTTPServer`.
- The previous flake shape was hard-coded to `x86_64-linux`; evaluating it on this aarch64 host failed. The dev shell is now emitted for both `x86_64-linux` and `aarch64-linux`.
- The standalone automation binary is independent enough to compile-check without pulling the daemon dependency graph, which is useful when working on repo automation.

## Remaining issues

- Historical progress reports still mention deleted shell paths; they were left as historical records.
- `test_transfer_matrix.sh` was replaced by focused daemon-based Zig commands rather than a byte-for-byte giant matrix clone. The practical coverage now lives in `test-swarm`, `test-swarm-backends`, `test-large-transfer`, and the existing unit/sim tests.

## Validation

- `zig build -Dtls=none --search-prefix <sqlite>`
- `zig build test-swarm -Dtls=none --search-prefix <sqlite>`
- `zig build test-selective-download -Dtls=none --search-prefix <sqlite>`
- `zig build test-web-seed-e2e -Dtls=none --search-prefix <sqlite>`
- `zig build validate-strace -- <synthetic-summary>`
- `nix flake check`

## Key references

- `src/automation/main.zig:159` - command dispatch and user-facing automation command list.
- `src/automation/main.zig:359` - backend swarm summary/run-log output.
- `src/automation/main.zig:450` - live swarm port/runtime backend handling.
- `src/automation/main.zig:1186` - Zig worktree setup replacement.
- `src/automation/main.zig:1288` - large-transfer command.
- `src/automation/main.zig:1407` - web-seed e2e command.
- `src/automation/main.zig:1497` - selective-download command.
- `src/automation/main.zig:1623` - Docker conformance command.
- `src/automation/shell.zig:195` - managed process wait/stop lifecycle.
- `build.zig:1454` - Docker conformance build-step wiring.
- `scripts/web_seed_server.py:20` - threaded web seed test server.
- `flake.nix:18` - multi-system dev shell with opentracker/Python.
