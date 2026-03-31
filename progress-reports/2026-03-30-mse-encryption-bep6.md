# MSE/PE Encryption (BEP 6)

## What was done

Implemented Message Stream Encryption (MSE/PE) per BEP 6 for BitTorrent connection obfuscation. This is required by some private trackers and helps avoid ISP throttling of unencrypted BitTorrent traffic.

### New files
- `src/crypto/rc4.zig` -- RC4 stream cipher with BEP 6 1024-byte discard
- `src/crypto/mse.zig` -- Full MSE handshake protocol: DH key exchange, SKEY identification, crypto negotiation, both initiator and responder roles

### Modified files
- `src/crypto/root.zig` -- Export new modules
- `src/config.zig` -- Added `encryption` config field and `parseEncryptionMode()` helper
- `src/io/event_loop.zig` -- Added `PeerCrypto` to Peer struct, `encryption_mode` to EventLoop
- `src/io/peer_handler.zig` -- Transparent decryption of received data in `handleRecv`
- `src/io/protocol.zig` -- Encryption of outgoing messages in `submitMessage` and `submitExtensionHandshake`
- `src/io/seed_handler.zig` -- Encryption of piece data in batch flush and individual block sends
- `src/main.zig` -- Wire encryption config to event loop
- `src/rpc/handlers.zig` -- Expose encryption mode in qBittorrent-compatible preferences API

## Key design decisions

### 768-bit big-integer arithmetic
BEP 6 requires DH with a specific 768-bit prime. Zig stdlib does not have big-integer support suitable for modular exponentiation, so `U768` was implemented from scratch with:
- 12 x u64 limbs in little-endian order
- Schoolbook multiplication with double-width (1536-bit) intermediate
- Barrett-like reduction from MSB down
- Square-and-multiply modular exponentiation

### RC4 with 1024-byte discard
BEP 6 mandates discarding the first 1024 bytes of RC4 keystream. This defends against known-plaintext attacks on early RC4 output. `Rc4.initDiscardBep6()` handles this automatically.

### Transparent encrypt/decrypt in event loop
Rather than adding MSE-specific states to the event loop state machine (which would be complex), encryption/decryption is applied transparently:
- **Recv path**: Newly received bytes are decrypted in-place immediately after the io_uring CQE completes, before any protocol parsing
- **Send path**: Message bytes are encrypted in-place just before the io_uring send SQE is submitted
- The rest of the protocol code (handshake validation, message parsing, etc.) operates on plaintext

### Blocking vs async handshake
The MSE handshake itself is implemented using blocking Ring I/O (like the existing `peer_wire.zig` handshake functions). This works for varuna-tools and for synchronous connection paths. Full async event loop integration (MSE handshake as a state machine) is noted as remaining work.

## What was learned

- BEP 6 uses DH with generator g=2 and a 768-bit prime from RFC 2409. The prime's top limb is 0xFFFFFFFFFFFFFFFF which makes Barrett reduction almost exact (quotient estimate is very close).
- The SKEY identification scheme (HASH('req2', SKEY) XOR HASH('req3', S)) allows the responder to identify which torrent the initiator wants without revealing the info-hash to passive observers.
- RC4 key derivation uses separate keys for each direction: HASH('keyA', S, SKEY) for initiator->responder and HASH('keyB', S, SKEY) for responder->initiator.
- The VC (verification constant, 8 zero bytes) serves as a synchronization point -- the responder scans the decrypted stream for 8 consecutive zeros to find where the encrypted portion begins.

## Test coverage

25 new tests:
- 6 RC4 tests: known test vectors (Key/Plaintext, Wiki/pedia), encrypt-decrypt roundtrip, BEP 6 discard behavior, keystream generation
- 7 big-integer tests: from/to bytes, from u64, addition, subtraction, comparison, mulMod, powMod
- 2 DH tests: key exchange produces same shared secret, public key is non-trivial
- 1 hash derivation test: req1/req3/keyA/keyB produce different outputs
- 3 crypto negotiation tests: forced, preferred, disabled modes
- 3 PeerCrypto tests: encrypt/decrypt roundtrip, plaintext no-op, bidirectional with separate keys
- 1 component integration test: DH + SKEY identification + cipher setup via socket pair
- 2 threaded handshake tests: full MSE handshake (RC4 negotiation), plaintext fallback

## Remaining work

- Async MSE handshake state machine in the event loop (for production daemon connections)
- Automatic MSE fallback: try encrypted first, fall back to plaintext on connection failure
- Integration test with demo_swarm.sh using encrypted connections
