# SQLite Transient Binding Fix

## What changed and why

`src/storage/sqlite3.zig` now models SQLite bind destructors with an
`align(1)` function-pointer type. That lets Zig represent SQLite's
`SQLITE_TRANSIENT` sentinel value, which the C API defines as a destructor
function pointer with integer value `-1`.

The previous binding used a normally aligned function pointer. Zig 0.15.2
rejected `@ptrFromInt(maxInt(usize))` for that type because the sentinel is not
a valid aligned function address.

## What was learned

This is an FFI binding-shape issue, not a runtime SQLite problem and not caused
by ARM. The failure happened at Zig semantic analysis before any SQLite code
ran. ARM is still relevant to the remaining build failures, but those come from
BoringSSL inline assembly, not SQLite.

## Remaining issues or follow-up

`zig build test` still fails in this environment with 29 compile failures from
BoringSSL's ARM inline assembly (`fmov s4, %w[val]`). A TLS-free verification
path using `-Dtls=none -Dcrypto=stdlib` is also blocked because
`src/io/tls.zig` still imports OpenSSL headers during semantic analysis.

## Key code references

- `src/storage/sqlite3.zig:15` - adds the `Destructor` type with `align(1)`.
- `src/storage/sqlite3.zig:51` - applies the destructor type to
  `sqlite3_bind_blob`.
- `src/storage/sqlite3.zig:67` - applies the destructor type to
  `sqlite3_bind_text`.
- `src/storage/sqlite3.zig:79` - defines `SQLITE_TRANSIENT` with the SQLite C
  sentinel value.
