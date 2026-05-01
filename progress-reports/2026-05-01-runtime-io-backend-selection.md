# Runtime IO Backend Selection

## What Changed

- Added `[daemon] io_backend` with `auto`, `io_uring`, `epoll_posix`, `epoll_mmap`, `kqueue_posix`, and `kqueue_mmap` parsing. The Linux default `auto` prefers `io_uring` when the runtime probe succeeds and falls back to `epoll_posix` when it does not.
- Moved daemon startup to a runtime dispatch that instantiates the selected concrete `EventLoopOf(IO)`, `SessionManagerOf(IO)`, `TorrentSessionOf(IO)`, `ApiHandlerOf(IO)`, `ApiServerOf(IO)`, and tracker executor stack.
- Kept the old build-selected aliases (`EventLoop`, `SessionManager`, `TorrentSession`, etc.) for tests and existing callers, while allowing the daemon binary to compile the Linux backend branches into one executable.
- Changed startup gating so only the effective `io_uring` backend requires the kernel floor and a successful `io_uring` probe. Explicit `epoll_posix` / `epoll_mmap` no longer fail just because `io_uring` is unavailable.

## What Was Learned

- The event loop itself was already generic, but the daemon ownership graph still leaked concrete `RealIO` through RPC server, tracker executor, session manager, torrent session, queue manager, sync state, and web-seed callbacks.
- Zig still needs a concrete type per branch. The practical runtime-selection shape is a top-level switch that calls a generic daemon body, not a fully type-erased IO object.
- The kqueue branches can be represented in the config/probe model, but real macOS runtime validation remains separate from Linux CI/build verification.

## Verification

- `nix shell nixpkgs#zig_0_15 --command zig build --summary failures --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `nix shell nixpkgs#zig_0_15 --command zig build test --summary failures --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `nix shell nixpkgs#zig_0_15 --command zig build -Dio=epoll_posix test --summary failures --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `nix shell nixpkgs#zig_0_15 --command zig build -Dio=epoll_mmap test --summary failures --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `nix shell nixpkgs#zig_0_15 --command zig build -Dio=kqueue_posix --summary failures --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `nix shell nixpkgs#zig_0_15 --command zig build -Dio=kqueue_mmap --summary failures --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`

All six commands exited 0.

## Remaining Issues

- kqueue runtime backend selection needs validation on a real macOS host.
- Cross-backend performance comparison is still unmeasured; this only proves compile/test behavior and runtime selection plumbing.

## Key References

- `src/config.zig:5` - runtime backend config enum and parser.
- `src/runtime/probe.zig:32` - runtime backend selection and per-backend support checks.
- `src/main.zig:86` - top-level backend dispatch into the generic daemon body.
- `src/io/backend.zig:141` - backend-specific init helpers for arbitrary concrete IO types.
- `src/daemon/session_manager.zig:28` - generic session manager.
- `src/daemon/torrent_session.zig:177` - generic torrent session.
- `src/rpc/server.zig:54` - generic API server.
- `src/tracker/executor.zig:14` - generic HTTP tracker executor.
- `src/io/web_seed_handler.zig:209` - generic web-seed callback context.
- `STATUS.md:32` - status update for runtime-selectable daemon IO.
