# RPC qBittorrent Hash Selection And Info Filters

## What changed and why

Added a shared RPC hash-selection helper for qBittorrent-style `hashes` values. It expands `hashes=all` from a stats snapshot and parses pipe-delimited 40-byte hashes into owned fixed-size keys before mutating torrents.

Wired that helper through high-value plural torrent endpoints: delete, pause, resume, per-torrent rate-limit setters, sequential download, super seeding, force reannounce, recheck, share limits, category/tag assignment, queue priority actions, force start, and addPeers.

`/api/v2/torrents/info` now honors `hashes`, `hash`, `filter`, `category`, `tag`, `sort`, `reverse`, `limit`, and `offset` against the existing `TorrentSession.Stats` surface.

## What was learned

The current API test target is blocked on this aarch64 host before tests execute by an existing `src/storage/sqlite3.zig` pointer-alignment compile error for `SQLITE_TRANSIENT`. The worktree's tracked `lib/libsqlite3.so` symlink also points to an x86_64 system path, so `zig build test-api` needs either a suitable search prefix or a repo-level SQLite setup fix on this machine.

## Remaining issues or follow-up

The form/query parser still decodes values in place. This change uses the existing parser to stay scoped, but tracker-url parameters with encoded `&` or `=` still need the tokenise-first parser follow-up from the codebase review.

`/torrents/add` multi-file and newline URL handling remains untouched.

## Key code references

- `src/rpc/handlers.zig:413` - `/torrents/info` query filtering, sorting, and paging.
- `src/rpc/handlers.zig:2308` - `resolveHashesOrAll` central hash-selection helper.
- `tests/api_categories_test.zig:247` - `hashes=all` category regression.
- `tests/api_categories_test.zig:346` - pipe-delimited tags regression.
- `tests/api_categories_test.zig:374` - `/torrents/info` hash/category/tag/filter regression.
- `tests/api_categories_test.zig:422` - `/torrents/info` sort/offset/limit regression.
