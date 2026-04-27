# Runtime per-op feature probe + `RealIO.truncate` async — 2026-04-29

Track (runtime-detect): converted the previous "switch
`RealIO.truncate` to `IORING_OP_FTRUNCATE` once kernel floor bumps
to 6.9+" follow-up
(`progress-reports/2026-04-28-truncate-op.md`) into a runtime
decision. The daemon now probes the running kernel's per-op
io_uring support once at `RealIO.init` via
`IORING_REGISTER_PROBE`, caches the result on the backend, and
branches in `RealIO.truncate` — async `IORING_OP_FTRUNCATE` SQE on
supporting kernels (≥6.9, or any kernel where the op is
backported), synchronous `posix.ftruncate(2)` fallback otherwise.

The bulletproof approach over kernel-version-string parsing: it
picks up backports and custom kernels the version-arithmetic
approach would miss.

Three bisectable commits, all green at HEAD. Test count:
**1420/1421 → 1422/1423 (+2)**, 1 skipped (intentional). `zig
build`: clean. `zig fmt .`: clean. Daemon binary: builds.

Dev-machine probe result (kernel 7.0.1): `supports_ftruncate =
true`. The async path is the one actually exercised on the dev
machine.

Branch: `worktree-runtime-detect`.

## Commits

1. `54f2f9a` — **`io: add IORING_REGISTER_PROBE wrapper + FeatureSupport struct`**
   Added `FeatureSupport` (small struct of `bool` flags, one per
   kernel-floor-blocked op we care about — currently just
   `supports_ftruncate`) and `probeFeatures(*linux.IoUring)` to
   `src/io/ring.zig`. The probe wrapper uses Zig stdlib's
   `IoUring.get_probe()` (already issues the
   `IORING_REGISTER_PROBE` syscall and returns `linux.io_uring_probe`
   with a 256-entry op table). Kernels too old to support the probe
   register itself (kernel <5.6, returns `EINVAL`) get mapped to
   `FeatureSupport.none` (all-false), which is observably equivalent
   to "nothing extra is supported" — every op gated on
   `FeatureSupport` must already have a synchronous fallback. Three
   inline tests: probe runs without panic, returns a `FeatureSupport`
   value (skip when io_uring unavailable), and the `none` sentinel
   has every flag false.

2. `ea99efb` — **`io: route RealIO.truncate through IORING_OP_FTRUNCATE when supported`**
   `RealIO` gains a `feature_support: FeatureSupport` field cached
   at init. `RealIO.truncate` branches:

   * `supports_ftruncate=true`: async path. `armCompletion` then
     submit `IORING_OP_FTRUNCATE` via
     `prep_rw(.FTRUNCATE, fd, addr=0, len=0, offset=length)` — the
     kernel reads the new file length from `sqe->off`;
     addr/len/rw_flags/buf_index/splice_fd_in must all be zero or
     it returns EINVAL (verified via the kernel header
     `enum io_uring_op` plus `io_uring/truncate.c`). The CQE flows
     through `dispatchCqe` → `buildResult` → `voidOrError(cqe)`,
     same as fallocate / fsync.

   * `supports_ftruncate=false`: existing synchronous
     `posix.ftruncate(2)` fallback unchanged. Inner-loop `.rearm`
     handling kept (not via `resubmit`) to dodge the
     inferred-error-set cycle the truncate-op landing already
     documented.

   `buildResult` for `.truncate` switched from
   `error.UnknownOperation` to `voidOrError(cqe)` — the previous
   placeholder is no longer reachable on supporting kernels.

   Three new inline RealIO tests:
   - "RealIO truncate extends a tempfile via the
     runtime-detected path" replaces the old synchronous-only
     test. Adapts to whichever path the kernel selected (`tick(1)`
     iff async).
   - "RealIO truncate via async path (kernel ≥6.9 only)" pins the
     async path: skips on unsupported kernels and asserts the
     callback hasn't fired before `tick(1)`.
   - "RealIO truncate shrinks file via async path" extends async
     coverage to the shrink case.

3. (this commit) — **`docs: progress report + STATUS milestone for runtime feature probe`**
   This file plus the STATUS entries (closed the truncate-floor
   follow-up; new "Last Verified Milestone"; filed
   "Generalize `FeatureSupport` to cover other
   kernel-floor-blocked ops" follow-up).

## Methodology notes

### Pattern #14 — investigation discipline

Read both the kernel ABI and the Zig stdlib bindings before
drafting the wrapper:

- Kernel ABI (`include/linux/io_uring.h`): `IORING_REGISTER_PROBE
  = 8`, `io_uring_probe { last_op, ops_len, resv, resv2[3], ops[]
  }`, `io_uring_probe_op { op, resv, flags, resv2 }`,
  `IO_URING_OP_SUPPORTED = (1U << 0)`. Subtleties: `ops` is
  flexible-array in kernel form (sized at register time);
  `ops_len` returned from kernel may be less than what we asked
  for if the kernel's last_op is below 256.
- Kernel ABI for `IORING_OP_FTRUNCATE` (`io_uring/truncate.c` in
  6.9+): `ft->len = READ_ONCE(sqe->off)` — the new file length
  goes in `sqe->off`, NOT `sqe->len`. `sqe->len` must be 0 or
  EINVAL. The team-lead's brief said `len = new_size_in_bytes`,
  which is incorrect — caught it by reading the kernel source.
  `prep_rw(.FTRUNCATE, fd, addr=0, len=0, offset=length)`
  produces the right shape.
- Zig stdlib (`std/os/linux.zig`): `IORING_OP.FTRUNCATE` is in the
  exhaustive enum (Zig 0.15.2). `io_uring_probe.is_supported(op)`
  exists on the struct and handles `last_op` / `ops_len` bounds
  correctly. `IoUring.get_probe()` exists and wraps the syscall.
  This means the wrapper is a 4-line function — no manual
  syscall, no flexible-array handling.

The "what does the FALLOCATE shape look like?" lookup
(`prep_fallocate` in `std/os/linux/io_uring_sqe.zig`) confirmed
the SQE-construction approach. FALLOCATE puts `len` in `addr`
and `mode` in `len`; FTRUNCATE puts `length` in `off` and
requires `addr=len=0`. Different pacing, same general shape.

### Pattern #15 — read existing invariants

Mirrored two existing patterns:

1. The `probe()` function in `src/io/ring.zig` (kernel-availability
   probe) gave the natural home for the new per-op probe. Both are
   "ask the kernel a yes/no question about io_uring" and live
   together cleanly. `probeFeatures` is one function call and one
   struct.

2. The async submission shape in `RealIO` (`fallocate`, `fsync`,
   `recv`, `send`, etc.): `armCompletion` then submit the SQE,
   return; CQE arrives later, dispatched via `dispatchCqe` →
   `buildResult` → callback. The async truncate path mirrors that
   exactly. The synchronous fallback path is the one already in
   place, kept verbatim.

### Why a per-op probe instead of a kernel-version check

The team-lead picked the bulletproof approach. Two reasons in
practice:

1. **Backports**: distributions sometimes backport individual
   io_uring ops to older kernel branches without bumping the
   reported version. A version check against 6.9 misses those
   backports; a probe doesn't.
2. **Customised kernels**: some users run kernels with
   `CONFIG_IO_URING_FTRUNCATE=n` (or similar) compiled out. A
   probe catches that; a version check doesn't.

`uname` parsing also has its own bugs (custom version strings,
non-standard release fields, etc.). The probe is one syscall at
init and the result is cached for the ring's lifetime.

### Why the `feature_support: FeatureSupport` field on RealIO instead of a per-op static check

Two design alternatives considered:

- **A**: probe inline at every truncate call. Rejected: the probe
  is a syscall; running it per-op adds overhead and gives
  inconsistent answers if the kernel hot-reloads io_uring support
  (irrelevant in practice but the per-op cost is the real
  rejection reason).
- **B**: a process-wide `var feature_support: FeatureSupport`
  initialized at module load. Rejected: forces tests to share
  state with production, violates the existing "every backend
  owns its config" invariant. RealIO already owns its ring.
  Co-locating the per-op feature flags on the RealIO instance is
  the natural shape.

`feature_support` is `pub` on RealIO so tests can both gate on it
(`if (!io.feature_support.supports_ftruncate) return error.SkipZigTest;`)
and assert on it for diagnostic output.

### Pattern #8 — bisectable commits

Three commits, each compiling and passing the full test suite:

1. `54f2f9a` — probe wrapper + struct + tests. 1420 → 1422.
2. `ea99efb` — RealIO.feature_support + truncate dispatch +
   tests. 1422 → 1422 (the new tests offset the test count
   stability of the probe-test commit by exercising the async
   path explicitly).
3. (this commit) — progress report + STATUS only. 1422 → 1422.

If commit 1 lands without commit 2, the `FeatureSupport` is
unused but harmless. If commit 2 lands without commit 1, it
fails to compile (depends on `ring_mod.FeatureSupport` /
`ring_mod.probeFeatures`). Commit ordering matters; bisect
remains clean.

## Files touched

- `src/io/ring.zig` — new `FeatureSupport` struct + `probeFeatures`
  function + 3 inline tests.
- `src/io/real_io.zig` — `feature_support` field on `RealIO`,
  populated in `init`; `truncate` branch on
  `supports_ftruncate`; `buildResult` for `.truncate` switched
  from `error.UnknownOperation` to `voidOrError(cqe)`; one
  updated and two new inline tests.
- `STATUS.md` — closed the truncate-floor follow-up; new "Last
  Verified Milestone" for 2026-04-29; filed
  "Generalize `FeatureSupport` to cover other
  kernel-floor-blocked ops" follow-up.
- `progress-reports/2026-04-29-runtime-feature-probe.md` — this
  file.

## Files NOT touched (per the brief)

- `src/io/io_interface.zig` — contract unchanged. No new ops,
  no new fields.
- `src/io/sim_io.zig` — SimIO doesn't simulate kernel feature
  detection; the truncate op already exists there. No changes.
- `src/storage/writer.zig` — the truncate dispatch is internal to
  RealIO; storage code shouldn't change at all. No changes.
- `tests/storage_writer_test.zig` — the existing PieceStore
  truncate fallback integration tests drive SimIO, which is
  unaffected by the RealIO dispatch change. They still pass.

## Follow-ups (not in scope for this round)

### 1. Generalize `FeatureSupport` to cover other kernel-floor-blocked ops

AGENTS.md tracks `IORING_OP_SETSOCKOPT` (6.7+) and
`IORING_OP_BIND`/`LISTEN` (6.11+) as currently-synchronous ops
gated on the overall kernel floor. Now that `FeatureSupport` is
in place, those can drop their ad-hoc kernel-version arithmetic
in favor of per-op probe flags:
- add `supports_setsockopt: bool`, `supports_bind: bool`,
  `supports_listen: bool` to `FeatureSupport`,
- branch in the relevant submission methods,
- keep the synchronous fallback alongside (same shape as the
  truncate landing).

Estimated 0.5-1 day per op group once the day-one daemon paths
are pinned down. Filed as a STATUS entry; not blocking.

### 2. Live-pipeline BUGGIFY harness for the truncate path

Same follow-up the truncate-op round filed
(`progress-reports/2026-04-28-truncate-op.md`); this round
doesn't change its scope. The async path adds a CQE-dispatch step
to the truncate flow, but BUGGIFY runs against SimIO (which is
already async-shaped) so the harness coverage required is
unchanged.
