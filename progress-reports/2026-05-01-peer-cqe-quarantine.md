# Peer CQE quarantine for slot removal

## What changed and why

- Added explicit peer pending-operation flags for embedded socket/connect, recv, and untracked send completions. `removePeer` now quarantines a slot in `.disconnecting` only when one of those completions is actually still owned by the IO backend.
- Kept tracked sends on the existing ghost `PendingSend` path, so their CQEs can drain without keeping the peer slot unavailable.
- Cleared pending flags when completions fire, so synchronous removals from inside a recv/send callback reset immediately instead of getting stuck in `.disconnecting`.
- Hardened TCP and uTP body receive handlers so a malformed message that removes the peer cannot re-arm the slot as `active_recv_header`.
- Added SimIO coverage where delayed close CQEs hold a removed MSE peer slot in `.disconnecting` until the stale recv completion drains.

## What was learned

- Inferring in-flight CQEs from `PeerState` is too broad: direct unit tests call receive paths after the CQE has already fired, so state alone incorrectly looked like there was still a backend-owned completion.
- The real ownership boundary is the submission/callback pair. Explicit flags model that boundary and preserve the late-CQE protection added for SimIO delayed-close schedules.

## Verification

- `zig build test` passed after the change.

## Remaining issues or follow-up

- The smart-ban BUGGIFY tests still emit very noisy repeated ban diagnostics. The behavior did not fail the suite, but the logging should be tightened separately if it keeps obscuring useful failures.
- Next step: run the same checks under the epoll backend and fix any backend-specific breakage.

## Key code references

- `src/io/types.zig:75`
- `src/io/event_loop.zig:1771`
- `src/io/event_loop.zig:1799`
- `src/io/peer_handler.zig:455`
- `src/io/peer_handler.zig:670`
- `src/io/peer_handler.zig:925`
- `src/io/protocol.zig:468`
- `src/io/utp_handler.zig:445`
- `tests/sim_mse_handshake_test.zig:583`
