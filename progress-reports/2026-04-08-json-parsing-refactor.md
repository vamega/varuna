# JSON Parsing Refactor in RPC Handlers

## What was done

Replaced three hand-rolled JSON extraction functions (`extractJsonInt`, `extractJsonBool`,
`extractJsonFloat`) in `src/rpc/handlers.zig` with `std.json.parseFromSlice` and a typed
`PreferencesUpdate` struct. Also introduced two helper functions to reduce code duplication
throughout the handler file.

### Changes

1. **`PreferencesUpdate` struct** (line ~1766): All fields `handleSetPreferences` reads are
   declared as optional with `null` defaults. Parsed via
   `std.json.parseFromSlice(PreferencesUpdate, allocator, body, .{ .ignore_unknown_fields = true })`.

2. **`handleSetPreferences` rewritten** (line ~576): JSON bodies are now parsed into the
   typed struct. If JSON parsing fails (e.g. the body is form-encoded), the handler falls
   back to `extractParam`-based form decoding. This preserves backward compatibility with
   both `json={"dl_limit":1024}` form-encoded payloads and raw JSON bodies.

3. **`errorResponse` helper** (line ~1723): Replaces 23 copies of the three-line
   `allocPrint + catch + return` error pattern with a single function call.

4. **`requireHashes` helper** (line ~1732): Replaces 16 sites that extracted torrent
   hashes. Tries `hashes` first, then falls back to `hash`, giving all endpoints consistent
   handling of both parameter names.

5. **Removed `extractJsonInt`, `extractJsonBool`, `extractJsonFloat`**: These had no
   remaining callers after the `handleSetPreferences` rewrite. Their tests were also removed.

### Tests added

- `parsePreferencesJson parses integer fields`
- `parsePreferencesJson parses boolean fields`
- `parsePreferencesJson parses float fields`
- `parsePreferencesJson parses queue config fields`
- `parsePreferencesJson parses seeding time as signed int`
- `parsePreferencesJson parses multiple fields in one request`
- `parsePreferencesJson missing fields are null`
- `parsePreferencesJson ignores unknown fields`
- `parsePreferencesJson handles empty object`
- `parsePreferencesJson parses dht and pex toggles`
- `parsePreferencesJson parses max_ratio_act`
- `parsePreferencesJson handles whitespace`
- `requireHashes returns hashes param`
- `requireHashes falls back to hash param`
- `requireHashes prefers hashes over hash`
- `requireHashes returns null when neither present`
- `requireHashes returns null for empty body`
- `errorResponse formats error message`
- `errorResponse uses correct status code`

## What was learned

- `std.json.parseFromSlice` with `.ignore_unknown_fields = true` handles the partial-update
  pattern well: unknown fields are silently skipped, and missing known fields stay `null`
  thanks to Zig's optional struct defaults.
- The `Parsed(T)` wrapper returned by `parseFromSlice` manages scanner memory, so `.deinit()`
  must be called after the parsed values are consumed. For `PreferencesUpdate` (all scalar
  fields, no allocated strings in the struct), this is straightforward.

## Code references

- `src/rpc/handlers.zig:~1766` -- `PreferencesUpdate` struct definition
- `src/rpc/handlers.zig:~576` -- rewritten `handleSetPreferences`
- `src/rpc/handlers.zig:~1723` -- `errorResponse` helper
- `src/rpc/handlers.zig:~1732` -- `requireHashes` helper
