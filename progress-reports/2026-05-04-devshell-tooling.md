# Devshell Tooling

## What Changed

- Added `curl` and `diffutils` to the default Nix dev shell. `diffutils` provides `cmp`, which the automation harness uses for transfer verification.
- Added a `performance-tools` Nix dev shell that layers `strace` and Linux `perf` on top of the default build/test shell.
- Documented the split between normal automation tooling and profiling tooling in `README.md`, `AGENTS.md`, and `perf/README.md`.

## What Was Learned

- The default shell already carried `opentracker` and `python3`, but not the `curl` and `cmp` commands that `src/automation/main.zig` invokes directly.
- `perf` remains host-sensitive on Linux/WSL even when available from Nix, so it belongs in an explicit profiling shell rather than the default shell.

## Remaining Issues

- Deeper profiling tools such as `bpftrace`, `heaptrack`, `valgrind`, and `pahole` remain documented as external host tools rather than devshell defaults.

## Key References

- `flake.nix:22` - default package list shared by both dev shells.
- `flake.nix:46` - `performance-tools` shell.
- `src/automation/main.zig:980` - `curl` usage in API helpers.
- `src/automation/main.zig:545` - `cmp` usage in transfer verification.
