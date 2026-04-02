const std = @import("std");
const toml = @import("toml");
const mse = @import("crypto/mse.zig");

pub const Config = struct {
    daemon: Daemon = .{},
    storage: Storage = .{},
    network: Network = .{},
    performance: Performance = .{},

    pub const Daemon = struct {
        api_port: u16 = 8080,
        api_bind: []const u8 = "127.0.0.1",
        api_username: []const u8 = "admin",
        api_password: []const u8 = "adminadmin",
        /// Enable torrent queueing. When false, all torrents are active.
        queueing_enabled: bool = false,
        /// Max torrents actively downloading. -1 = unlimited.
        max_active_downloads: i32 = 5,
        /// Max torrents actively seeding. -1 = unlimited.
        max_active_uploads: i32 = 5,
        /// Overall max active torrents (downloading + seeding). -1 = unlimited.
        max_active_torrents: i32 = -1,
        /// Enable global share ratio limit enforcement.
        max_ratio_enabled: bool = false,
        /// Target share ratio (e.g. 2.0 = upload 2x download). -1 = disabled.
        max_ratio: f64 = -1.0,
        /// Action when ratio limit reached: 0 = pause, 1 = remove torrent.
        max_ratio_act: u8 = 0,
        /// Enable global seeding time limit enforcement.
        max_seeding_time_enabled: bool = false,
        /// Maximum minutes to seed after completion. -1 = disabled.
        max_seeding_time: i64 = -1,
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
        /// MSE encryption mode: "forced", "preferred", "enabled", "disabled".
        /// forced   = only encrypted connections (RC4)
        /// preferred = prefer encryption, allow plaintext fallback
        /// enabled  = allow both encryption and plaintext
        /// disabled = no MSE, plaintext only (default)
        encryption: []const u8 = "preferred",
        /// Masquerade as a different client for peer ID generation.
        /// Format: "ClientName X.Y.Z" e.g. "qBittorrent 5.1.4", "rTorrent 0.16".
        /// Supported: qBittorrent, rTorrent, uTorrent, Deluge, Transmission.
        /// When null (default), uses Varuna's own peer ID prefix (-VR0001-).
        masquerade_as: ?[]const u8 = null,
    };

    pub const Performance = struct {
        hasher_threads: u32 = 4,
        pipeline_depth: u32 = 5,
        ring_entries: u16 = 256,
        /// Piece cache size in bytes. 0 = use default (64 MB).
        piece_cache_size: u64 = 0,
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

/// Parse the encryption config string into an EncryptionMode enum.
pub fn parseEncryptionMode(value: []const u8) mse.EncryptionMode {
    if (std.mem.eql(u8, value, "forced")) return .forced;
    if (std.mem.eql(u8, value, "preferred")) return .preferred;
    if (std.mem.eql(u8, value, "enabled")) return .enabled;
    if (std.mem.eql(u8, value, "disabled")) return .disabled;
    // Default to preferred for unknown values
    return .preferred;
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

test "parseEncryptionMode recognizes all modes" {
    try std.testing.expectEqual(mse.EncryptionMode.forced, parseEncryptionMode("forced"));
    try std.testing.expectEqual(mse.EncryptionMode.preferred, parseEncryptionMode("preferred"));
    try std.testing.expectEqual(mse.EncryptionMode.enabled, parseEncryptionMode("enabled"));
    try std.testing.expectEqual(mse.EncryptionMode.disabled, parseEncryptionMode("disabled"));
    // Unknown defaults to preferred
    try std.testing.expectEqual(mse.EncryptionMode.preferred, parseEncryptionMode("unknown"));
}

test "default encryption config is preferred" {
    const config = Config{};
    try std.testing.expectEqualSlices(u8, "preferred", config.network.encryption);
}

test "default share ratio limits are disabled" {
    const config = Config{};
    try std.testing.expect(!config.daemon.max_ratio_enabled);
    try std.testing.expect(config.daemon.max_ratio == -1.0);
    try std.testing.expectEqual(@as(u8, 0), config.daemon.max_ratio_act);
    try std.testing.expect(!config.daemon.max_seeding_time_enabled);
    try std.testing.expectEqual(@as(i64, -1), config.daemon.max_seeding_time);
}
