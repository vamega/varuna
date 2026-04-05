# MSE/PE RC4 End-to-End Fix

## What was done and why

Fixed Message Stream Encryption (BEP 6) so that two `varuna` instances can
complete a download with full RC4 encryption. Three distinct bugs were found
and fixed across two sessions.

### Bug 1: `reduceWide` DH modular reduction (previous session)

The 768-bit Diffie-Hellman `powMod` implementation had a carry-propagation
bug in `reduceWide` that caused the shared secret to differ between the two
peers, making all downstream crypto fail silently.

### Bug 2: VC scan misaligned dec_cipher (`vc_not_found`)

**Root cause**: The initiator's `dec_cipher` (key_B) was advanced byte-by-byte
through `PadB` (which arrives as plaintext before the seeder's encrypted VC).
The seeder's `enc_cipher` starts at keystream position 0 when it encrypts the
VC (8 zero bytes). By the time the actual VC bytes arrived at position
`pad_b_len`, the initiator's dec_cipher was at position `pad_b_len`, not 0.
Decryption produced garbage instead of 8 zero bytes.

**Fix** (`src/crypto/mse.zig`): Buffer all bytes received during the VC scan
(`scan_buf`). For each candidate start position `p` (tried once we have `p+8`
bytes buffered), construct a fresh `Rc4.initDiscardBep6(key_B)` and try to
decrypt 8 bytes. If the result is all zeros, the VC is found and the trial
cipher (already advanced by 8) becomes the new `dec_cipher`. Same fix applied
to the synchronous `initiateHandshake` path.

Key state added to `MseInitiatorHandshake`:
- `dec_key: [20]u8` — stores key_B so trial ciphers can be constructed
- `scan_buf: [max_pad_len + 8]u8` — accumulates bytes for sliding-window check

### Bug 3: Several send paths missing `encryptBuf`

After MSE completes, multiple send paths never called `peer.crypto.encryptBuf`
before submitting to io_uring, so those messages were sent as plaintext into a
stream the remote was decrypting with RC4 — producing garbage at the receiver.

Missing encryption calls found and fixed:
- `submitPexMessage` in `src/io/protocol.zig` — PEX (BEP 11) frames
- `sendUtMetadataReject` in `src/io/protocol.zig` — BEP 9 reject frames
- Metadata data response in `src/io/protocol.zig` — BEP 9 data frames
- `tryFillPipeline` in `src/io/peer_policy.zig` — REQUEST frames

The seeder's symptom was a corrupted message length (e.g. `0x51FBEDB9`) when
decrypting the downloader's PEX header. The downloader's enc_cipher was at the
correct keystream position but the bytes were never encrypted before sending.

### Bug 4: PEX state leaked on event loop shutdown

`PeerCrypto.pex_state` was freed in `cleanupPeer` (called by `removePeer`) but
not in the `EventLoop.deinit` peer cleanup loop. Any peer still connected when
the download completed leaked its `PexState` and its internal `sent_peers`
hashmap. Fixed by adding the missing `pex_state` free in `deinit`.

## What was learned

- **Always check every send path for encryption.** The pattern is consistent
  (`peer.crypto.encryptBuf(buf)` immediately before tracking/sending), but it's
  easy to add a new send path and forget it. The failure mode is subtle: the
  receiver's cipher advances through the plaintext bytes, so it stays
  misaligned for all *subsequent* messages. The first few messages (which were
  encrypted) decode fine; only later ones look corrupted.

- **RC4 keystream position must match exactly.** Both sides must consume the
  keystream for every byte transmitted, in order. A single missed `encryptBuf`
  or `decryptBuf` call permanently desynchronises the stream.

- **`deinit` and `removePeer` are separate cleanup paths.** Resource owners
  added to `cleanupPeer` also need to appear in the `deinit` peer loop, because
  the loop tears down remaining peers without going through `removePeer`.

- **The VC scan bug**: BEP 6 is ambiguous about whether PadB is inside or
  outside the RC4 stream. It is *outside* — PadB is sent plaintext before the
  responder starts encrypting. The initiator must not advance `dec_cipher`
  through those bytes.

## Remaining issues / follow-up

- The debug SHA1 logging added during investigation has been removed from
  `computeSharedSecret`, the initiator/responder `init` paths, and the
  `req1_not_found` error path.
- Ubuntu 25.10 ISO torrent speed test has not yet been run.

## Code references

- `src/crypto/mse.zig:1088` — `recv_vc_scan` sliding-window trial cipher
- `src/crypto/mse.zig:313` — `computeSharedSecret` (sha1 debug vars removed)
- `src/io/protocol.zig:254` — BEP 9 data response `encryptBuf` (added)
- `src/io/protocol.zig:288` — BEP 9 reject `encryptBuf` (added)
- `src/io/protocol.zig:510` — PEX `encryptBuf` (added)
- `src/io/peer_policy.zig:137` — REQUEST `encryptBuf` (added)
- `src/io/event_loop.zig:943` — `deinit` pex_state free (added)
