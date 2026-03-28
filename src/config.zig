const std = @import("std");
const toml = @import("toml");

pub const Config = struct {
    daemon: Daemon = .{},
    storage: Storage = .{},
    network: Network = .{},
    performance: Performance = .{},

    pub const Daemon = struct {
        api_port: u16 = 8080,
        api_bind: []const u8 = "127.0.0.1",
    };

    pub const Storage = struct {
        resume_db: ?[]const u8 = null,
        data_dir: ?[]const u8 = null,
    };

    pub const Network = struct {
        port_min: u16 = 6881,
        port_max: u16 = 6889,
        max_peers: u32 = 50,
        connect_timeout_secs: u32 = 10,
        /// Global maximum number of connections across all torrents.
        max_connections: u32 = 500,
        /// Maximum number of peers per individual torrent.
        max_peers_per_torrent: u32 = 100,
        /// Maximum number of simultaneous outbound connections (SYN queue protection).
        max_half_open: u32 = 50,
        /// Global download speed limit in bytes/sec. 0 = unlimited.
        dl_limit: u64 = 0,
        /// Global upload speed limit in bytes/sec. 0 = unlimited.
        ul_limit: u64 = 0,
        /// Network interface to bind to (e.g. "wg0"). Requires CAP_NET_RAW or root.
        bind_device: ?[]const u8 = null,
        /// Local IP address to bind to (e.g. "10.0.0.1").
        bind_address: ?[]const u8 = null,
    };

    pub const Performance = struct {
        hasher_threads: u32 = 4,
        pipeline_depth: u32 = 5,
        ring_entries: u16 = 256,
    };
};

pub fn load(allocator: std.mem.Allocator, path: []const u8) !Config {
    var parser = toml.Parser(Config).init(allocator);
    const result = parser.parseFile(path) catch |err| switch (err) {
        error.FileNotFound => return Config{},
        else => return err,
    };
    defer result.deinit();
    return result.value;
}

pub fn loadDefault(allocator: std.mem.Allocator) Config {
    // Try well-known paths in order
    const paths = [_][]const u8{
        "varuna.toml",
        "/etc/varuna/config.toml",
    };

    for (paths) |path| {
        if (load(allocator, path)) |config| {
            return config;
        } else |_| {}
    }

    // Check $XDG_CONFIG_HOME/varuna/config.toml
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/varuna/config.toml", .{xdg}) catch return Config{};
        if (load(allocator, path)) |config| {
            return config;
        } else |_| {}
    }

    // Check ~/.config/varuna/config.toml
    if (std.posix.getenv("HOME")) |home| {
        var buf: [1024]u8 = undefined;
        const path = std.fmt.bufPrint(&buf, "{s}/.config/varuna/config.toml", .{home}) catch return Config{};
        if (load(allocator, path)) |config| {
            return config;
        } else |_| {}
    }

    return Config{};
}

test "default config has sensible values" {
    const config = Config{};
    try std.testing.expectEqual(@as(u16, 6881), config.network.port_min);
    try std.testing.expectEqual(@as(u16, 6889), config.network.port_max);
    try std.testing.expectEqual(@as(u32, 50), config.network.max_peers);
    try std.testing.expectEqual(@as(u32, 500), config.network.max_connections);
    try std.testing.expectEqual(@as(u32, 100), config.network.max_peers_per_torrent);
    try std.testing.expectEqual(@as(u32, 50), config.network.max_half_open);
    try std.testing.expectEqual(@as(u32, 4), config.performance.hasher_threads);
    try std.testing.expectEqual(@as(u32, 5), config.performance.pipeline_depth);
    try std.testing.expectEqual(@as(?[]const u8, null), config.network.bind_device);
    try std.testing.expectEqual(@as(?[]const u8, null), config.network.bind_address);
}

test "load missing file returns defaults" {
    const config = load(std.testing.allocator, "nonexistent.toml") catch Config{};
    try std.testing.expectEqual(@as(u16, 6881), config.network.port_min);
}
