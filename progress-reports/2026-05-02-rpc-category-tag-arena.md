# RPC Category And Tag Arena Coverage

## What changed and why

- Changed `CategoryStore.serializeJson` and `TagStore.serializeJson` to build directly into the caller allocator instead of duplicating a parent-owned cached JSON string.
- Kept `cachedJson()` for `/sync/maindata`, where category/tag JSON is persistent sync state and can still be cached by the store.
- Added an RPC arena regression that dirties category and tag caches, calls the real `ApiHandler` with a `TieredArena` request allocator, and asserts the SessionManager parent allocator's live allocation count is unchanged after each list response.

## What was learned

- The server-level per-slot arena already covers handler allocations, but dirty category/tag list endpoints had an extra store-cache allocation before duplicating into the request allocator.
- Separating "serialize for this response" from "materialize persistent cached JSON" preserves the sync cache while keeping direct category/tag list responses request-scoped.

## Remaining issues or follow-up

- `SyncState` snapshot hash maps still allocate persistent delta state from their own allocator. That is not per-request transient response work, but it remains the dominant allocation source in large `/sync/maindata` workloads.

## Key code references

- `src/daemon/categories.zig:73`: cached category JSON remains store-owned.
- `src/daemon/categories.zig:85`: category response serialization now uses the caller allocator directly.
- `src/daemon/categories.zig:161`: cached tag JSON remains store-owned.
- `src/daemon/categories.zig:173`: tag response serialization now uses the caller allocator directly.
- `tests/rpc_arena_test.zig:357`: dirty-cache request-arena regression.
