# Multi-Block Piece Download Stall - Root Cause Found

**Date:** 2026-03-27
**Status:** Root cause identified, fix needed

## Root Cause

Two bugs identified:

### 1. Truncated bitfield for >96 pieces (FIXED)
`submitMessage` for payloads > 12 bytes only sent the header, not the payload.
Fixed by allocating a complete buffer for large messages.

### 2. No partial send handling (NOT YET FIXED)
When the seed sends a piece response (13-byte header + 16KB block = ~16KB total),
the io_uring send may complete partially. `handleSend` only checks `res <= 0` but
doesn't re-send the remaining bytes if `res < buffer.len`.

For 16KB pieces (1 block), the total message is ~16397 bytes which may complete in
one send on localhost. For multi-block pieces, the seed sends multiple 16KB responses
rapidly, and the kernel's send buffer can fill, causing partial sends.

The downloader receives a truncated message, fails to parse it (the 4-byte length
prefix says N bytes but only M < N bytes arrive before the next message starts),
and the state machine breaks.

## Impact

- 16KB pieces (1 block per piece): works for up to 10MB (640 pieces)
- 64KB+ pieces (4+ blocks per piece): fails even for 1 piece

## Fix Needed

In `handleSend`, check if `cqe.res < expected_send_len`. If partial:
1. Calculate remaining bytes: `buffer[cqe.res..]`
2. Re-submit a send SQE for the remaining bytes
3. Track the expected total per send

This requires storing the original buffer + length in the pending_sends entry
so we can re-submit the remainder.

## Learnings

1. io_uring send is NOT guaranteed to send all bytes in one CQE, even on localhost
2. The BT protocol has large messages (piece responses) that commonly exceed
   TCP send buffer boundaries
3. Every send SQE needs partial send handling, similar to `send_all` in the
   blocking Ring wrapper
