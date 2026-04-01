## What Was Done And Why

- Updated the profiling build steps to resolve a real `perf` backend before falling back to plain `perf`. This fixes `zig build perf-stat` and `zig build perf-record` on Ubuntu/WSL hosts where `/usr/bin/perf` is only a wrapper script and refuses to run without an exact kernel-matched backend.
- Refreshed the profiling docs and decision log so the repository now documents the actual failure mode and workaround instead of saying a kernel-matched WSL package is required in all cases.

## What Was Learned

- On this Ubuntu 24.04 WSL host, `perf` is usable even though the running kernel is `6.6.87.2-microsoft-standard-WSL2` and the installed backend is from Ubuntu's `6.8.0-106` linux-tools package.
- The real problem was the Ubuntu wrapper at `/usr/bin/perf`, not root access or a hard kernel/userspace version block.
- `perf stat` and `perf record` both work through the real backend, but WSL still reports many hardware counters as unsupported. Software counters and sampled profiles remain usable.

## Remaining Issues Or Follow-Up Work

- If a host has multiple installed linux-tools backends, the build helper picks the highest versioned backend it can find. That is sufficient for the current Ubuntu/WSL packaging case, but it is still best-effort rather than a distro-specific contract.
- WSL hardware counter availability remains limited, so `perf stat -d` output should be interpreted accordingly.

## Code References

- `build.zig:199` selects the resolved `perf` executable for both profiling build steps.
- `build.zig:226` adds backend discovery across `/usr/lib/linux-tools/.../perf` and `/usr/lib/linux-tools-.../perf`.
- `build.zig:301` adds version-aware candidate ordering so the newest installed backend wins.
- `perf/README.md:16` documents the wrapper-script issue and direct-backend fallback.
- `DECISIONS.md:141` records the WSL backend-detection decision and observed behavior.
