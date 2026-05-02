# uTP Send Queue Integration Repair

## What Changed

- Fixed the new uTP send-queue regression test so its synthetic ACK uses the same timestamp domain as packets emitted through `utp_handler.utpSendData`.
- Added an explicit assertion that the initial send makes partial progress before the ACK opens the next send window.

## What Was Learned

- The test mixed hard-coded simulation timestamps with `utp_handler.utpNowUs()` timestamps recorded in `UtpSocket.last_send_time_us`.
- That made RTT sampling see a wrapped, huge delta and panic in debug arithmetic inside `UtpSocket.updateRtt`.

## Remaining Issues

- Longer term, uTP handler timestamping should be made easier to drive from deterministic simulation clocks.
- The live uTP-only swarm still needs a separate investigation; this repair only fixes the regression test harness.

## References

- `tests/utp_bytestream_test.zig:337`
- `tests/utp_bytestream_test.zig:343`
