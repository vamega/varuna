# SimIO Durable File Length

## What changed

- Extended the SimIO durability model from byte overlays to file-length metadata.
- `write`, `truncate`, and mode-0 `fallocate` now update a pending visible length that is promoted by `fsync` and dropped by `crash`.
- Added focused durability tests for pending vs. fsynced `truncate` and `fallocate` length changes.

## What was learned

The existing crash model could prove write/fsync ordering, but it could not model sparse length changes. That meant tests could not distinguish "the file appears extended/truncated in pagecache" from "the file length is durable after the barrier." Modeling pending length closes that gap without changing the public IO contract.

## Remaining issues

- SimIO still treats nonzero `fallocate` modes as metadata no-ops. That is acceptable for current PieceStore paths, but punch-hole/keep-size tests would need explicit semantics.
- `copy_file_range` still models only byte counts, not byte content movement. MoveJob cross-filesystem simulation would need content-aware copy behavior if we want crash tests for relocation copy fallback.

## Key references

- `src/io/sim_io.zig:302` - `pending_len` describes unfsynced file-length metadata.
- `src/io/sim_io.zig:337` - visible reads use pending length before durable length.
- `src/io/sim_io.zig:394` - fsync promotes pending length and dirty bytes together.
- `src/io/sim_io.zig:1392` - mode-0 `fallocate` extends pending length.
- `src/io/sim_io.zig:1403` - `truncate` records pending length until fsync.
- `tests/sim_io_durability_test.zig:378` - regression tests for crash behavior around pending and fsynced length changes.
