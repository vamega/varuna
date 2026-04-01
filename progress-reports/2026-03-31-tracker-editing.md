# Tracker Editing (Add/Remove/Edit Tracker URLs)

## What was done

Implemented tracker editing -- the ability to add, remove, and edit tracker URLs for torrents after they have been added. This is important for private tracker users who need to update passkeys or announce URLs without re-adding torrents.

### Implementation

1. **SQLite persistence** (`src/storage/resume.zig`):
   - New `tracker_overrides` table: `(info_hash BLOB, url TEXT, tier INT, action TEXT, orig_url TEXT)`.
   - CRUD methods: `saveTrackerOverride`, `removeTrackerOverride`, `removeTrackerOverrideByOrig`, `clearTrackerOverrides`, `loadTrackerOverrides`, `freeTrackerOverrides`.
   - 4 new tests covering add/load, edit with orig_url, remove/clear, per-torrent isolation.

2. **Mutable tracker storage** (`src/daemon/torrent_session.zig`):
   - New `TrackerOverrides` struct with three lists: `added` (user URLs), `removed` (suppressed metainfo URLs), `edits` (URL replacements).
   - `buildTrackerUrls` now applies overrides: removes suppressed URLs, replaces edited URLs, appends user-added URLs.
   - `getStats` tracker count and primary tracker URL now reflect overrides.
   - `addTrackerUrls`, `removeTrackerUrls`, `editTrackerUrl` methods with immediate SQLite persistence.
   - `loadTrackerOverrides` called during session startup alongside rate limits, categories, and tags.

3. **Session manager** (`src/daemon/session_manager.zig`):
   - `addTrackers(hash, urls)`: add URLs + trigger re-announce.
   - `removeTrackers(hash, urls)`: remove URLs.
   - `editTracker(hash, origUrl, newUrl)`: replace URL + trigger re-announce.
   - `getSessionTrackers` updated to apply overrides (removed, edited, added).

4. **API endpoints** (`src/rpc/handlers.zig`):
   - `POST /api/v2/torrents/addTrackers` -- body: `hash=<hash>&urls=<newline-separated>`.
   - `POST /api/v2/torrents/removeTrackers` -- body: `hash=<hash>&urls=<pipe-separated>`.
   - `POST /api/v2/torrents/editTracker` -- body: `hash=<hash>&origUrl=<old>&newUrl=<new>`.
   - All three are qBittorrent WebAPI v2 compatible.

5. **CLI** (`src/ctl/main.zig`):
   - `varuna-ctl add-tracker <hash> <url> [<url2> ...]`
   - `varuna-ctl remove-tracker <hash> <url> [<url2> ...]`
   - `varuna-ctl edit-tracker <hash> <old-url> <new-url>`

6. **Documentation**:
   - `docs/api-compatibility.md`: moved tracker editing from "Unsupported" to "Implemented".
   - `STATUS.md`: added tracker editing to Done section, updated test counts.

## Design decisions

- **Overlay model**: overrides are stored as an overlay on top of the immutable metainfo announce-list, not as a replacement. This preserves the original .torrent data and makes it easy to "undo" overrides by clearing the override table.
- **Three override actions**: `add` (new URL not in metainfo), `remove` (suppress a metainfo URL), `edit` (replace a metainfo URL with a new one). Edits store `orig_url` so the replacement can be applied idempotently on reload.
- **Immediate persistence**: each override operation opens a short-lived SQLite connection (one-shot pattern, same as categories/tags). This is fine because tracker editing is infrequent and user-driven.
- **Re-announce on add/edit**: adding or editing trackers triggers `forceReannounce` to immediately notify the new/updated tracker.

## Key file references

- `src/storage/resume.zig`: tracker_overrides table + CRUD (lines ~801-910)
- `src/daemon/torrent_session.zig`: TrackerOverrides struct (~line 19), buildTrackerUrls overlay (~line 1375), add/remove/edit methods (~line 1402)
- `src/daemon/session_manager.zig`: addTrackers/removeTrackers/editTracker (~line 497), getSessionTrackers with overrides (~line 952)
- `src/rpc/handlers.zig`: handleTorrentsAddTrackers/RemoveTrackers/EditTracker (~line 862)
- `src/ctl/main.zig`: add-tracker/remove-tracker/edit-tracker commands (~line 302)
