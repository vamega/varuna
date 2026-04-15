# Syscall Report Rewrite — bpftrace Startup Capture

**Date:** 2026-04-15

## What Changed

Rewrote `scripts/syscall_report.sh` to capture ALL daemon syscalls from initialization.

### Key fixes:
1. **bpftrace starts BEFORE daemon** — tracepoints attach system-wide via `comm == "varuna"`, so every syscall from the first `execve` is captured
2. **WSL2 compatibility** — uses `comm == "varuna"` filter instead of PID-based filtering (bpftrace `pid` is TID on WSL2, not TGID)
3. **`--invoke` mode** — `bpftrace -c /path/to/varuna` launches daemon as a child, guaranteed zero-miss coverage
4. **Factored out Python parsing** — single `PARSE_SCRIPT` variable replaces 3 copy-pasted parser blocks
5. **Cleaner output** — grouped by io_uring ops, direct I/O violations, and other syscalls

### Two modes:
- **Default (per-phase)**: bpftrace attaches first, then daemon starts. Separate reports for startup, torrent 1, torrent 2.
- **`--invoke`**: `bpftrace -c` spawns daemon. Single combined report covering entire lifetime.

## What Was Learned

- `bpftrace -c` rejects shell scripts from user-writable tmp dirs (security). Must pass the binary directly.
- `bpftrace -c "/bin/bash -c 'cmd'"` doesn't work — bpftrace passes the whole string to `execvp`, doesn't shell-parse it. Use `cd` before `bpftrace -c /binary`.
- Kernel tracepoints are system-wide: attaching `tracepoint:raw_syscalls:sys_enter` BEFORE a process starts means the first syscall is captured.

## Key Code Reference
- `scripts/syscall_report.sh` — rewritten script
