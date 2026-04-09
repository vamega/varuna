## What Was Done

- Changed `Layout` so only pure-v2 torrents use file-aligned v2 piece mapping. Hybrid torrents now keep the v1 piece grid for `pieceSize`, `pieceOffset`, `pieceSpanCount`, and `mapPiece`, which matches the flat `pieces` array and peer-wire piece numbering they still expose.
- Made both `Layout.pieceHash()` and `Metainfo.pieceHash()` fail with `error.UnsupportedForV2` on pure-v2 torrents instead of slicing an empty v1 hash buffer.
- Tightened metainfo parsing to reject `piece length = 0`.
- Added regression tests for pure-v2 hash access, hybrid piece mapping semantics, and zero piece-length rejection.

## What Was Learned

- The hybrid inconsistency came from mixing two valid models in one struct: build-time file ranges were v1-derived, but the runtime helpers treated hybrids as if they were file-aligned v2 torrents. That silently changes span counts and offsets for the same piece index.
- Pure-v2 code should not pretend a v1 flat hash table exists. Returning a slice from an empty `pieces` buffer is worse than an explicit error because it hides the version boundary instead of enforcing it.
- `piece length` is one of those fields that looks "positive" in the spec but still needs an explicit zero check in parser code unless the helper enforces strictly greater-than-zero semantics.

## Remaining Issues / Follow-Up

- This pass fixes layout semantics and API boundaries, but it does not yet implement the full pure-v2 download/verification flow for multi-piece files. That still belongs to the later BEP 52 follow-through work.
- Tracker correctness is the next Wave 2 target: first-success behavior in `multi_announce`, allocator/thread safety there, and UDP retry transaction-ID handling.

## Verification

- Ran `zig fmt src/torrent/layout.zig src/torrent/metainfo.zig`
- Ran `zig build test` successfully

## Key References

- `src/torrent/layout.zig:33`
- `src/torrent/layout.zig:87`
- `src/torrent/layout.zig:115`
- `src/torrent/layout.zig:586`
- `src/torrent/layout.zig:611`
- `src/torrent/metainfo.zig:75`
- `src/torrent/metainfo.zig:133`
- `src/torrent/metainfo.zig:489`
- `src/torrent/metainfo.zig:545`
