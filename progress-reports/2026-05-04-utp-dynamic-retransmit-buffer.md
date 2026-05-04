# uTP Dynamic Retransmit Buffer

## What Changed

- Replaced `UtpSocket`'s fixed `[128]OutPacket` retransmit array with bounded dynamic storage (`max_outbuf = 512`) so active uTP senders can keep a larger in-flight retransmission history without reserving ~177 KiB per idle socket.
- Kept ACK/SACK processing ordered by `out_seq_start`, but added a head index plus occasional compaction instead of shifting large inline datagram buffers on every cumulative ACK.
- Made retransmit-buffer insertion explicitly fallible (`bufferSentPacket` now returns an error), so allocation or cap failures surface to uTP send plumbing instead of silently dropping retransmission history.
- Updated uTP telemetry and tests to use `outBufCount()` and added a regression that buffers 256 outstanding packets, covering the old fixed-cap failure mode.

## What Was Learned

- A 128-entry inline retransmit buffer costs about `128 * 1416 = 181,248` bytes (~177 KiB) per socket once the 1400-byte datagram copy, metadata, and padding are included.
- Simply raising the inline cap would be too expensive: 512 inline packets would reserve roughly 708 KiB per socket even when idle.
- A dynamic buffer still needs a non-shifting head; otherwise ACK processing would copy large `OutPacket` values and create a new hot-path cost while trying to improve throughput.

## Remaining Issues

- This removes one local uTP send-window cap, but it does not tune LEDBAT growth, retransmit batching, UDP receive batching, or uTP upload copy overhead.
- The daemon still needs another real-torrent uTP-only comparison after this lands to see whether the wider retransmit flight improves the Ubuntu/Deepin cases.

## Key References

- `src/net/utp.zig:184` - dynamic retransmit cap.
- `src/net/utp.zig:281` - dynamic `out_buf` and head index.
- `src/net/utp.zig:493` - `outBufCount()` / `outPacketForSeq()` helpers.
- `src/net/utp.zig:697` - ACK head advancement without shifting packet buffers.
- `src/net/utp.zig:854` - occasional retransmit-buffer compaction.
- `src/io/utp_handler.zig:920` - uTP send path now propagates retransmit-buffer insertion errors.
- `src/daemon/session_manager.zig:2102` - peer telemetry reads the new dynamic count.
- `src/net/utp.zig:1775` - regression for more than 128 outstanding packets.
