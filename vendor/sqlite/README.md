# SQLite

Varuna defaults to `-Dsqlite=system`. Use the SQLite package from your distro,
Nix dev shell, or an explicit Zig `--search-prefix`; do not check in a
machine-specific `libsqlite3.so` symlink.

The repository does not vendor SQLite by default. If a system SQLite is not
available and you intentionally want a bundled build, place `sqlite3.c` and
`sqlite3.h` here locally and build with `-Dsqlite=bundled`.

Download from https://www.sqlite.org/download.html (look for "sqlite-amalgamation-*.zip").

```bash
cd vendor/sqlite
curl -LO https://www.sqlite.org/2025/sqlite-amalgamation-3490200.zip
unzip sqlite-amalgamation-3490200.zip
cp sqlite-amalgamation-3490200/sqlite3.c sqlite-amalgamation-3490200/sqlite3.h .
rm -rf sqlite-amalgamation-3490200 sqlite-amalgamation-3490200.zip
```

The amalgamation is a single C file (~250KB) that contains the entire SQLite library.
