# Performance Tooling

Varuna is expected to move toward aggressive `io_uring` usage over time. This directory holds the profiling and syscall-inspection playbook used to measure what the binary actually does today.

Generated artifacts should go under `perf/output/`.

## Prerequisites

These tools are external Linux packages, not Zig dependencies. The helper steps in `build.zig` expect the following binaries to be present on the host:

- `strace`
- `perf`
- `bpftrace`

On many distributions this means packages similar to `strace`, `linux-perf` or `perf`, and `bpftrace`.
On Ubuntu and WSL, `/usr/bin/perf` may be a wrapper script that refuses to run unless an exact kernel-matched backend exists. The build helpers in `build.zig` detect and prefer a real backend binary from `/usr/lib/linux-tools.../perf` when one is installed.

## Goals

- Confirm which syscalls are still used directly instead of through `io_uring`.
- Find CPU hotspots and call stacks before optimizing blindly.
- Keep a repeatable workflow for comparing changes across iterations.

## Build-Step Helpers

These commands build `varuna` first and then run it under the selected tool. Pass normal `varuna` CLI arguments after `--`.

- `zig build trace-syscalls -- banner`
  Writes a full syscall trace to `perf/output/strace.log`.
- `zig build perf-stat -- banner`
  Writes `perf stat` counters to `perf/output/perf-stat.txt`.
- `zig build perf-record -- banner`
  Writes sampled profiling data to `perf/output/perf.data`.

## Direct Tool Usage

Fast syscall summary:

```bash
strace -f -yy -c ./zig-out/bin/varuna banner
```

Full syscall trace:

```bash
strace -f -yy -s 256 -o perf/output/strace.log ./zig-out/bin/varuna banner
```

CPU counters:

```bash
perf stat -d --output perf/output/perf-stat.txt ./zig-out/bin/varuna banner
```

If `/usr/bin/perf` prints `perf not found for kernel ...`, run the real backend directly instead:

```bash
/usr/lib/linux-tools-*/perf stat -d --output perf/output/perf-stat.txt ./zig-out/bin/varuna banner
```

Sampled profile:

```bash
perf record -o perf/output/perf.data --call-graph dwarf ./zig-out/bin/varuna banner
perf report -i perf/output/perf.data
```

And likewise for direct backend invocation:

```bash
/usr/lib/linux-tools-*/perf record -o perf/output/perf.data --call-graph dwarf ./zig-out/bin/varuna banner
/usr/lib/linux-tools-*/perf report -i perf/output/perf.data
```

## eBPF / bpftrace Strategy

Use `bpftrace` when you need targeted kernel-level visibility rather than a full `strace` log.
This generally requires running as root.

Count all syscall entry tracepoints for the running process:

```bash
sudo bpftrace -e 'tracepoint:syscalls:sys_enter_* /comm == "varuna"/ { @[probe] = count(); }'
```

Check whether `io_uring` entry is happening at all:

```bash
sudo bpftrace -e 'tracepoint:syscalls:sys_enter_io_uring_enter /comm == "varuna"/ { @io_uring_enter = count(); }'
```

Look for fallback blocking I/O syscalls:

```bash
sudo bpftrace -e '
tracepoint:syscalls:sys_enter_read /comm == "varuna"/ { @read = count(); }
tracepoint:syscalls:sys_enter_write /comm == "varuna"/ { @write = count(); }
tracepoint:syscalls:sys_enter_recvfrom /comm == "varuna"/ { @recvfrom = count(); }
tracepoint:syscalls:sys_enter_sendto /comm == "varuna"/ { @sendto = count(); }
'
```

## Benchmark Baselines (ReleaseFast, 2026-03-25)

Host: WSL2, kernel 6.6.87.2, x86_64

| Benchmark | Per-iteration | Throughput | Notes |
|-----------|--------------|------------|-------|
| kernel_parser | <1ns | N/A | Compiler optimizes away in release |
| bencode_parse | 79us | 32 MB/s | 200-entry dictionary |
| sha1_256kb | 228us | 1,096 MB/s | Software SHA-1, LLVM auto-vectorized |
| metainfo_parse | 36us | 37 MB/s | Full parse including info_hash |

SHA-1 at 1.1 GB/s means piece verification is not a bottleneck for typical network speeds (<100 MB/s). Hardware SHA-NI would add ~2x but is not urgent.

## Interpretation Notes

- A minimal-client build that still shows `read`, `write`, `connect`, `recvfrom`, or `sendto` is expected until the networking and storage paths are moved to `io_uring`.
- Treat unexpected `openat`, `statx`, `futex`, or timer-heavy behavior as prompts to inspect startup, buffering, and lock behavior.
- Record which command was run and what changed in [DECISIONS.md](../DECISIONS.md) when a profiling pass leads to a design choice.
