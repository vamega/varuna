# Pure Zig build for vendored c-ares

**Date:** 2026-04-05

## What was done

Added a pure Zig build for the c-ares async DNS library, eliminating the need
for CMake/Ninja/Make when building with `-Ddns=c_ares`. The build follows the
same pattern as the existing BoringSSL vendored build.

### New files
- `build/cares.zig` — Zig build script that compiles all c-ares library sources
  into a static library, matching the CMake `CSOURCES` list minus
  platform-specific files (Android, macOS, Windows).
- `build/cares-generated/ares_config.h` — Pre-built config header for Linux,
  replacing the CMake-generated `ares_config.h`. Hardcoded for glibc >= 2.36.
- `build/cares-generated/ares_build.h` — Pre-built build header for Linux,
  replacing the CMake-generated `ares_build.h`.
- `vendor/c-ares` — git submodule pointing to https://github.com/c-ares/c-ares.git

### Modified files
- `build.zig` — Added `-Dcares=system|bundled` option (default: `bundled`).
  When `-Ddns=c_ares -Dcares=bundled`, compiles from `vendor/c-ares/`.
  When `-Ddns=c_ares -Dcares=system`, links system `libcares` as before.
- `src/io/dns_cares.zig` — Fixed Zig 0.15 API compatibility issues exposed
  by compiling against bundled headers.

## What was learned

### c-ares build structure
- c-ares uses `HAVE_CONFIG_H` to gate inclusion of `ares_config.h` from
  `ares_setup.h`. Without it, only Windows config is loaded.
- The source tree has a nested `src/lib/include/` directory with internal
  headers (`ares_mem.h`, `ares_buf.h`, etc.) that must be on the include path.
- CMake's `#cmakedefine FOO` produces `#define FOO` (no value), while our
  headers use `#define FOO 1`. Both are equivalent for `#ifdef` checks.

### C compilation flags
- `-std=c99` or `-std=gnu99` is insufficient — `pipe2()` requires
  `_GNU_SOURCE` to be visible even under `-std=gnu11`. We pass both
  `-std=gnu11` and `-D_GNU_SOURCE=1`.
- c-ares forward-declares `struct hostent` in `ares.h` (line 399). Without
  `<netdb.h>` included first, Zig's `@cImport` sees it as opaque and blocks
  field access. Fix: `@cInclude("netdb.h")` before `@cInclude("ares.h")`.

### Zig 0.15 API changes in dns_cares.zig
- `posix.epoll_create1` now takes `u32` instead of a struct initializer.
  Use `linux.EPOLL.CLOEXEC` instead of `.{ .CLOEXEC = true }`.
- `posix.epoll_ctl` operation parameter changed from enum to `u32`.
  Use `linux.EPOLL.CTL_ADD` / `CTL_MOD` / `CTL_DEL`.
- c-ares callback signature changed `struct hostent *` to
  `const struct hostent *` in newer versions; Zig callback needs
  `?*const c.struct_hostent` and `callconv(.c)`.
- `ares_getsock()` returns `c_int` but bitmask operations need `c_uint`;
  use `@bitCast` to convert.

### Config header validation
- Validated our hardcoded headers against CMake output on Ubuntu with
  `build-essential`. Found and fixed:
  - Missing `HAVE_ARC4RANDOM_BUF` (glibc 2.36+)
  - Incorrect `HAVE_INET_NET_PTON` (BSD extension, not in glibc)
  - Missing `CARES_HAVE_ARPA_NAMESER_COMPAT_H` in `ares_build.h`

## Key code references
- `build/cares.zig:118` — `create()` function, entry point for the build
- `build/cares-generated/ares_config.h:1-21` — documents glibc >= 2.36
  assumption and CMake validation recipe
- `build.zig:18-23` — `-Dcares=system|bundled` option
- `build.zig:88-99` — system vs bundled switching logic
- `src/io/dns_cares.zig:5` — `netdb.h` include for `struct hostent`

## Build flags
```
zig build -Ddns=c_ares                    # bundled (default)
zig build -Ddns=c_ares -Dcares=system     # system libcares
zig build -Ddns=c_ares -Dcares=bundled    # explicit bundled
```
