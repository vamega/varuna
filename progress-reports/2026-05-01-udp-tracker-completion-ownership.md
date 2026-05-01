# UDP tracker completion ownership

## What changed and why

- `UdpTrackerExecutor` now uses separate socket, connect, send, and recv completions instead of reusing one completion for overlapping sendmsg/recvmsg phases (`src/tracker/udp_executor.zig:145`, `src/tracker/udp_executor.zig:564`, `src/tracker/udp_executor.zig:593`).
- UDP socket connect is routed through the IO contract instead of direct `posix.connect`, preserving backend parity for SimIO and epoll backends (`src/tracker/udp_executor.zig:469`, `src/tracker/udp_executor.zig:491`).
- Completed slots are marked closing and are not returned to the free pool until all late socket/connect/send/recv callbacks have drained, avoiding slot reuse while a CQE still references slot-owned buffers and message structs (`src/tracker/udp_executor.zig:789`, `src/tracker/udp_executor.zig:813`).
- Added a source-side SimIO regression proving connect-state send and recv submissions can be in flight at the same time without completing the request as `SubmitFailed` (`src/tracker/udp_executor.zig:833`).
- Wired `udp_executor.zig` into tracker source-side tests so the IO-contract regression runs under `zig build test` (`src/tracker/root.zig:18`).

## What was learned

- The old single-completion shape was incompatible with backends that enforce one in-flight operation per completion. `startConnect`, `startAnnounce`, and `startScrape` all submitted sendmsg and recvmsg back-to-back.
- Serializing recv after send would avoid `AlreadyInFlight`, but separate completions better match UDP retransmission behavior because a later retransmit can send while the receive remains armed.

## Remaining issues or follow-up

- Executor `destroy` still assumes the event loop has drained outstanding callbacks before freeing the executor itself. The slot-level reuse bug is fixed, but a larger executor-lifetime drain would be a separate shutdown hardening pass.
- Final verification should include default and epoll backend full suites.

## Verification

- `zig build test --summary failures` passed.
- `git diff --check` passed.
