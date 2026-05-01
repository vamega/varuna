# Protocol Peer-State Test Bodies

## What changed and why

Fixed protocol peer-state regressions by making direct `processMessage` tests pass exact peer-wire message body slices instead of the full `small_body_buf`. The protocol handler now validates exact payload lengths before dispatch, so oversized scratch-buffer bodies were correctly rejected as malformed and never reached the CHOKE/UNCHOKE/INTERESTED/HAVE/CANCEL handlers.

## What was learned

The production peer-state logic was already role-neutral for outbound-mode serving peers. The failing tests were constructing invalid bodies: control messages need a 1-byte body, HAVE needs 5 bytes, and CANCEL needs 13 bytes. In the HAVE test, the invalid body caused `removePeer` cleanup to deinit `peer.availability`, which made the later nullable unwrap panic.

## Remaining issues or follow-up

`zig build test` still has unrelated existing failures in `tests/sim_multi_source_eventloop_test.zig`. No protocol inline or peer-mode regression failures remained in the post-fix full test summary.

## Key code references

- `src/io/protocol.zig:1105` - test helper for exact small-buffer message bodies
- `src/io/protocol.zig:1238` - UNCHOKE direct-message test now passes a 1-byte body
- `src/io/protocol.zig:1257` - INTERESTED direct-message test now passes a 1-byte body
- `src/io/protocol.zig:1302` - HAVE direct-message test now passes a 5-byte body
- `tests/peer_mode_regression_test.zig:56` - outbound-mode INTERESTED regression uses the exact 1-byte body
