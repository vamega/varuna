# Persist categories and tags across daemon restarts

## What was done

Categories and tags were previously in-memory only (CategoryStore/TagStore HashMaps)
and lost on every daemon restart. This change persists them to the existing SQLite
resume DB using a write-through strategy.

### Schema additions (4 new tables in resume DB)

- `categories` -- global category definitions (name + save_path)
- `torrent_categories` -- per-torrent category assignment (info_hash -> category)
- `torrent_tags` -- per-torrent tag assignments (info_hash, tag)
- `global_tags` -- all known tag names (independent of torrent assignments)

### Implementation approach

- **Write-through**: every create/edit/delete of categories, tags, or torrent
  assignments immediately persists to SQLite. These operations are infrequent
  (user-driven CRUD), so the overhead is negligible.
- **Load once at startup**: `SessionManager.loadCategoriesAndTags()` opens the
  resume DB and populates the in-memory CategoryStore and TagStore before
  accepting API requests.
- **Per-torrent loading**: when a torrent's `startWorker` opens its ResumeWriter,
  it also loads that torrent's persisted category and tags from the DB.
- **One-shot statements**: category/tag SQL uses prepare-execute-finalize per call
  rather than cached prepared statements, since these operations are rare. The
  hot-path piece/stats statements remain pre-prepared as before.

### SQLite bindings

Added `sqlite3_bind_text` and `sqlite3_column_text` to `src/storage/sqlite3.zig`
since category/tag data is text rather than blobs or integers.

## Key file changes

- `src/storage/sqlite3.zig:46-52` -- new text binding/column functions
- `src/storage/resume.zig:302-472` -- all new category/tag ResumeDb methods
- `src/daemon/session_manager.zig:31-67` -- resume_db field, loadCategoriesAndTags()
- `src/daemon/session_manager.zig:237,275,302` -- write-through in setTorrentCategory, addTorrentTags, removeTorrentTags
- `src/rpc/handlers.zig:732,761,780,820,838` -- write-through in handler CRUD methods
- `src/daemon/torrent_session.zig:503-515` -- per-torrent load on startup
- `src/main.zig:90` -- call loadCategoriesAndTags() at daemon startup

## Tests added

8 new tests in `src/storage/resume.zig`:
- save and load categories (with upsert)
- remove category
- torrent category persistence (set, load, clear)
- torrent tags persistence (add, load, remove, dedup)
- global tags persistence
- clear category from all torrents
- remove tag from all torrents

## Design notes

- The SessionManager holds a shared `ResumeDb` for category/tag operations,
  separate from the per-torrent `ResumeWriter` instances. This avoids needing
  a torrent session to exist before persisting global categories/tags.
- All DB operations are on the API request thread (behind the SessionManager
  mutex), not the io_uring event loop thread, consistent with the project's
  SQLite policy.
