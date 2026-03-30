# SHA-NI Hardware-Accelerated SHA-1

## What was done

Implemented SHA-NI (x86_64 SHA extensions) accelerated SHA-1 hashing in `src/crypto/sha1.zig`. Replaced all `std.crypto.hash.Sha1` usage across the codebase with the new module.

## Key files

- `src/crypto/sha1.zig` -- SHA-1 with SHA-NI acceleration and software fallback
- `src/crypto/root.zig` -- crypto module root
- `src/root.zig` -- added `crypto` module export
- `src/bench/main.zig` -- added comparative SHA-1 benchmarks (std vs SHA-NI, 256KB and 1MB)

### Files updated to use new SHA-1
- `src/io/hasher.zig` -- threadpool piece hasher (most critical hot path)
- `src/storage/verify.zig` -- piece recheck
- `src/io/peer_policy.zig` -- inline fallback verification
- `src/torrent/client.zig` -- test helper hash computation
- `src/torrent/create.zig` -- .torrent creation piece hashing
- `src/torrent/info_hash.zig` -- info hash computation

## Performance results (ReleaseFast)

| Buffer size | std.crypto.hash.Sha1 | SHA-NI (varuna) | Speedup |
|-------------|----------------------|-----------------|---------|
| 256 KB      | ~1,075 MB/s          | ~2,145 MB/s     | 2.0x    |
| 1 MB        | ~1,068 MB/s          | ~2,155 MB/s     | 2.0x    |

## What was learned

1. **Zig's std SHA-1 is pure software.** Unlike `std.crypto.hash.sha2` (which has SHA-NI and AArch64 SHA acceleration), `std.crypto.Sha1` has no hardware acceleration at all. Custom implementation was required.

2. **Zig's default build target uses native CPU features.** `builtin.cpu.has(.x86, .sha)` is true even without `-Dcpu=native` when building on a machine with SHA-NI. This means comptime feature detection works out of the box.

3. **SHA-NI byte-swap mask is a full 128-bit reversal.** The `_mm_set_epi64x(0x0001020304050607, 0x08090a0b0c0d0e0f)` mask used by pshufb reverses all 16 bytes, not just per-word byte swap. This is because SHA-NI operates on big-endian 32-bit words in a specific lane order. Getting this wrong produces plausible-looking but incorrect hashes.

4. **Instruction ordering matters for SHA-NI scheduling.** The reference pattern (noloader/SHA-Intrinsics) places `sha1msg2` BEFORE `sha1rnds4` from round 12 onwards. This is not just a latency optimization -- it's required for correct message schedule computation because `sha1msg2` reads from a message register that `sha1rnds4` doesn't touch, while later instructions depend on the msg2 result.

5. **The SHA-256 pattern in Zig's std lib was a good reference** for inline asm syntax (`"=x"`, `"0"` tied operands, `"x"` xmm constraints) but the SHA-1 instruction sequence is fundamentally different (5-word state vs 8-word, different round structure).

## Design decisions

- **Comptime detection, not runtime.** SHA-NI support is known at compile time. No CPUID at runtime, no function pointer dispatch. This is simpler and avoids branch misprediction on every block.
- **Software fallback is a copy of std lib's algorithm.** Same round structure, same correctness. Just embedded in our module so the API is uniform.
- **No separate sha1_ni.zig file.** The SHA-NI code is small enough to live in the same file as the dispatcher and fallback. A separate file would just add import complexity.
