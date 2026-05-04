# Build Dependency Cache Investigation

## What Changed

- Removed the checked-in `lib/libsqlite3.so` symlink to `/usr/lib/x86_64-linux-gnu/libsqlite3.so.0` and stopped adding repository `lib/` to the SQLite search path. The default SQLite mode now relies on the system/dev-shell library or explicit Zig `--search-prefix`.
- Kept `-Dsqlite=bundled` as an explicit local escape hatch, but it now fails early with a clear message when `vendor/sqlite/sqlite3.c` is absent.
- Added `-Dtls=system_boringssl` so environments with a packaged BoringSSL can link `libssl.a`/`libcrypto.a` instead of rebuilding vendored BoringSSL from source.
- Fixed `-Dtls=none`, which previously still forced `src/io/tls.zig` to import `openssl/ssl.h`.
- Fixed `-Ddns=c_ares -Dcares=bundled` build wiring by exposing the generated c-ares headers to `@cImport`, and brought `dns_cares.zig` back into the executor DNS interface shape.
- Updated `flake.nix`, `AGENTS.md`, `README.md`, and `vendor/sqlite/README.md` to prefer system SQLite and document system-link dependency modes.

## What Was Learned

Timing was done with fresh local Zig cache directories under `/tmp` and a shared temporary global cache.

| Build | Wall Time | Notes |
| --- | ---: | --- |
| `-Dtls=none -Ddns=threadpool -Dsqlite=system` | 36.2s cold-ish / 29.6s repeat | Baseline without BoringSSL or c-ares. |
| default vendored BoringSSL | 2:20.9 first / 1:56.7 repeat | BoringSSL rebuilt despite warm global cache; `boringssl-crypto` alone reported 58s. |
| `-Dtls=system_boringssl` | 29.1s | Skips vendored BoringSSL compilation and matches the no-TLS baseline. |
| `-Dtls=none -Ddns=c_ares -Dcares=bundled` | 32.2s | Bundled c-ares itself reported about 3s, so it is not a major clean-build cost. |
| `-Dtls=none -Ddns=c_ares -Dcares=system` | 30.7s | System c-ares avoids the small bundled compile. |
| `-Dsqlite=bundled` | failed | `vendor/sqlite/sqlite3.c` is not present by design in this checkout. |

The major build-time issue is vendored BoringSSL. Zig's local cache removal still forces those C/C++ static libraries to rebuild; the artifacts did not behave like durable global-cache hits in these measurements. System-linking BoringSSL avoids that cost.

## Remaining Issues

- Default `zig build` still uses vendored BoringSSL for portability. Developers who want faster clean rebuilds should use `-Dtls=system_boringssl` in a dev shell or with explicit `--search-prefix` values.
- The c-ares compatibility `resolveAsync` is build-compatible but still completes synchronously through the existing c-ares wait path. The custom DNS backend remains the cleaner long-term async path.
- `-Dsqlite=bundled` still requires a local amalgamation. If we decide bundled SQLite should be a first-class fallback, add a real package/build dependency instead of asking people to drop files manually.
- The build graph still compiles one shared Varuna module for all installed artifacts. A future cleanup could give `varuna-tools`, `varuna-ctl`, and `varuna-perf` narrower modules so they do not inherit daemon-only dependencies.

## Verification

- `nix run nixpkgs#zig_0_15 -- fmt build.zig build/cares.zig src/io/tls.zig src/io/dns_cares.zig src/io/http_executor.zig src/crypto/boringssl.zig`
- `nix run nixpkgs#zig_0_15 -- build --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `nix run nixpkgs#zig_0_15 -- build -Dtls=none -Ddns=threadpool -Dsqlite=system --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `nix run nixpkgs#zig_0_15 -- build -Dtls=system_boringssl -Dsqlite=system --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2 --search-prefix /nix/store/xci3ic096j0fh1mkg5dikijwirpxpmm7-boringssl-0.20260413.0 --search-prefix /nix/store/7891d11df9b43kvypa65vjhfvd9bv6jq-boringssl-0.20260413.0-dev`
- `nix run nixpkgs#zig_0_15 -- build -Dtls=none -Ddns=c_ares -Dcares=bundled -Dsqlite=system --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `nix run nixpkgs#zig_0_15 -- build -Dtls=none -Dsqlite=bundled` failed intentionally with the new clear missing-amalgamation message.
- `nix run nixpkgs#zig_0_15 -- build test --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `git diff --check`

## Key Code References

- `build.zig:10` SQLite mode and missing-amalgamation guard.
- `build.zig:62` `-Dtls=system_boringssl` option and system-link wiring.
- `build.zig:129` c-ares include-path wiring.
- `build.zig:1602` TLS backend enum.
- `build/cares.zig:3` generated c-ares include path export.
- `src/io/tls.zig:13` TLS implementation/stub selection.
- `src/io/dns_cares.zig:236` executor-compatible c-ares `resolveAsync`.
- `src/io/dns_cares.zig:462` c-ares node pointer access fix.
- `src/io/http_executor.zig:897` HTTPS disabled check for `-Dtls=none`.
- `src/crypto/boringssl.zig:15` crypto backend validation message.
- `flake.nix:22` dev-shell dependency packages.
- `AGENTS.md:50` local dependency instructions.
- `README.md:71` build instructions for system SQLite and system BoringSSL.
- `vendor/sqlite/README.md:1` SQLite vendor policy.
