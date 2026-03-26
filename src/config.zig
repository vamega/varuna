const std = @import("std");
const toml = @import("toml");

pub const Config = struct {
    storage: Storage = .{},
    network: Network = .{},
    performance: Performance = .{},

    pub const Storage = struct {
        resume_db: ?[]const u8 = null,
        data_dir: ?[]const u8 = null,
    };

    pub const Network = struct {
        port: u16 = 6881,
        max_peers: u32 = 50,
        connect_timeout_secs: u32 = 10,
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
    try std.testing.expectEqual(@as(u16, 6881), config.network.port);
    try std.testing.expectEqual(@as(u32, 50), config.network.max_peers);
    try std.testing.expectEqual(@as(u32, 4), config.performance.hasher_threads);
    try std.testing.expectEqual(@as(u32, 5), config.performance.pipeline_depth);
}

test "load missing file returns defaults" {
    const config = load(std.testing.allocator, "nonexistent.toml") catch Config{};
    try std.testing.expectEqual(@as(u16, 6881), config.network.port);
}
