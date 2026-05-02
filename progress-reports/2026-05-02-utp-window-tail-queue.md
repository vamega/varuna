# uTP window-limited send queue

## What changed and why

- Fixed `utpSendData` so application byte-stream bytes that do not fit the current uTP congestion/receive window are queued on the `UtpSocket` instead of being dropped after a partial DATA burst.
- Added ACK-driven draining of the queued byte stream, preserving peer-wire message order across multiple DATA packets and multiple caller writes.
- Added deterministic coverage that reproduces a large uTP byte-stream write limited by the initial congestion window, ACKs the first burst, and verifies the sender resumes packetizing the remaining bytes.

## What was learned

- The focused regression failed before the fix: after ACKing the first window-limited burst, `sock.seq_nr` did not advance on a follow-up drain attempt. That proved the unsent tail had been lost at the uTP sender boundary.
- `scripts/demo_swarm.sh` with default config completed 256 MiB in `34.828s`, essentially unchanged from the prior `34.832s` baseline. The logs showed MSE/TCP handshakes, so that timing is not a uTP data-path measurement.
- A one-off uTP-only variant of the demo configs (`transport = "utp_only"`) timed out after 180s at `progress=0.0000`. The temp configs contained the override, but the daemon logs showed no outbound uTP connection attempt, so the uTP-only live harness remains blocked before throughput can be measured.

## Remaining issues or follow-up

- The correctness fix is in place, but it did not improve the default live swarm timing because the default two-daemon harness used TCP.
- Root-cause the uTP-only peer discovery/connection path in the live harness: tracker peers were present in the setup, but no uTP initiation reached the logs.
- After uTP-only live connectivity works, rerun the 256 MiB swarm with a real uTP data path and compare against the default TCP-backed 34.8s result.

## Key code references

- `src/net/utp.zig:282` - per-socket ordered pending send buffer.
- `src/net/utp.zig:506` - queue/consume helpers for pending application bytes.
- `src/io/utp_handler.zig:218` - ACK path drains pending uTP data.
- `src/io/utp_handler.zig:578` - `utpSendData` now queues first, then packetizes as the window allows.
- `tests/utp_bytestream_test.zig:291` - deterministic regression for window-limited send resumption.
