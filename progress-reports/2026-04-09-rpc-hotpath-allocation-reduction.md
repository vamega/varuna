# 2026-04-09: RPC Hot-Path Allocation Reduction

## What was done and why

Removed the extra body duplication from `/api/v2/sync/maindata`.

- `src/rpc/handlers.zig:1347` now calls `sync_state.computeDelta()` with the request allocator directly and returns the owned JSON buffer as the response body.
- This removes the previous pattern of building the response in an arena, copying it into a second owned buffer, and immediately destroying the arena.

## What was learned

- `SyncState.computeDelta()` already owns the long-lived snapshot state internally and returns a fully owned JSON slice. The extra arena only made sense when the function returned borrowed memory, which it no longer does.
- The simplest allocation reduction in a hot polling path is often just removing an old ownership workaround that is no longer necessary.

## Remaining issues / follow-up

- `/sync/torrentPeers` now has its own snapshot state, but the rest of the large RPC list endpoints still build temporary object graphs and strings on the request allocator.
- The HTTP client module was not changed in this pass; its daemon/tooling boundary remained as-is.

## Code references

- `src/rpc/handlers.zig:1347`
