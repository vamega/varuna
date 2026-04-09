# 2026-04-09: Crypto MSE Hardening

## What was done and why

Hardened the MSE and RC4 input-validation path so malformed peers fail early instead of driving undefined or oversized state.

- `src/crypto/mse.zig:323` adds explicit DH public-key validation (`1 < Y < P-1`) before shared-secret derivation.
- `src/crypto/mse.zig:458` and `src/crypto/mse.zig:599` now reject invalid DH public keys in the blocking initiator/responder flows.
- `src/crypto/mse.zig:883` extends the async state-machine error surface with `invalid_dh_public_key` and `initial_payload_too_large`.
- `src/crypto/mse.zig:1412` and `src/crypto/mse.zig:1478` now bound responder IA length before reading/decrypting into the fixed buffer. This closes the out-of-bounds risk from oversized initiator IA values.
- `src/crypto/rc4.zig:16` now rejects empty RC4 keys at initialization time instead of indexing `key[idx % key.len]` with `key.len == 0`.

## What was learned

- The "shared secret is not zero" check is not enough for Diffie-Hellman peer validation. Rejecting invalid public keys before exponentiation is simpler and avoids treating obviously bad peers as normal handshake failures.
- The async responder path was more fragile than the blocking path because its IA buffer size was fixed while the protocol length field is attacker-controlled.

## Remaining issues / follow-up

- Secret scrubbing is still not comprehensive across all handshake buffers and derived keys.
- This pass bounded IA to the implementation's current limit (`512` bytes). If Varuna later wants to forward larger initial payloads, the responder should switch to owned dynamic storage instead of lifting the cap.

## Code references

- `src/crypto/mse.zig:323`
- `src/crypto/mse.zig:458`
- `src/crypto/mse.zig:599`
- `src/crypto/mse.zig:883`
- `src/crypto/mse.zig:1412`
- `src/crypto/rc4.zig:16`
