# IO Contract Bypass Cleanup

## What changed and why

- Removed the public `io_interface.{socket,bind,listen,setsockopt,bindDevice}Blocking` helpers. The IO contract now exposes only the core async operations; startup callers that need to wait own their local "submit + tick until done" loop.
- Routed one-shot listener startup socket creation, bind, listen, setsockopt, and `SO_BINDTODEVICE` through caller-owned wrappers in `EventLoopOf(IO)` and `ApiServerOf(IO)` instead of IO-interface convenience methods.
- Routed remaining generic daemon fd cleanup in HTTP executor pools/slots, RPC client/listener lifecycle, accepted-peer rejection paths, and TCP/uTP listener stop/deinit paths through `io.closeSocket`.
- Added `zig build test-io-contract`, a focused build step for SimIO-backed lifecycle regressions that assert the simulated fd is actually closed.
- Removed the legacy `MoveJob.start()` / `startWithSpawner()` worker-thread entry points and the old whole-root mover tests. Daemon relocation now has one scheduling model: `MoveJob.startOnEventLoop` plus `SessionManager.tickMoveJobs`.
- Switched the MoveJob EXDEV fallback from `copy_file_range` to file -> pipe -> file `splice`. RealIO stays on native `IORING_OP_SPLICE`; `RealIO.copy_file_range` now reports unsupported instead of hiding a threadpool or blocking syscall behind the production backend.

## What was learned

- The daemon MoveJob path is not backend-switched into a worker thread. It uses the same IO contract call shape regardless of backend; non-io_uring backends should hide any required worker-thread file I/O inside the backend adapter.
- Putting blocking wait helpers on `io_interface.zig` makes the wrong thing look endorsed. Keeping those waits at the listener startup call sites preserves the async contract while still making startup sequencing explicit.
- MoveJob already has the right scheduling boundary for relocation: it tries `renameat` first and only enters the copy path after `EXDEV`. Because `copy_file_range(2)` has no io_uring opcode, the production backend should prefer `splice` unless profiling later gives a concrete reason to reintroduce `copy_file_range` on a backend-owned threadpool.
- Eventfd lifecycle in `HttpExecutor` and inbound-peer `getpeername` are still separate boundaries. They need either a new abstraction or a deliberate exception, rather than being disguised as socket close paths.

## Remaining issues or follow-up

- Add an event-loop delete job for `remove_delete_files`.
- Continue the peer socket setup cleanup separately: inbound `getpeername`, `configurePeerSocket`, and outbound `applyBindConfig` still use direct syscalls.
- The default threadpool DNS backend still cannot apply `bind_device` to resolver-owned sockets.

## Key code references

- `src/io/io_interface.zig:629` - regression test asserts no blocking helper declarations remain
- `src/io/http_executor.zig:302` - connection-pool fd drops now use `io.closeSocket`
- `src/rpc/server.zig:108` - API listener startup uses local wrappers over IO contract ops
- `src/io/event_loop.zig:1714` - event-loop listener startup uses local wrappers over IO contract ops
- `src/io/event_loop.zig:1772` - uTP/DHT listener creation now goes through the wrapper-owned IO contract wait
- `src/io/event_loop.zig:1887` - TCP listener creation now goes through the wrapper-owned IO contract wait
- `src/io/peer_handler.zig:144` - accepted-peer rejection close path uses `self.io.closeSocket`
- `src/io/root.zig:85` - `http_executor` inline tests are now reachable through module tests
- `build.zig:689` - focused `test-io-contract` step
- `src/daemon/session_manager.zig:1112` - production MoveJob starts on the shared event loop
- `src/daemon/session_manager.zig:1215` - production MoveJob ticks on the shared event loop
- `src/storage/move_job.zig:280` - sole MoveJob start entry point is `startOnEventLoop`
- `src/storage/move_job.zig:88` - regression test asserts legacy `start` / `startWithSpawner` declarations stay absent
- `src/storage/move_job.zig:640` - EXDEV fallback submits file-to-pipe `splice`
- `src/storage/move_job.zig:670` - EXDEV fallback drains pipe-to-destination `splice`
- `src/io/real_io.zig:553` - `copy_file_range` reports unsupported on RealIO
- `STATUS.md:306` - corrected MoveJob status

## Verification

- `nix run nixpkgs#zig_0_15 -- build test-io-contract --summary failures --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `nix run nixpkgs#zig_0_15 -- build test-io-contract test-move-job test-io-parity --summary failures --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `nix run nixpkgs#zig_0_15 -- build test-io-contract test-move-job test-bind-device test-event-loop test-rpc-server-stress --summary failures --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
- `nix run nixpkgs#zig_0_15 -- build --summary failures --search-prefix /nix/store/2s8x83pfbvx99ixy04l1r03kmxl0xr9q-sqlite-3.51.2`
