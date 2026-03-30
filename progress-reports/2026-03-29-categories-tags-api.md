# Categories and Tags API

## What was done

Added qBittorrent-compatible categories and tags endpoints to the varuna daemon RPC API. This enables torrent organization via categories (with optional save paths) and freeform tags, matching the qBittorrent v2 API contract.

### New file
- `src/daemon/categories.zig`: `CategoryStore` (HashMap-backed) and `TagStore` (HashSet-backed) with CRUD operations and JSON serialization.

### Modified files
- `src/daemon/torrent_session.zig`: Added `category`, `tags` (ArrayList), and `tags_string` (cached comma-joined) fields to `TorrentSession`. Added `category` and `tags` fields to `Stats` struct. Added `rebuildTagsString()` helper.
- `src/daemon/session_manager.zig`: Holds `CategoryStore` and `TagStore` instances. Added `setTorrentCategory()`, `addTorrentTags()`, `removeTorrentTags()` methods.
- `src/rpc/handlers.zig`: 10 new endpoints: `categories`, `createCategory`, `removeCategories`, `editCategory`, `setCategory`, `tags`, `createTags`, `deleteTags`, `addTags`, `removeTags`. Updated `torrents/info` serialization to include `category` and `tags`. Updated `torrents/add` to accept `category` parameter from query, form-encoded body, or multipart.
- `src/rpc/sync.zig`: Added `categories` and `tags` sections to sync/maindata response. Included category/tags in Wyhash change detection.
- `src/daemon/root.zig`: Exported `categories` module.
- `STATUS.md`: Updated API section.

## Design decisions
- In-memory only (no persistence) as specified. Categories/tags are lost on daemon restart.
- Tags are stored as an ArrayList on TorrentSession with a pre-computed comma-separated string cache (`tags_string`) to avoid allocation in the Stats path.
- Deleting a global tag also removes it from all torrents. Removing a category clears it from all assigned torrents.
- Category assignment via `setCategory` validates the category exists in the store; `torrents/add` category assignment is best-effort (won't fail the add if category doesn't exist).
- Thread safety: category/tag handlers acquire the SessionManager mutex directly (same pattern as existing endpoints).

## Tests
- 5 unit tests in `categories.zig`: create/list, edit/remove, tag CRUD, empty serialization for both stores.
- All existing tests continue to pass.

## Code references
- `src/daemon/categories.zig` (entire file): CategoryStore and TagStore
- `src/rpc/handlers.zig:197-246`: category/tag endpoint dispatch in handleTorrents
- `src/rpc/handlers.zig:693-863`: handler implementations
- `src/daemon/session_manager.zig:202-265`: setTorrentCategory, addTorrentTags, removeTorrentTags
