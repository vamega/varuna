# Directory Metadata Parity Tightening

## What changed and why

- Tightened the IO backend parity compile check so it now covers the full documented submission surface, including `closeSocket`, bind/listen/setsockopt, fallocate/truncate, splice/copy_file_range, and the directory metadata ops.
- Extended that compile check beyond RealIO and SimIO to include the Linux epoll backends and macOS kqueue backends. This makes the focused IO parity target fail if an alternate backend loses `statx`/`getdents` contract support.
- Strengthened the directory enumeration test to issue a second `getdents` call and require EOF (`0` bytes), proving the RealIO/SimIO contract preserves directory fd offset semantics instead of only returning one matching entry.

## What was learned

- The 2026-05-02 metadata slice already implemented `statx` and `getdents` across RealIO, SimIO, epoll, and kqueue; no backend implementation changes were needed after the stricter focused tests were added.
- The remaining integration gap is still MoveJob v2, not the IO contract surface. The thread-based move job still owns raw directory walking and copy/unlink loops.

## Remaining issues or follow-up

- Rewrite MoveJob as an event-loop-owned state machine using `openat` / `mkdirat` / `renameat` / `unlinkat` / `statx` / `getdents` plus existing copy primitives.
- Decide MoveJob scheduling policy first: global cap, per-device partitioning, FIFO, or size-aware scheduling.

## Key code references

- `tests/io_backend_parity_test.zig:33` - full documented backend method set checked at comptime.
- `tests/io_backend_parity_test.zig:60` - RealIO, SimIO, EpollPosixIO, EpollMmapIO, KqueuePosixIO, and KqueueMmapIO all checked.
- `tests/io_backend_parity_test.zig:263` - directory enumeration via the IO contract.
- `tests/io_backend_parity_test.zig:287` - repeated `getdents` EOF assertion.
- `src/io/io_interface.zig:215` - `StatxOp` contract.
- `src/io/io_interface.zig:229` - `GetdentsOp` contract.
- `STATUS.md:306` - remaining MoveJob v2 integration blocker.
