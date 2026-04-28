# Kqueue file-op bifurcation — 2026-04-30

Splits the original `KqueueIO` into two file-op-strategy variants:
`KqueuePosixIO` (rename of the original) and `KqueueMmapIO` (new). The
readiness layer is identical; only the file-op submission methods
diverge. Mirrors the parallel `worktree-epoll-bifurcation` engineer's
`EpollPosixIO` / `EpollMmapIO` split on the Linux side.

Branch: `worktree-kqueue-bifurcation`.

## Background

The 2026-04-29 KqueueIO MVP (`8384b6a`) shipped sockets + timers +
cancel for the macOS dev backend. File ops were stubbed as
`error.OperationNotSupported` pending a thread-pool follow-up.

The user clarified in this round that file-I/O strategy is its own
axis. There are **two valid file-I/O strategies for any readiness-based
backend**:

1. **POSIX**: positional `pread`/`pwrite`/`fsync`/`fcntl(F_PREALLOCATE)`
   syscalls offloaded to a thread pool. Predictable, matches io_uring's
   completion semantics, no implicit pagecache assumptions.
2. **mmap**: file mapped into the address space at first access;
   reads/writes become `memcpy`; durability via `msync(MS_SYNC)`.
   Zero-copy at the cost of page-fault latency on the EL thread.

The IoBackend enum becomes 6-way overall (sibling engineer's territory):
`io_uring`, `epoll_posix`, `epoll_mmap`, `kqueue_posix`, `kqueue_mmap`,
`sim`. This branch covers the kqueue half.

## What changed

### Commit 1 — `KqueueIO` → `KqueuePosixIO` rename (`a15c9de`)

Mechanical:
- `git mv src/io/kqueue_io.zig src/io/kqueue_posix_io.zig`
- 52 occurrences of `KqueueIO` → `KqueuePosixIO`
- `git mv tests/kqueue_io_test.zig tests/kqueue_posix_io_test.zig`
- Build steps `test-kqueue-io` → `test-kqueue-posix-io`,
  `test-kqueue-io-bridge` → `test-kqueue-posix-io-bridge`
- Module path renames in `src/io/root.zig`,
  `src/io/backend.zig` (transitional — sibling will overwrite at
  merge time), and `build.zig` (test wiring + IoBackend doc string)

The existing `-Dio=kqueue` flag continues to resolve to `KqueuePosixIO`
until the sibling's 6-way IoBackend split (`-Dio={kqueue_posix,kqueue_mmap}`)
lands and supersedes it. Documented in the IoBackend enum docstring.

### Commit 2 — `KqueueMmapIO` MVP (`d5d170e`)

New `src/io/kqueue_mmap_io.zig` (~960 LOC). Sibling of KqueuePosixIO;
the readiness layer copy-pastes from the POSIX file. Diff is in the
file-op submission methods:

| Op | Strategy | Notes |
|---|---|---|
| `read` | mmap + memcpy | fstats fd at first access; PROT_READ\|PROT_WRITE, MAP_SHARED. Bounds-checked: short-reads on partial overflow; reads entirely past EOF return 0. Optional `MADV.WILLNEED` (closest macOS equivalent of MAP_POPULATE). |
| `write` | mmap + memcpy | Same lazy-map. Writes past mapped EOF return `error.NoSpaceLeft` — the daemon is expected to size the file via fallocate first (PieceStore.init does this). |
| `fsync` | msync(MS_SYNC) | If the fd has no mapping yet, falls back to plain `fsync(2)` so PieceStore init's metadata-flush path keeps working. Darwin's msync has no datasync-only variant; both `op.datasync = true` and `false` map to MSF.SYNC. F_FULLFSYNC is the durability primitive but is out of scope for a dev backend. |
| `fallocate` | F_PREALLOCATE + ftruncate | Pattern from `tigerbeetle/src/io/darwin.zig:fs_allocate`. Tries ALLOCATECONTIG\|ALLOCATEALL first, falls back to ALLOCATEALL. Maps EOPNOTSUPP → `error.OperationNotSupported` so the daemon's existing truncate fallback path lights up uniformly. (No ENOTSUP on Darwin — only EOPNOTSUPP.) |
| `truncate` | unmap-if-mapped + ftruncate | Darwin lacks `mremap`, so a resize must drop the mapping; the next access remaps at the new size. |

Per-completion `KqueueState` is byte-identical to the POSIX sibling
(same field set, same layout). Kept as a parallel sibling type rather
than an `@import` shared header — either backend can be optimised
without forcing a ripple to the other.

The `fstore_t` extern struct is inlined locally with the field types
that match Darwin's kernel ABI. An inline test asserts size/alignment
match (drift detection vs the tigerbeetle reference).

Build wiring (additive; no overlap with the sibling engineer):
- `test-kqueue-mmap-io` standalone, cross-compile-clean
- `test-kqueue-mmap-io-bridge` varuna_mod-side, Linux-only by construction

### Commit 3 — Tests + docs (this commit)

This file plus a STATUS milestone entry.

## Validation

```
$ nix develop --command zig build                                                        # Linux io_uring: green
$ nix develop --command zig build test                                                   # Linux full suite: green
$ nix develop --command zig build test-kqueue-posix-io                                   # native POSIX inline: green
$ nix develop --command zig build test-kqueue-mmap-io                                    # native mmap inline: green
$ nix develop --command zig build -Dtarget=aarch64-macos -Dio=kqueue                     # bare cross-compile: clean
$ nix develop --command zig build test-kqueue-posix-io \
       -Dtarget=aarch64-macos -Dio=kqueue                                                # POSIX cross-compile: clean
$ nix develop --command zig build test-kqueue-mmap-io \
       -Dtarget=aarch64-macos -Dio=kqueue                                                # mmap cross-compile: clean
$ nix develop --command zig fmt .                                                        # clean
```

Test count delta from the inline mmap suite: **+8 inline tests** in
`src/io/kqueue_mmap_io.zig` covering the platform-portable subset
(state size, timer heap ordering, errno mapping, fstore_t layout,
makeCancelledResult tag preservation), plus **+3 platform-only**
(init/deinit, real timeout-via-kevent, full mmap round-trip
fallocate→write→fsync→read). The platform-only ones skip on Linux as
expected. The bridge test files add **+2** Linux-side tests each.

## What cross-compiles vs. what needs real-macOS validation

Cross-compile validates that the file *parses and type-checks* on the
macOS target. It does not guarantee runtime correctness. Items needing
eyes-on-Darwin validation:

1. **mmap round-trip semantics on a real darwin filesystem.** The
   inline `mmap-backed read/write round-trip` test — fallocate to 4096,
   write a pattern at offset 100, fsync, read it back — exercises every
   file-op method end-to-end. Cross-compiles cleanly; needs to be run
   on hardware. Failure modes to watch: mmap rejecting the
   PROT_READ|PROT_WRITE combo on certain darwin filesystems,
   F_PREALLOCATE returning an unmapped errno that lands in
   `posix.unexpectedErrno`, msync timing (MS_SYNC on darwin is
   synchronous but cheap; MS_ASYNC returns immediately).
2. **Page-fault latency on the EL thread.** The whole point of
   bifurcating from POSIX is so the user can compare. Real benchmarking
   requires a workload with working-set > RAM and a real macOS box.
3. **F_PREALLOCATE error mapping.** The Tigerbeetle reference treats
   several errnos as `unreachable`; the MVP maps them to
   `error.OperationNotSupported` / `error.BadFileDescriptor` /
   `error.InvalidArgument` / `error.FileTooBig`. Real-darwin runs
   should confirm these match actual returns.
4. **All KqueuePosixIO concerns inherited.** Section 3 of the
   2026-04-29 KqueueIO progress report lists 5 items; all still apply
   to KqueueMmapIO since the readiness layer is identical
   (EVFILT.READ/EV.ADD|ENABLE|ONESHOT mask values, posix.recv/send
   errno mapping on BSD, std.c.recvmsg/sendmsg signature compatibility,
   connect-with-deadline race ordering, posix.SOCK.NONBLOCK value
   match).

## Surprises vs. the design doc

1. **`fstore_t` alignment is 8, not 4.** The intuitive guess from
   "first field is c_uint" is wrong — the struct has three off_t
   (i64) fields, so the struct align is 8. Caught by an inline test.
   Worth flagging because a misaligned `@intFromPtr(&store)` would
   silently produce EINVAL on the F_PREALLOCATE call.
2. **No `ENOTSUP` on Darwin.** Linux distinguishes `ENOTSUP` from
   `EOPNOTSUPP` (same numeric value but separately defined); Darwin
   only has `EOPNOTSUPP`. Cross-compile catches the bad reference
   immediately if you write `.OPNOTSUPP, .NOTSUP =>` — but it's an
   easy paste-from-Linux trap.
3. **`std.heap.page_size_min` is the alignment that `posix.mmap`
   requires for both `ptr` and the returned slice.** Initially tried
   to use `@alignOf(u8)` (i.e. 1) and got a type error; the slice
   alignment is on the type, not the value. Required `[*]align(...)`
   in the `FileMapping.base` field declaration.
4. **`posix.MAP` is a packed struct on every platform, with a `TYPE`
   enum field.** Constructing an mmap call cross-platform is therefore
   `posix.mmap(ptr, len, prot, .{ .TYPE = .SHARED }, fd, 0)` — clean
   and platform-agnostic at the call site, even though the underlying
   bit layouts diverge.
5. **The kqueue file does not need `_ = kqueue_io;` in `src/io/root.zig`'s
   test block to compile** (the original didn't have one), but the brief
   asked for it and adding it caused no test failures. Followed the brief.

## Coordination notes

- **Sibling engineer (`worktree-epoll-bifurcation`)** owns the IoBackend
  enum split (3-way → 6-way) and the dispatch in `src/io/backend.zig`.
  My branch leaves the existing `-Dio=kqueue` flag in place pointing
  at `KqueuePosixIO`; sibling's merge will retire that flag in favour
  of `kqueue_posix` / `kqueue_mmap`.
- **Expected merge conflicts:**
  - `build.zig`: both engineers add new test wiring entries. Conflicts
    are line-position only.
  - `src/io/root.zig`: both engineers add module references. Same
    shape, same resolution.
  - `src/io/backend.zig`: sibling's 6-way dispatch supersedes my
    1-line transitional import-rename. Take sibling's version
    wholesale; ensure my new file paths
    (`kqueue_posix_io_mod`/`kqueue_mmap_io_mod`) appear in the
    final dispatch.
- **Contract (`src/io/io_interface.zig`)**: untouched, as per the
  brief. No surface required modification for the bifurcation, matching
  the design doc's prediction.

## Key code references

- `src/io/kqueue_posix_io.zig:1-25` — module docstring (now flags the
  bifurcation explicitly)
- `src/io/kqueue_mmap_io.zig:1-58` — module docstring (file-op
  strategy, why mmap)
- `src/io/kqueue_mmap_io.zig:158-172` — `fstore_t` and Darwin
  F_PREALLOCATE flag constants
- `src/io/kqueue_mmap_io.zig:475-525` — `getOrMap` / `unmapFile`
  helpers
- `src/io/kqueue_mmap_io.zig:732-754` — `read` (mmap memcpy)
- `src/io/kqueue_mmap_io.zig:756-775` — `write` (mmap memcpy)
- `src/io/kqueue_mmap_io.zig:777-808` — `fsync` (msync, with fsync(2)
  fallback for unmapped fds)
- `src/io/kqueue_mmap_io.zig:810-852` — `fallocate` (F_PREALLOCATE +
  ftruncate)
- `src/io/kqueue_mmap_io.zig:854-866` — `truncate` (unmap + ftruncate)
- `src/io/kqueue_mmap_io.zig:1010-1077` — full mmap round-trip test
- `build.zig:421-475` — `test-kqueue-mmap-io` build wiring
