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
