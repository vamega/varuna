# SQLite Amalgamation

Place `sqlite3.c` and `sqlite3.h` here for bundled builds (`-Dsqlite=bundled`).

Download from https://www.sqlite.org/download.html (look for "sqlite-amalgamation-*.zip").

```bash
cd vendor/sqlite
curl -LO https://www.sqlite.org/2025/sqlite-amalgamation-3490200.zip
unzip sqlite-amalgamation-3490200.zip
cp sqlite-amalgamation-3490200/sqlite3.c sqlite-amalgamation-3490200/sqlite3.h .
rm -rf sqlite-amalgamation-3490200 sqlite-amalgamation-3490200.zip
```

The amalgamation is a single C file (~250KB) that contains the entire SQLite library.
