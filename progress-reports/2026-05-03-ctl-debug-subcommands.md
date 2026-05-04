# Dedicated ctl diagnostic subcommands

## What changed and why

- Added read-only `varuna-ctl` diagnostic request parsing for `peers`, `conn-diagnostics`, `diagnostics`, `trackers`, `properties`, and `maindata`.
- Centralized diagnostic GET path construction so common real-torrent diagnostics no longer require `varuna-ctl api get ...`, while keeping `api get` unchanged as an escape hatch.
- Wired the parsed diagnostics through the existing ctl GET path and `api_client.Client` facade.
- Replaced the incomplete optional `watch` experiment with focused parser/path tests because a maintainable watch command needs a separate JSON summarization design.

## What was learned

- `varuna-ctl` already had a one-off `conn-diag` command; it is now handled by the shared diagnostics parser as a compatibility alias alongside the requested `conn-diagnostics` and `diagnostics`.
- The worktree's Nix flake is hard-coded to `x86_64-linux`, while this environment is `aarch64-linux`; validation used `nix run nixpkgs#zig_0_15 -- ...` to get Zig 0.15.2.

## Remaining issues or follow-up

- No human formatter was added for these diagnostics. The commands print the raw API JSON body in both `--format human` and `--format json`, matching the current ctl behavior for similar GET commands.
- `watch` remains intentionally unimplemented until there is a small, tested JSON summary contract.

## Key code references

- `src/ctl/cli.zig:20` defines the diagnostic views and request shape.
- `src/ctl/cli.zig:69` builds the qBittorrent-compatible diagnostic GET paths with query encoding and `rid=0` defaults.
- `src/ctl/cli.zig:125` parses the dedicated diagnostic subcommands and aliases.
- `src/ctl/cli.zig:245` covers parser/path behavior for peers, diagnostics aliases, trackers, properties, maindata, and invalid options.
- `src/ctl/main.zig:76` dispatches diagnostic commands through `doGet` and the existing API client facade.
- `src/ctl/main.zig:583` documents the new commands in CLI usage output.
