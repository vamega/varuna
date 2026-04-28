//! DNS resolution interface for the varuna daemon.
//!
//! This module provides a unified `DnsResolver` type and `resolveOnce` function
//! that dispatch to either a threadpool-based or c-ares-based backend depending
//! on the build configuration:
//!
//!   - `-Ddns=threadpool` (default): uses `getaddrinfo` on background threads
//!   - `-Ddns=c-ares`: uses the c-ares async DNS library with epoll fd monitoring
//!
//! Both backends provide the same public API: `DnsResolver` with `init`, `deinit`,
//! `resolve`, `invalidate`, `clearAll`, plus a standalone `resolveOnce` function.
//! Both share the same TTL cache behavior (5-minute TTL, 64-entry max).

const std = @import("std");
const build_options = @import("build_options");

const backend = if (build_options.dns_backend == .c_ares)
    @import("dns_cares.zig")
else
    @import("dns_threadpool.zig");

/// Thread-safe DNS resolver with TTL-based caching.
///
/// The underlying implementation is selected at build time:
/// - threadpool: `getaddrinfo` on a background thread (default)
/// - c-ares: async DNS via the c-ares library with epoll fd monitoring
///
/// Both backends have identical semantics:
/// - Numeric IPs (IPv4/IPv6) are parsed inline with no syscall
/// - Hostnames are cached with a 5-minute TTL, up to 64 entries
/// - Cache misses trigger resolution with a 5-second timeout
/// - Thread-safe via mutex-protected cache
pub const DnsResolver = backend.DnsResolver;

/// Resolve a hostname without caching. Numeric IPs are parsed inline;
/// hostnames go through the configured backend with a 5-second timeout.
///
/// Use this for one-off callers that don't need caching (e.g., UDP
/// tracker connections that happen infrequently). For repeated lookups,
/// prefer DnsResolver.resolve().
pub const resolveOnce = backend.resolveOnce;

/// Per-resolver init configuration. Plumbed explicitly through every
/// caller that constructs a `DnsResolver` (HttpExecutor / TrackerExecutor
/// / UdpTrackerExecutor → SessionManager → main).
///
/// **`bind_device`**: when non-null (e.g. "wg0"), the c-ares backend
/// registers an `ares_set_socket_callback` that applies `SO_BINDTODEVICE`
/// to every UDP/TCP socket the channel creates, so DNS queries egress
/// through the configured interface like peer / tracker / RPC traffic.
/// The threadpool backend (`-Ddns=threadpool`, the build default)
/// stores the value but cannot apply it — `getaddrinfo` owns its own
/// UDP socket internally with no caller hook. See `docs/custom-dns-
/// design-round2.md` §1 and STATUS.md "Known Issues" for the gap and
/// the queued custom-DNS-library follow-up.
///
/// **Lifetime contract**: when set, the slice must outlive the
/// `DnsResolver`. The daemon's caller chain borrows it from
/// `cfg.network.bind_device`, which lives in the config arena for the
/// daemon's lifetime, so this is naturally satisfied.
///
/// **`ttl_bounds`**: floor/cap applied to authoritative DNS TTLs (c-ares
/// only — the threadpool backend uses `cap_s` as a fixed lifetime since
/// `getaddrinfo` doesn't expose TTL).
pub const Config = struct {
    bind_device: ?[]const u8 = null,
    ttl_bounds: TtlBounds = TtlBounds.default,
};

/// Cache TTL bounds applied to every backend.
///
/// Backends that can extract the authoritative DNS TTL from the response
/// (currently c-ares via `ai_ttl`) clamp the answer's TTL into
/// `[cache_min_ttl_s, cache_max_ttl_s]`. Backends that cannot
/// (`getaddrinfo` via the threadpool) use `cache_max_ttl_s` as a fixed
/// cache lifetime.
pub const TtlBounds = struct {
    /// Floor (seconds). Bounds the case where an authoritative server
    /// returns TTL=0 or a very low TTL during e.g. an infrastructure
    /// migration; without this floor the cache would be defeated.
    floor_s: u32 = 30,
    /// Cap (seconds). Bounds the worst-case stale-IP window. Matches
    /// the upper end of typical tracker announce intervals (30-60 min)
    /// so a steady-state announce can hit the cache once per cycle and
    /// re-resolve once the tracker's authoritative TTL allows.
    cap_s: u32 = 60 * 60,

    /// Default bounds: floor 30 s, cap 1 h. Tuned for tracker hostnames.
    pub const default: TtlBounds = .{};

    /// Clamp an authoritative TTL into the [floor, cap] window.
    pub fn clamp(self: TtlBounds, answer_ttl_s: u32) u32 {
        return std.math.clamp(answer_ttl_s, self.floor_s, self.cap_s);
    }
};

/// Classify a connect-failure error to decide whether the cached DNS
/// answer for the destination host should be invalidated.
///
/// Rationale: the goal is to invalidate only on errors that suggest the
/// resolved IP itself is wrong (host has migrated, infrastructure moved,
/// the DNS answer is stale). Errors that mean "the IP is fine but
/// something else went wrong" (HTTP parse error, TLS handshake failure,
/// 4xx tracker response, our own submit-side bug) must NOT invalidate
/// the cache, or a single misbehaving tracker would cause us to thrash
/// DNS on every announce.
///
/// Invalidate on:
///   - error.ConnectionRefused      — peer rejected SYN; nothing live
///                                    listens at that address
///   - error.ConnectionTimedOut     — no SYN-ACK within deadline; covers
///                                    both kernel ETIMEDOUT and the
///                                    io_uring `link_timeout` case
///   - error.NetworkUnreachable     — no route to that address family /
///                                    network
///   - error.HostUnreachable        — ICMP host unreachable
///
/// Do NOT invalidate on:
///   - error.ConnectionResetByPeer  — connection was established, then
///                                    reset by the peer mid-stream; the
///                                    IP is reachable
///   - error.BrokenPipe             — same: established connection
///   - error.ConnectionAborted      — local-side abort, not a routing
///                                    or address problem
///   - error.OperationCanceled      — varuna initiated the cancel; tells
///                                    us nothing about the IP
///   - error.SubmitFailed/SocketCreateFailed — local-side resource
///                                    failure, not an IP problem
///   - error.RequestTimedOut        — overall request budget hit;
///                                    distinct from connect-level
///                                    ConnectionTimedOut and could fire
///                                    after a successful connect
///   - error.HttpProtocolError, parse errors, 4xx/5xx tracker responses
///     — by definition the IP was reachable enough to talk back
pub fn shouldInvalidateOnConnectError(err: anyerror) bool {
    return switch (err) {
        error.ConnectionRefused,
        error.ConnectionTimedOut,
        error.NetworkUnreachable,
        error.HostUnreachable,
        => true,
        else => false,
    };
}

// Re-export tests from the active backend so `zig build test` picks them up.
comptime {
    _ = backend;
}

// ── Cross-backend interface tests ────────────────────────
// These tests verify the public API contract regardless of backend.

test "DnsResolver resolves numeric ipv4 without caching" {
    var resolver = try DnsResolver.init(std.testing.allocator, .{});
    defer resolver.deinit(std.testing.allocator);

    const addr = try resolver.resolve(std.testing.allocator, "127.0.0.1", 8080);
    try std.testing.expectEqual(@as(u16, 8080), addr.getPort());
}

test "DnsResolver resolves numeric ipv6 without caching" {
    var resolver = try DnsResolver.init(std.testing.allocator, .{});
    defer resolver.deinit(std.testing.allocator);

    const addr = try resolver.resolve(std.testing.allocator, "::1", 9090);
    try std.testing.expectEqual(@as(u16, 9090), addr.getPort());
}

test "DnsResolver captures bind_device from Config" {
    var resolver = try DnsResolver.init(std.testing.allocator, .{ .bind_device = "wg0" });
    defer resolver.deinit(std.testing.allocator);

    try std.testing.expect(resolver.bind_device != null);
    try std.testing.expectEqualStrings("wg0", resolver.bind_device.?);
}

test "DnsResolver default Config has null bind_device" {
    var resolver = try DnsResolver.init(std.testing.allocator, .{});
    defer resolver.deinit(std.testing.allocator);

    try std.testing.expect(resolver.bind_device == null);
}

test "resolveOnce parses numeric addresses" {
    const addr4 = try resolveOnce(std.testing.allocator, "10.0.0.1", 6881);
    try std.testing.expectEqual(@as(u16, 6881), addr4.getPort());

    const addr6 = try resolveOnce(std.testing.allocator, "::1", 6881);
    try std.testing.expectEqual(@as(u16, 6881), addr6.getPort());
}

test "shouldInvalidateOnConnectError invalidates on routing/refusal errors" {
    try std.testing.expect(shouldInvalidateOnConnectError(error.ConnectionRefused));
    try std.testing.expect(shouldInvalidateOnConnectError(error.ConnectionTimedOut));
    try std.testing.expect(shouldInvalidateOnConnectError(error.NetworkUnreachable));
    try std.testing.expect(shouldInvalidateOnConnectError(error.HostUnreachable));
}

test "shouldInvalidateOnConnectError preserves cache on non-routing errors" {
    try std.testing.expect(!shouldInvalidateOnConnectError(error.ConnectionResetByPeer));
    try std.testing.expect(!shouldInvalidateOnConnectError(error.BrokenPipe));
    try std.testing.expect(!shouldInvalidateOnConnectError(error.ConnectionAborted));
    try std.testing.expect(!shouldInvalidateOnConnectError(error.OperationCanceled));
    try std.testing.expect(!shouldInvalidateOnConnectError(error.SubmitFailed));
    try std.testing.expect(!shouldInvalidateOnConnectError(error.SocketCreateFailed));
    try std.testing.expect(!shouldInvalidateOnConnectError(error.RequestTimedOut));
    try std.testing.expect(!shouldInvalidateOnConnectError(error.OutOfMemory));
}

test "TtlBounds.clamp floors low TTLs and caps high TTLs" {
    const bounds = TtlBounds.default;

    // TTL=0 (e.g. authoritative migration in progress) clamps to floor
    try std.testing.expectEqual(@as(u32, 30), bounds.clamp(0));
    try std.testing.expectEqual(@as(u32, 30), bounds.clamp(15));
    // Boundary
    try std.testing.expectEqual(@as(u32, 30), bounds.clamp(30));
    try std.testing.expectEqual(@as(u32, 60), bounds.clamp(60));
    // Within range passes through
    try std.testing.expectEqual(@as(u32, 600), bounds.clamp(600));
    try std.testing.expectEqual(@as(u32, 1800), bounds.clamp(1800));
    // Boundary at cap
    try std.testing.expectEqual(@as(u32, 3600), bounds.clamp(3600));
    // Above cap clamps down
    try std.testing.expectEqual(@as(u32, 3600), bounds.clamp(86400));
    try std.testing.expectEqual(@as(u32, 3600), bounds.clamp(std.math.maxInt(u32)));
}

test "TtlBounds.clamp honors custom floor/cap" {
    const tight: TtlBounds = .{ .floor_s = 60, .cap_s = 120 };
    try std.testing.expectEqual(@as(u32, 60), tight.clamp(0));
    try std.testing.expectEqual(@as(u32, 60), tight.clamp(30));
    try std.testing.expectEqual(@as(u32, 90), tight.clamp(90));
    try std.testing.expectEqual(@as(u32, 120), tight.clamp(120));
    try std.testing.expectEqual(@as(u32, 120), tight.clamp(3600));
}
