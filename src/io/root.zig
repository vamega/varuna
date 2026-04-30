pub const buffer_pools = @import("buffer_pools.zig");
pub const clock = @import("clock.zig");
pub const Clock = clock.Clock;
pub const dht_handler = @import("dht_handler.zig");
pub const downloading_piece = @import("downloading_piece.zig");
pub const dns = @import("dns.zig");
pub const dns_custom = struct {
    pub const message = @import("dns_custom/message.zig");
    pub const resolv_conf = @import("dns_custom/resolv_conf.zig");
    pub const cache = @import("dns_custom/cache.zig");
    pub const query = @import("dns_custom/query.zig");
    pub const resolver = @import("dns_custom/resolver.zig");
};
pub const event_loop = @import("event_loop.zig");
pub const io_interface = @import("io_interface.zig");
pub const types = @import("types.zig");
pub const peer_handler = @import("peer_handler.zig");
pub const protocol = @import("protocol.zig");
pub const seed_handler = @import("seed_handler.zig");
pub const super_seed = @import("super_seed.zig");
pub const peer_policy = @import("peer_policy.zig");
pub const utp_handler = @import("utp_handler.zig");
pub const hasher = @import("hasher.zig");
pub const http_blocking = @import("http_blocking.zig");
pub const http_parse = @import("http_parse.zig");
pub const http_executor = @import("http_executor.zig");
pub const metadata_handler = @import("metadata_handler.zig");
pub const rate_limiter = @import("rate_limiter.zig");
pub const recheck = @import("recheck.zig");
pub const backend = @import("backend.zig");
pub const epoll_posix_io = @import("epoll_posix_io.zig");
pub const epoll_mmap_io = @import("epoll_mmap_io.zig");
pub const posix_file_pool = @import("posix_file_pool.zig");
pub const real_io = @import("real_io.zig");
pub const kqueue_posix_io = @import("kqueue_posix_io.zig");
pub const kqueue_mmap_io = @import("kqueue_mmap_io.zig");
pub const ring = @import("ring.zig");
pub const sim_io = @import("sim_io.zig");
pub const signal = @import("signal.zig");
pub const tls = @import("tls.zig");
pub const web_seed_handler = @import("web_seed_handler.zig");

// Pull subsystem source-side `test "..."` blocks into the test runner.
// Mirrors the pattern in `src/torrent/root.zig` and `src/crypto/root.zig`:
// `pub const x = @import(...)` does NOT propagate test discovery in Zig
// 0.15.2; an explicit `_ = ...;` reference inside a `test {}` block
// is required, AND the parent root must opt-in via `_ = io;` (in
// `src/root.zig`'s test block).
//
// Files NOT listed here either have no inline tests, or have inline
// tests that aren't yet verified to compile + pass against current Zig
// std + production logic. Tracked in Task #9; expand this list as each
// subsystem's tests are validated. Wired into `mod_tests` (the
// `varuna_mod` test root) — there's no separate `addTest` step because
// cross-package namespace imports from `tests/` don't propagate test
// discovery in Zig 0.15.2; only the in-package `_ = io;` path works.
test {
    const build_options = @import("build_options");

    _ = buffer_pools;
    _ = dns;
    _ = dns_custom.message;
    _ = dns_custom.resolv_conf;
    _ = dns_custom.cache;
    _ = dns_custom.query;
    _ = dns_custom.resolver;
    _ = @import("dns_threadpool.zig");
    // dns_cares.zig wraps `@cImport("ares.h")`. The header is only on
    // the include path when `-Ddns=c-ares`. Default build (threadpool)
    // would otherwise fail with "ares.h file not found". Gate the test
    // import to match.
    if (build_options.dns_backend == .c_ares) {
        _ = @import("dns_cares.zig");
    }
    _ = downloading_piece;
    _ = event_loop;
    _ = hasher;
    _ = http_blocking;
    _ = http_parse;
    _ = io_interface;
    _ = metadata_handler;
    _ = peer_handler;
    _ = peer_policy;
    _ = protocol;
    _ = rate_limiter;
    _ = backend;
    _ = epoll_posix_io;
    _ = epoll_mmap_io;
    _ = posix_file_pool;
    _ = kqueue_posix_io;
    _ = kqueue_mmap_io;
    _ = real_io;
    _ = recheck;
    _ = ring;
    _ = seed_handler;
    _ = sim_io;
    _ = super_seed;
    _ = tls;
    _ = web_seed_handler;
}
