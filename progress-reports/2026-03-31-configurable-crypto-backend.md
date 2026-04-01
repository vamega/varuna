# Configurable Crypto Backend

**Date:** 2026-03-31

## What was done

Added build-time configurable cryptographic algorithm backends via `-Dcrypto=varuna|stdlib|boringssl`.

**New files:**
- `src/crypto/backend.zig` -- unified dispatch module that comptime-selects Sha1, Sha256, and Rc4 implementations based on the build option. Contains 9 tests verifying correct output for all algorithms.
- `src/crypto/boringssl.zig` -- Zig-idiomatic wrappers around BoringSSL's SHA1, SHA256, and RC4 C APIs via `@cImport`. Only compiled when `-Dcrypto=boringssl`.

**Modified files:**
- `build.zig` -- added `CryptoBackend` enum and `-Dcrypto` option, passes `crypto_backend` through `build_options`. Build-time panic if `-Dcrypto=boringssl` is used with `-Dtls=none`.
- `src/crypto/root.zig` -- now exports `Sha1`, `Sha256`, `Rc4` from `backend.zig` instead of directly from `sha1.zig`. Also exports `VarunaSha1` for direct access to hardware-accelerated SHA-1 (used by benchmarks). Exports `crypto_backend` constant.
- `src/crypto/mse.zig` -- imports Sha1 and Rc4 from backend.zig instead of sha1.zig/rc4.zig.
- `src/torrent/create.zig`, `src/torrent/info_hash.zig`, `src/torrent/client.zig`, `src/torrent/merkle.zig`, `src/torrent/merkle_cache.zig` -- import from crypto/root.zig.
- `src/storage/verify.zig`, `src/io/hasher.zig`, `src/io/peer_policy.zig` -- import from crypto/root.zig.
- `src/net/ut_metadata.zig`, `src/net/metadata_fetch.zig` -- import from crypto/root.zig.
- `src/bench/main.zig` -- uses `VarunaSha1` for hardware-specific benchmarks, adds `ActiveSha1` line to compare the configured backend, reports `crypto_backend` in output.

## What was learned

- Zig's `build.addOptions()` generates its own enum types in the options module (e.g., `@"build.CryptoBackend"`). You cannot define a duplicate enum in source code and compare it against the build option value -- Zig treats them as different types. The solution is `@TypeOf(build_options.crypto_backend)` to get the generated type.
- The comptime `switch` on the backend enum cleanly eliminates dead code paths: when `-Dcrypto=varuna`, the BoringSSL `@cImport` is never evaluated, so BoringSSL headers don't need to be present.

## Backends

| Backend | SHA-1 | SHA-256 | RC4 |
|---------|-------|---------|-----|
| `varuna` (default) | Custom with SHA-NI/AArch64 HW detection | `std.crypto.hash.sha2.Sha256` | Custom `src/crypto/rc4.zig` |
| `stdlib` | `std.crypto.hash.Sha1` | `std.crypto.hash.sha2.Sha256` | Custom (no stdlib RC4) |
| `boringssl` | BoringSSL `SHA1_*` | BoringSSL `SHA256_*` | BoringSSL `RC4_*` |

## Testing

- `zig build test -Dtls=none` (default `-Dcrypto=varuna`): all pass
- `zig build test -Dtls=none -Dcrypto=stdlib`: all pass
- `zig build -Dtls=none -Dcrypto=boringssl`: correctly panics at build time
- 9 new backend tests: SHA-1 one-shot + incremental + empty-string, SHA-256 one-shot + incremental + empty-string, RC4 known-vector + roundtrip + BEP6-discard + keystream

## Remaining work

- BoringSSL backend (`-Dcrypto=boringssl`) cannot be tested without `vendor/boringssl` submodule initialized. The wrappers are written but unexercised in CI until BoringSSL is available.
