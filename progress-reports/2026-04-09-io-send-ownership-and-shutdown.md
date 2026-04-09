## What Was Done

- Moved peer-wire `submitMessage` onto the tracked-send path for both small and large messages, so active control messages no longer borrow `Peer.handshake_buf` while an earlier send may still be in flight.
- Changed `EventLoop.drainRemainingCqes()` to dispatch CQEs until tracked reads, writes, sends, and timeout state are actually retired instead of polling the ring and discarding completions before freeing memory.
- Extended seed-mode pending read bookkeeping with per-span expected lengths and encoded `span_index` into the disk-read CQE context, then reject partial or mismatched read completions instead of treating any positive result as success.
- Added a focused unit test for the seed-read context encoding helper.

## What Was Learned

- The old shutdown path had the right high-level idea, but not the right mechanism: closing fds is not enough if the event loop then frees tracked buffers without dispatching the CQEs that clear those ownership tables.
- Seed-mode reads need per-span identity, not just a per-piece `read_id`. Once multiple spans are in flight, total bytes alone are not enough to prove the correct regions were filled.
- The smallest peer-wire messages are the easiest to overlook because they seem "obviously safe", but they are exactly where shared scratch buffers tend to leak into async send paths.

## Remaining Issues / Follow-Up

- This wave hardens shutdown and seed-read correctness, but it does not yet add a dedicated integration test that forces late CQEs during deinit. That would be a good follow-up once the Zig environment is stable enough for narrower repro harnesses.
- `zig build test` passed after these changes. The focused `zig build test-torrent-session` step still intermittently fails on this host with Zig's cache/toolchain `manifest_create Unexpected` issue, which is separate from the I/O fixes.
- Wave 1.4 should next address resume flush ordering, `clearTorrent()` coverage, and v2 multi-piece verification correctness.

## Verification

- Ran `zig fmt src/io/event_loop.zig src/io/protocol.zig src/io/seed_handler.zig`
- Ran `zig build test` successfully
- Re-ran `zig build test-torrent-session`; the wrapper import is fixed, but this host still hits `manifest_create Unexpected`

## Key References

- `src/io/protocol.zig:399`
- `src/io/event_loop.zig:108`
- `src/io/event_loop.zig:462`
- `src/io/seed_handler.zig:26`
- `src/io/seed_handler.zig:234`
- `src/io/seed_handler.zig:277`
- `src/io/seed_handler.zig:507`
