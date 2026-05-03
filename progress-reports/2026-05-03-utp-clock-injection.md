# uTP Clock Injection

## What changed and why

- Added `Clock.nowUs32()` for wrapping 32-bit microsecond protocol timestamps.
- Routed uTP event-loop integration through `self.clock.nowUs32()` instead of direct wall-clock reads, so simulated event loops drive uTP send, receive, reset, and timeout timestamps.
- Added regression coverage that sends uTP data under a simulated event-loop clock and verifies the socket send timestamp comes from that clock.

## What was learned

- The lower-level uTP socket/manager already accepted explicit `now_us`; the nondeterminism was isolated to the event-loop/uTP handler adapter.
- The uTP ACK regression test no longer needs to compensate for a wall-clock sender timestamp.

## Remaining issues or follow-up

- Soak-test timing still uses `std.time.microTimestamp()` for measurement, which is separate from protocol behavior.

## Key references

- `src/runtime/clock.zig:111`
- `src/io/utp_handler.zig:197`
- `src/io/utp_handler.zig:597`
- `src/io/utp_handler.zig:757`
- `src/io/event_loop.zig:646`
- `tests/utp_bytestream_test.zig:298`
