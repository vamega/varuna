# uTP seq_nr Off-by-One Fix

**Date:** 2026-04-14

## The Bug

ALL data transfer over uTP was broken. BT handshakes, wire messages, and piece data silently disappeared. The daemon connected via uTP (SYN/SYN-ACK succeeded) but no application data ever arrived.

## Root Cause

In `src/net/utp.zig`, `acceptSyn()` set `self.seq_nr = 1` and used it for the SYN-ACK header, but did NOT increment it afterward. The first DATA packet also used `seq_nr = 1`.

The remote peer set `ack_nr = 1` after processing the SYN-ACK (which had `seq_nr = 1`). It then expected the next DATA to have `seq_nr = ack_nr + 1 = 2`. When the DATA arrived with `seq_nr = 1`, the remote treated it as a duplicate of the SYN-ACK and silently dropped it.

## Fix

One line: `self.seq_nr +%= 1;` after encoding the SYN-ACK in `acceptSyn()`. The first DATA packet now uses `seq_nr = 2`, matching the remote's expectation.

## How It Was Found

TDD approach:
1. Wrote `tests/utp_bytestream_test.zig` with 3 tests exercising the uTP byte stream at the UtpSocket level (no EventLoop, no io_uring)
2. All 3 tests failed — even a single 68-byte BT handshake
3. Debug output showed: `server sends seq_nr=1, client expects seq_nr=2`
4. Traced to `acceptSyn` not incrementing after the SYN-ACK
5. One-line fix, all 3 tests pass

## Tests Added

`zig build test-utp` runs 3 tests:
- BT handshake exchange (68 bytes each direction)
- Multiple BT wire messages (BITFIELD, UNCHOKE, INTERESTED)
- Fragmented PIECE message (2000 bytes across 2 MTU-sized packets)

## Impact

This fix unblocks:
- uTP data transfer in demo_swarm (re-enable `enable_utp = true`)
- uTP peer connections in real-world downloads
- The entire uTP→BT protocol bridge

## Key Code Reference
- Fix: `src/net/utp.zig:333` (`self.seq_nr +%= 1` after SYN-ACK encode)
