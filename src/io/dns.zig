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
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    const addr = try resolver.resolve(std.testing.allocator, "127.0.0.1", 8080);
    try std.testing.expectEqual(@as(u16, 8080), addr.getPort());
}

test "DnsResolver resolves numeric ipv6 without caching" {
    var resolver = try DnsResolver.init(std.testing.allocator);
    defer resolver.deinit(std.testing.allocator);

    const addr = try resolver.resolve(std.testing.allocator, "::1", 9090);
    try std.testing.expectEqual(@as(u16, 9090), addr.getPort());
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
