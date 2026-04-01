const backend = @import("backend.zig");

/// SHA-1 hash — implementation selected by `-Dcrypto=varuna|stdlib|boringssl`.
pub const Sha1 = backend.Sha1;

/// SHA-256 hash — implementation selected by `-Dcrypto=varuna|stdlib|boringssl`.
pub const Sha256 = backend.Sha256;

/// RC4 stream cipher — implementation selected by `-Dcrypto=varuna|stdlib|boringssl`.
/// Note: `-Dcrypto=stdlib` falls back to our implementation (no stdlib RC4).
pub const Rc4 = backend.Rc4;

/// The active crypto backend (comptime constant from build options).
pub const crypto_backend = backend.crypto_backend;

/// Direct access to our custom SHA-1 with hardware acceleration,
/// regardless of which backend is active. Useful for benchmarks.
pub const VarunaSha1 = @import("sha1.zig");

pub const rc4 = @import("rc4.zig");
pub const mse = @import("mse.zig");

test {
    _ = backend;
    _ = @import("sha1.zig");
    _ = @import("rc4.zig");
    _ = @import("mse.zig");
}
