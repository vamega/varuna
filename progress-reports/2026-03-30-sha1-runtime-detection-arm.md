# SHA-1 Runtime CPU Detection and ARM Support

## What was done

Rewrote `src/crypto/sha1.zig` to replace comptime SHA-NI detection with runtime CPU detection and added AArch64 SHA1 crypto extension support.

### Changes

1. **Runtime x86_64 detection**: Uses CPUID inline assembly (leaf 7 for SHA bit 29, leaf 1 for SSE4.1 bit 19) instead of `builtin.cpu.has(.x86, .sha)`. A binary compiled with `-Dcpu=baseline` or on a non-SHA-NI machine will now use SHA-NI when run on a capable CPU.

2. **AArch64 SHA1 extensions**: Full implementation using ARM Crypto Extension instructions (`sha1c`, `sha1p`, `sha1m`, `sha1h`, `sha1su0`, `sha1su1`) via inline assembly. Detection via `getauxval(AT_HWCAP)` checking `HWCAP_SHA1` on Linux.

3. **Atomic cached detection**: Detection runs once on first use. Result stored in `std.atomic.Value(Accel)` with acquire/release ordering. The `Accel` enum uses `u8` backing to satisfy Zig's extern-compatible atomic requirements.

4. **Public API changes**:
   - `hasShaNi()` now returns true for either x86 SHA-NI or ARM SHA1 hardware.
   - New `accel()` function returns the specific backend: `.software`, `.x86_sha_ni`, or `.aarch64_sha1`.
   - Benchmark output updated to show `sha1_accel=<backend>`.

### Key files
- `src/crypto/sha1.zig` -- all detection, dispatch, and ARM implementation
- `src/bench/main.zig:111` -- updated benchmark reporting
- `STATUS.md:58` -- updated status entry
- `docs/future-features.md:15-25` -- updated feature description

## What was learned

- Zig 0.15 inline asm uses `[_]` for anonymous output/input names, not literal `_` discard. The compiler treats asm outputs as "used" so explicit `_ = var` discards are forbidden.
- `std.atomic.Value(T)` requires `T` to be extern-compatible. A bare `enum` has a `u2` tag which is not extern. Solution: explicit `enum(u8)` backing type.
- Zig's `zig fmt` auto-upgrades legacy asm clobber syntax (string-based `"v3"`) to the new struct syntax (`.{ .v3 = true }`).
- ARM SHA1 instructions use a different state layout than x86 SHA-NI. ARM keeps ABCD in natural order in a 128-bit vector and E as a scalar, while x86 reverses word order in the XMM register.

## Remaining work

- The AArch64 path is implemented but untested on real hardware (this is an x86_64 development machine). Correctness is ensured by the software fallback tests, but the ARM asm path needs validation on actual ARM hardware.
- Cross-compilation test: `zig build -Dtarget=aarch64-linux` should compile cleanly (ARM asm is guarded by arch checks).
