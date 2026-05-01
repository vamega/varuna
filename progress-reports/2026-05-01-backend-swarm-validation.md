# Backend Swarm Validation

## What changed

- Added `zig build test-swarm-backends`, which runs the existing live swarm demo across `io_uring`, `epoll_posix`, and `epoll_mmap`.
- Extended `scripts/demo_swarm.sh` so backend validation pins `[daemon] io_backend` in generated configs, supports larger payloads, reports transfer timing, and uses bounded process cleanup.
- Fixed runtime-backend callback typing in uTP recv/send and seed-mode disk-read completions. These callbacks now cast completion userdata back to the actual `EventLoopOf(IO)` instantiation instead of the default `EventLoop` alias.

## What was learned

The first full matrix exposed an `epoll_mmap` cleanup hang after a successful transfer. The seeder log showed repeated crashes in `std.os.linux.IoUring.recvmsg`, which meant an epoll-selected daemon was re-entering the build-default io_uring callback path. The root cause was concrete `*EventLoop` callback casts in the uTP handler. The seed read callback had the same shape and was fixed at the same boundary.

## Verification

- `zig build --summary failures`
- `zig build test --summary failures`
- `BACKENDS=epoll_mmap PAYLOAD_BYTES=4096 TIMEOUT=60 zig build test-swarm-backends --summary failures`
- `TIMEOUT=90 zig build test-swarm-backends --summary failures`

Final backend matrix:

| Backend | Status | Payload |
| --- | --- | --- |
| `io_uring` | pass | 1048576 bytes |
| `epoll_posix` | pass | 1048576 bytes |
| `epoll_mmap` | pass | 1048576 bytes |

## Remaining follow-up

- Run the same end-to-end matrix on macOS for `kqueue_posix` and `kqueue_mmap`; Linux CI cannot validate those branches.
- Consider adding the backend matrix to a slower CI lane because it depends on `opentracker` and starts multiple live daemon instances.

## Code references

- `build.zig:1325`
- `scripts/backend_swarm_matrix.sh:5`
- `scripts/demo_swarm.sh:30`
- `src/io/utp_handler.zig:48`
- `src/io/utp_handler.zig:108`
- `src/io/seed_handler.zig:34`
- `src/io/seed_handler.zig:339`
