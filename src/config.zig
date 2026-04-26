const std = @import("std");
const toml = @import("toml");
const mse = @import("crypto/mse.zig");

/// Fine-grained transport control inspired by uTorrent's `bt.transp_disposition`.
/// Each bit controls a specific transport direction:
///   bit 0 (1): allow outgoing TCP connections
///   bit 1 (2): allow outgoing uTP connections
///   bit 2 (4): allow incoming TCP connections
///   bit 3 (8): allow incoming uTP connections
pub const TransportDisposition = packed struct(u8) {
    outgoing_tcp: bool = true,
    outgoing_utp: bool = true,
    incoming_tcp: bool = true,
    incoming_utp: bool = true,
    _padding: u4 = 0,

    /// All transports enabled (default). Equivalent to bitfield value 15.
    pub const tcp_and_utp: TransportDisposition = .{};

    /// TCP only: no uTP in any direction. Equivalent to bitfield value 5.
    pub const tcp_only: TransportDisposition = .{
        .outgoing_tcp = true,
        .outgoing_utp = false,
        .incoming_tcp = true,
        .incoming_utp = false,
    };

    /// uTP only: no TCP in any direction. Equivalent to bitfield value 10.
    pub const utp_only: TransportDisposition = .{
        .outgoing_tcp = false,
        .outgoing_utp = true,
        .incoming_tcp = false,
        .incoming_utp = true,
    };

    /// True when at least one outbound transport is enabled.
    pub fn canConnectOutbound(self: TransportDisposition) bool {
        return self.outgoing_tcp or self.outgoing_utp;
    }

    /// True when at least one inbound transport is enabled.
    pub fn canAcceptInbound(self: TransportDisposition) bool {
        return self.incoming_tcp or self.incoming_utp;
    }

    /// Convert to the uTorrent-compatible integer representation.
    pub fn toBitfield(self: TransportDisposition) u8 {
        return @bitCast(self);
    }

    /// Parse from a uTorrent-compatible integer representation.
    pub fn fromBitfield(value: u8) TransportDisposition {
        var disp: TransportDisposition = @bitCast(value);
        disp._padding = 0;
        return disp;
    }

    /// Construct from the legacy `enable_utp` boolean.
    /// true  -> tcp_and_utp (all enabled)
    /// false -> tcp_only (TCP only)
    pub fn fromEnableUtp(enable_utp: bool) TransportDisposition {
        return if (enable_utp) tcp_and_utp else tcp_only;
    }

    /// Return the legacy `enable_utp` equivalent: true if any uTP direction is enabled.
    pub fn toEnableUtp(self: TransportDisposition) bool {
        return self.outgoing_utp or self.incoming_utp;
    }

    /// Parse a human-readable transport preset name from TOML config.
    /// Accepts: "all", "tcp_and_utp", "tcp_only", "utp_only".
    pub fn parsePreset(value: []const u8) !TransportDisposition {
        if (std.mem.eql(u8, value, "all")) return tcp_and_utp;
        if (std.mem.eql(u8, value, "tcp_and_utp")) return tcp_and_utp;
        if (std.mem.eql(u8, value, "tcp_only")) return tcp_only;
        if (std.mem.eql(u8, value, "utp_only")) return utp_only;
        return error.InvalidTransportPreset;
    }

    /// Parse a single transport flag name. Returns the corresponding
    /// disposition with only that flag enabled (all others false).
    pub fn parseFlag(value: []const u8) !TransportDisposition {
        if (std.mem.eql(u8, value, "tcp_inbound")) return .{
            .outgoing_tcp = false,
            .outgoing_utp = false,
            .incoming_tcp = true,
            .incoming_utp = false,
        };
        if (std.mem.eql(u8, value, "tcp_outbound")) return .{
            .outgoing_tcp = true,
            .outgoing_utp = false,
            .incoming_tcp = false,
            .incoming_utp = false,
        };
        if (std.mem.eql(u8, value, "utp_inbound")) return .{
            .outgoing_tcp = false,
            .outgoing_utp = false,
            .incoming_tcp = false,
            .incoming_utp = true,
        };
        if (std.mem.eql(u8, value, "utp_outbound")) return .{
            .outgoing_tcp = false,
            .outgoing_utp = true,
            .incoming_tcp = false,
            .incoming_utp = false,
        };
        return error.InvalidTransportFlag;
    }

    /// Build a TransportDisposition from a list of individual flag names.
    /// Starts with all flags disabled, enables each named flag.
    /// Valid flag names: "tcp_inbound", "tcp_outbound", "utp_inbound", "utp_outbound".
    pub fn parseFlags(values: []const []const u8) !TransportDisposition {
        var result: TransportDisposition = .{
            .outgoing_tcp = false,
            .outgoing_utp = false,
            .incoming_tcp = false,
            .incoming_utp = false,
        };
        for (values) |flag| {
            const single = try parseFlag(flag);
            result.outgoing_tcp = result.outgoing_tcp or single.outgoing_tcp;
            result.outgoing_utp = result.outgoing_utp or single.outgoing_utp;
            result.incoming_tcp = result.incoming_tcp or single.incoming_tcp;
            result.incoming_utp = result.incoming_utp or single.incoming_utp;
        }
        return result;
    }
};

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
        /// Graceful shutdown drain timeout in seconds. On SIGTERM/SIGINT, the
        /// daemon drains in-flight transfers for up to this many seconds before
        /// forcing shutdown. 0 = immediate shutdown (no drain).
        shutdown_timeout: u32 = 10,
    };

    pub const Storage = struct {
        resume_db: ?[]const u8 = null,
        data_dir: ?[]const u8 = null,
    };

    pub const Network = struct {
        port_min: u16 = 6881,
        port_max: u16 = 6889,
        max_peers: u32 = 50,
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
        /// Disable tracker announces and rely on DHT/PEX for peer discovery.
        /// Useful for testing DHT peer discovery or for privacy-conscious operation.
        /// Private torrents (private=1 flag) always use the tracker regardless of this setting.
        disable_trackers: bool = false,
        /// Maximum bytes to request in a single web seed HTTP Range request.
        /// Larger values batch more pieces per request, reducing HTTP overhead.
        /// Default: 4 MB.
        web_seed_max_request_bytes: u32 = 4 * 1024 * 1024,
        /// Enable DHT (BEP 5) for distributed peer discovery.
        dht: bool = true,
        /// Enable PEX (BEP 11) for peer exchange between connected peers.
        pex: bool = true,
        /// Legacy toggle for uTP (BEP 29) transport for peer connections.
        /// Kept for backwards compatibility with existing config files.
        /// When `transport` is also set, `transport` takes precedence.
        /// true  -> "tcp_and_utp" (both TCP and uTP enabled in all directions)
        /// false -> "tcp_only"    (TCP only, no uTP)
        enable_utp: bool = true,
        /// Fine-grained transport control. Accepts either a preset string
        /// ("all", "tcp_and_utp", "tcp_only", "utp_only") or a list of
        /// individual flags (["tcp_inbound", "tcp_outbound", "utp_inbound",
        /// "utp_outbound"]). Takes precedence over `enable_utp` when set.
        /// Default null means fall through to `enable_utp`.
        transport: ?TransportDisposition = null,

        /// Resolve the effective TransportDisposition from config fields.
        /// `transport` takes precedence when set; otherwise falls back to `enable_utp`.
        pub fn resolveTransportDisposition(self: Network) TransportDisposition {
            if (self.transport) |disp| {
                return disp;
            }
            return TransportDisposition.fromEnableUtp(self.enable_utp);
        }

        /// Custom TOML deserialization for Network. Handles the `transport`
        /// field specially (accepts both string presets and arrays of flag
        /// names), then maps all other fields via standard value extraction.
        pub fn tomlIntoStruct(ctx: anytype, table: *toml.Table) !Network {
            var result = Network{};
            const alloc = ctx.alloc;

            // Handle `transport` specially: string preset or array of flags.
            if (table.fetchRemove("transport")) |entry| {
                alloc.free(entry.key);
                switch (entry.value) {
                    .string => |s| {
                        result.transport = TransportDisposition.parsePreset(s) catch
                            return error.InvalidTransportPreset;
                    },
                    .array => |ar| {
                        // Collect string values from the array.
                        var flags: [4][]const u8 = undefined;
                        if (ar.items.len == 0 or ar.items.len > 4) return error.InvalidTransportFlag;
                        for (ar.items, 0..) |item, i| {
                            switch (item) {
                                .string => |s| flags[i] = s,
                                else => return error.InvalidTransportFlag,
                            }
                        }
                        result.transport = TransportDisposition.parseFlags(flags[0..ar.items.len]) catch
                            return error.InvalidTransportFlag;
                    },
                    else => return error.InvalidTransportPreset,
                }
            }

            // Map remaining fields using type-directed extraction.
            inline for (@typeInfo(Network).@"struct".fields) |field| {
                if (comptime std.mem.eql(u8, field.name, "transport")) continue;
                // Skip methods/decls, only process actual fields.
                if (table.fetchRemove(field.name)) |entry| {
                    alloc.free(entry.key);
                    setField(Network, &result, field.name, entry.value) catch
                        return error.InvalidValueType;
                }
                // Fields not present in TOML keep their default values.
            }

            // Clean up any unknown keys remaining in the table.
            var it = table.iterator();
            while (it.next()) |entry| {
                alloc.free(entry.key_ptr.*);
                entry.value_ptr.deinit(alloc);
            }
            table.deinit();

            return result;
        }
    };

    /// Set a named field on a struct from a TOML Value, using type-directed
    /// dispatch. Handles the subset of types used by Network fields.
    fn setField(comptime T: type, dest: *T, comptime name: []const u8, value: toml.Value) !void {
        const FieldType = @TypeOf(@field(dest.*, name));
        switch (@typeInfo(FieldType)) {
            .int => {
                switch (value) {
                    .integer => |x| @field(dest.*, name) = @intCast(x),
                    else => return error.InvalidValueType,
                }
            },
            .float => {
                switch (value) {
                    .float => |x| @field(dest.*, name) = @floatCast(x),
                    .integer => |x| @field(dest.*, name) = @floatFromInt(x),
                    else => return error.InvalidValueType,
                }
            },
            .bool => {
                switch (value) {
                    .boolean => |b| @field(dest.*, name) = b,
                    else => return error.InvalidValueType,
                }
            },
            .pointer => |ptr_info| {
                if (ptr_info.size == .slice and ptr_info.child == u8) {
                    switch (value) {
                        .string => |s| @field(dest.*, name) = s,
                        else => return error.InvalidValueType,
                    }
                } else {
                    return error.InvalidValueType;
                }
            },
            .optional => |opt_info| {
                switch (@typeInfo(opt_info.child)) {
                    .pointer => |ptr_info| {
                        if (ptr_info.size == .slice and ptr_info.child == u8) {
                            switch (value) {
                                .string => |s| @field(dest.*, name) = s,
                                else => return error.InvalidValueType,
                            }
                        } else {
                            return error.InvalidValueType;
                        }
                    },
                    else => return error.InvalidValueType,
                }
            },
            else => return error.InvalidValueType,
        }
    }

    pub const Performance = struct {
        hasher_threads: u32 = 4,
        /// Piece cache size in bytes. 0 = use default (64 MB).
        piece_cache_size: u64 = 0,
    };
};

/// Parsed config result. Holds ownership of the TOML parse tree so that
/// string slices in the Config struct remain valid for the program lifetime.
pub const LoadedConfig = struct {
    value: Config,
    /// Opaque handle to the TOML parse tree. Must NOT be deinit'd while
    /// Config string slices (data_dir, bind_device, etc.) are still in use.
    _parse_result: ?toml.Parsed(Config) = null,

    pub fn deinit(self: *LoadedConfig) void {
        if (self._parse_result) |r| {
            var copy = r;
            copy.deinit();
        }
    }
};

pub fn load(allocator: std.mem.Allocator, path: []const u8) !LoadedConfig {
    var parser = toml.Parser(Config).init(allocator);
    const result = try parser.parseFile(path);
    errdefer {
        var copy = result;
        copy.deinit();
    }
    try validateConfig(result.value);
    // Do NOT deinit result — the Config's string slices point into its memory.
    // Ownership transfers to the caller via LoadedConfig.
    return .{ .value = result.value, ._parse_result = result };
}

fn loadOptional(allocator: std.mem.Allocator, path: []const u8) !?LoadedConfig {
    return load(allocator, path) catch |err| switch (err) {
        error.FileNotFound => null,
        else => return err,
    };
}

fn loadFromCandidates(
    allocator: std.mem.Allocator,
    paths: []const []const u8,
    xdg_config_home: ?[]const u8,
    home: ?[]const u8,
) !LoadedConfig {
    for (paths) |path| {
        if (try loadOptional(allocator, path)) |config| {
            return config;
        }
    }

    // Check $XDG_CONFIG_HOME/varuna/config.toml
    if (xdg_config_home) |xdg| {
        var buf: [1024]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/varuna/config.toml", .{xdg});
        if (try loadOptional(allocator, path)) |config| {
            return config;
        }
    }

    // Check ~/.config/varuna/config.toml
    if (home) |home_dir| {
        var buf: [1024]u8 = undefined;
        const path = try std.fmt.bufPrint(&buf, "{s}/.config/varuna/config.toml", .{home_dir});
        if (try loadOptional(allocator, path)) |config| {
            return config;
        }
    }

    return .{ .value = Config{} };
}

pub fn loadDefault(allocator: std.mem.Allocator) !LoadedConfig {
    const paths = [_][]const u8{
        "varuna.toml",
        "/etc/varuna/config.toml",
    };
    return loadFromCandidates(
        allocator,
        &paths,
        std.posix.getenv("XDG_CONFIG_HOME"),
        std.posix.getenv("HOME"),
    );
}

pub fn validateConfig(config: Config) !void {
    _ = try parseEncryptionMode(config.network.encryption);
    _ = config.network.resolveTransportDisposition();
}

/// Parse the encryption config string into an EncryptionMode enum.
pub fn parseEncryptionMode(value: []const u8) !mse.EncryptionMode {
    if (std.mem.eql(u8, value, "forced")) return .forced;
    if (std.mem.eql(u8, value, "preferred")) return .preferred;
    if (std.mem.eql(u8, value, "enabled")) return .enabled;
    if (std.mem.eql(u8, value, "disabled")) return .disabled;
    return error.InvalidEncryptionMode;
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
    try std.testing.expectEqual(@as(?[]const u8, null), config.network.bind_device);
    try std.testing.expectEqual(@as(?[]const u8, null), config.network.bind_address);
}

test "load missing file returns FileNotFound" {
    try std.testing.expectError(error.FileNotFound, load(std.testing.allocator, "nonexistent.toml"));
}

test "parseEncryptionMode recognizes all modes" {
    try std.testing.expectEqual(mse.EncryptionMode.forced, try parseEncryptionMode("forced"));
    try std.testing.expectEqual(mse.EncryptionMode.preferred, try parseEncryptionMode("preferred"));
    try std.testing.expectEqual(mse.EncryptionMode.enabled, try parseEncryptionMode("enabled"));
    try std.testing.expectEqual(mse.EncryptionMode.disabled, try parseEncryptionMode("disabled"));
    try std.testing.expectError(error.InvalidEncryptionMode, parseEncryptionMode("unknown"));
}

test "loadDefault stops on malformed config in current directory" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = try std.fs.cwd().openDir(".", .{});
    defer cwd.close();

    try tmp.dir.writeFile(.{
        .sub_path = "varuna.toml",
        .data = "[daemon]\napi_port = \"not-a-number\"\n",
    });
    try tmp.dir.setAsCwd();
    defer cwd.setAsCwd() catch unreachable;

    if (loadDefault(std.testing.allocator)) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

test "loadDefault returns defaults when no config is discovered" {
    const loaded = try loadFromCandidates(std.testing.allocator, &.{}, null, null);
    defer {
        var copy = loaded;
        copy.deinit();
    }

    try std.testing.expectEqual(@as(u16, 8080), loaded.value.daemon.api_port);
    try std.testing.expectEqualSlices(u8, "preferred", loaded.value.network.encryption);
}

test "load rejects invalid encryption mode" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = try std.fs.cwd().openDir(".", .{});
    defer cwd.close();

    try tmp.dir.writeFile(.{
        .sub_path = "invalid-encryption.toml",
        .data = "[network]\nencryption = \"bad-mode\"\n",
    });
    try tmp.dir.setAsCwd();
    defer cwd.setAsCwd() catch unreachable;

    try std.testing.expectError(
        error.InvalidEncryptionMode,
        load(std.testing.allocator, "invalid-encryption.toml"),
    );
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

test "default enable_utp is true" {
    const config = Config{};
    try std.testing.expect(config.network.enable_utp);
}

test "default transport disposition is tcp_and_utp" {
    const config = Config{};
    const disp = config.network.resolveTransportDisposition();
    try std.testing.expect(disp.outgoing_tcp);
    try std.testing.expect(disp.outgoing_utp);
    try std.testing.expect(disp.incoming_tcp);
    try std.testing.expect(disp.incoming_utp);
}

test "enable_utp false resolves to tcp_only disposition" {
    var net = Config.Network{};
    net.enable_utp = false;
    const disp = net.resolveTransportDisposition();
    try std.testing.expect(disp.outgoing_tcp);
    try std.testing.expect(!disp.outgoing_utp);
    try std.testing.expect(disp.incoming_tcp);
    try std.testing.expect(!disp.incoming_utp);
}

test "transport disposition overrides enable_utp" {
    var net = Config.Network{};
    net.enable_utp = false; // would normally mean tcp_only
    net.transport = TransportDisposition.utp_only; // but transport takes precedence
    const disp = net.resolveTransportDisposition();
    try std.testing.expect(!disp.outgoing_tcp);
    try std.testing.expect(disp.outgoing_utp);
    try std.testing.expect(!disp.incoming_tcp);
    try std.testing.expect(disp.incoming_utp);
}

test "TransportDisposition parsePreset recognizes all presets" {
    const all = try TransportDisposition.parsePreset("all");
    try std.testing.expect(all.outgoing_tcp and all.outgoing_utp);
    try std.testing.expect(all.incoming_tcp and all.incoming_utp);

    const tcp_and_utp = try TransportDisposition.parsePreset("tcp_and_utp");
    try std.testing.expect(tcp_and_utp.outgoing_tcp and tcp_and_utp.outgoing_utp);
    try std.testing.expect(tcp_and_utp.incoming_tcp and tcp_and_utp.incoming_utp);

    const tcp_only = try TransportDisposition.parsePreset("tcp_only");
    try std.testing.expect(tcp_only.outgoing_tcp and !tcp_only.outgoing_utp);
    try std.testing.expect(tcp_only.incoming_tcp and !tcp_only.incoming_utp);

    const utp_only = try TransportDisposition.parsePreset("utp_only");
    try std.testing.expect(!utp_only.outgoing_tcp and utp_only.outgoing_utp);
    try std.testing.expect(!utp_only.incoming_tcp and utp_only.incoming_utp);

    try std.testing.expectError(error.InvalidTransportPreset, TransportDisposition.parsePreset("invalid"));
}

test "TransportDisposition parseFlag recognizes individual flags" {
    const tcp_in = try TransportDisposition.parseFlag("tcp_inbound");
    try std.testing.expect(!tcp_in.outgoing_tcp and !tcp_in.outgoing_utp);
    try std.testing.expect(tcp_in.incoming_tcp and !tcp_in.incoming_utp);

    const tcp_out = try TransportDisposition.parseFlag("tcp_outbound");
    try std.testing.expect(tcp_out.outgoing_tcp and !tcp_out.outgoing_utp);
    try std.testing.expect(!tcp_out.incoming_tcp and !tcp_out.incoming_utp);

    const utp_in = try TransportDisposition.parseFlag("utp_inbound");
    try std.testing.expect(!utp_in.outgoing_tcp and !utp_in.outgoing_utp);
    try std.testing.expect(!utp_in.incoming_tcp and utp_in.incoming_utp);

    const utp_out = try TransportDisposition.parseFlag("utp_outbound");
    try std.testing.expect(!utp_out.outgoing_tcp and utp_out.outgoing_utp);
    try std.testing.expect(!utp_out.incoming_tcp and !utp_out.incoming_utp);

    try std.testing.expectError(error.InvalidTransportFlag, TransportDisposition.parseFlag("bogus"));
}

test "TransportDisposition parseFlags combines multiple flags" {
    // All four flags = same as tcp_and_utp
    const all = try TransportDisposition.parseFlags(&.{ "tcp_inbound", "tcp_outbound", "utp_inbound", "utp_outbound" });
    try std.testing.expect(all.outgoing_tcp and all.outgoing_utp);
    try std.testing.expect(all.incoming_tcp and all.incoming_utp);

    // TCP only via flags
    const tcp = try TransportDisposition.parseFlags(&.{ "tcp_inbound", "tcp_outbound" });
    try std.testing.expect(tcp.outgoing_tcp and !tcp.outgoing_utp);
    try std.testing.expect(tcp.incoming_tcp and !tcp.incoming_utp);

    // Asymmetric: TCP inbound + uTP outbound
    const asym = try TransportDisposition.parseFlags(&.{ "tcp_inbound", "utp_outbound" });
    try std.testing.expect(!asym.outgoing_tcp and asym.outgoing_utp);
    try std.testing.expect(asym.incoming_tcp and !asym.incoming_utp);

    // Single flag
    const single = try TransportDisposition.parseFlags(&.{"tcp_outbound"});
    try std.testing.expect(single.outgoing_tcp and !single.outgoing_utp);
    try std.testing.expect(!single.incoming_tcp and !single.incoming_utp);

    // Invalid flag in list
    try std.testing.expectError(error.InvalidTransportFlag, TransportDisposition.parseFlags(&.{ "tcp_inbound", "bad" }));
}

test "TransportDisposition bitfield round-trip" {
    const disp = TransportDisposition.tcp_and_utp;
    try std.testing.expectEqual(@as(u8, 15), disp.toBitfield());
    const rt = TransportDisposition.fromBitfield(15);
    try std.testing.expect(rt.outgoing_tcp and rt.outgoing_utp);
    try std.testing.expect(rt.incoming_tcp and rt.incoming_utp);

    try std.testing.expectEqual(@as(u8, 5), TransportDisposition.tcp_only.toBitfield());
    try std.testing.expectEqual(@as(u8, 10), TransportDisposition.utp_only.toBitfield());
}

test "TransportDisposition fromEnableUtp mapping" {
    const enabled = TransportDisposition.fromEnableUtp(true);
    try std.testing.expect(enabled.outgoing_tcp and enabled.outgoing_utp);
    try std.testing.expect(enabled.incoming_tcp and enabled.incoming_utp);

    const disabled = TransportDisposition.fromEnableUtp(false);
    try std.testing.expect(disabled.outgoing_tcp and !disabled.outgoing_utp);
    try std.testing.expect(disabled.incoming_tcp and !disabled.incoming_utp);
}

test "TransportDisposition toEnableUtp" {
    try std.testing.expect(TransportDisposition.tcp_and_utp.toEnableUtp());
    try std.testing.expect(!TransportDisposition.tcp_only.toEnableUtp());
    try std.testing.expect(TransportDisposition.utp_only.toEnableUtp());
}

test "TransportDisposition canConnectOutbound and canAcceptInbound" {
    try std.testing.expect(TransportDisposition.tcp_and_utp.canConnectOutbound());
    try std.testing.expect(TransportDisposition.tcp_and_utp.canAcceptInbound());
    try std.testing.expect(TransportDisposition.tcp_only.canConnectOutbound());
    try std.testing.expect(TransportDisposition.tcp_only.canAcceptInbound());

    // No transports at all
    const none: TransportDisposition = .{
        .outgoing_tcp = false,
        .outgoing_utp = false,
        .incoming_tcp = false,
        .incoming_utp = false,
    };
    try std.testing.expect(!none.canConnectOutbound());
    try std.testing.expect(!none.canAcceptInbound());
}

test "load rejects invalid transport preset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = try std.fs.cwd().openDir(".", .{});
    defer cwd.close();

    try tmp.dir.writeFile(.{
        .sub_path = "bad-transport.toml",
        .data = "[network]\ntransport = \"bad-mode\"\n",
    });
    try tmp.dir.setAsCwd();
    defer cwd.setAsCwd() catch unreachable;

    try std.testing.expectError(
        error.InvalidTransportPreset,
        load(std.testing.allocator, "bad-transport.toml"),
    );
}

test "load accepts transport as string preset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = try std.fs.cwd().openDir(".", .{});
    defer cwd.close();

    try tmp.dir.writeFile(.{
        .sub_path = "tcp-only.toml",
        .data = "[network]\ntransport = \"tcp_only\"\n",
    });
    try tmp.dir.setAsCwd();
    defer cwd.setAsCwd() catch unreachable;

    var loaded = try load(std.testing.allocator, "tcp-only.toml");
    defer loaded.deinit();
    const disp = loaded.value.network.resolveTransportDisposition();
    try std.testing.expect(disp.outgoing_tcp);
    try std.testing.expect(!disp.outgoing_utp);
    try std.testing.expect(disp.incoming_tcp);
    try std.testing.expect(!disp.incoming_utp);
}

test "load accepts transport as all preset" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = try std.fs.cwd().openDir(".", .{});
    defer cwd.close();

    try tmp.dir.writeFile(.{
        .sub_path = "all-transport.toml",
        .data = "[network]\ntransport = \"all\"\n",
    });
    try tmp.dir.setAsCwd();
    defer cwd.setAsCwd() catch unreachable;

    var loaded = try load(std.testing.allocator, "all-transport.toml");
    defer loaded.deinit();
    const disp = loaded.value.network.resolveTransportDisposition();
    try std.testing.expect(disp.outgoing_tcp);
    try std.testing.expect(disp.outgoing_utp);
    try std.testing.expect(disp.incoming_tcp);
    try std.testing.expect(disp.incoming_utp);
}

test "load accepts transport as array of flags" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = try std.fs.cwd().openDir(".", .{});
    defer cwd.close();

    try tmp.dir.writeFile(.{
        .sub_path = "transport-array.toml",
        .data = "[network]\ntransport = [\"tcp_inbound\", \"tcp_outbound\", \"utp_inbound\", \"utp_outbound\"]\n",
    });
    try tmp.dir.setAsCwd();
    defer cwd.setAsCwd() catch unreachable;

    var loaded = try load(std.testing.allocator, "transport-array.toml");
    defer loaded.deinit();
    const disp = loaded.value.network.resolveTransportDisposition();
    try std.testing.expect(disp.outgoing_tcp);
    try std.testing.expect(disp.outgoing_utp);
    try std.testing.expect(disp.incoming_tcp);
    try std.testing.expect(disp.incoming_utp);
}

test "load accepts asymmetric transport array" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = try std.fs.cwd().openDir(".", .{});
    defer cwd.close();

    try tmp.dir.writeFile(.{
        .sub_path = "asym-transport.toml",
        .data = "[network]\ntransport = [\"tcp_inbound\", \"utp_outbound\"]\n",
    });
    try tmp.dir.setAsCwd();
    defer cwd.setAsCwd() catch unreachable;

    var loaded = try load(std.testing.allocator, "asym-transport.toml");
    defer loaded.deinit();
    const disp = loaded.value.network.resolveTransportDisposition();
    try std.testing.expect(!disp.outgoing_tcp);
    try std.testing.expect(disp.outgoing_utp);
    try std.testing.expect(disp.incoming_tcp);
    try std.testing.expect(!disp.incoming_utp);
}

test "load rejects invalid transport flag in array" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = try std.fs.cwd().openDir(".", .{});
    defer cwd.close();

    try tmp.dir.writeFile(.{
        .sub_path = "bad-flag.toml",
        .data = "[network]\ntransport = [\"tcp_inbound\", \"bad_flag\"]\n",
    });
    try tmp.dir.setAsCwd();
    defer cwd.setAsCwd() catch unreachable;

    try std.testing.expectError(
        error.InvalidTransportFlag,
        load(std.testing.allocator, "bad-flag.toml"),
    );
}

test "load transport array with other network fields" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    var cwd = try std.fs.cwd().openDir(".", .{});
    defer cwd.close();

    try tmp.dir.writeFile(.{
        .sub_path = "full-network.toml",
        .data =
        \\[network]
        \\transport = ["tcp_inbound", "tcp_outbound"]
        \\port_min = 7000
        \\port_max = 7100
        \\max_peers = 200
        \\encryption = "forced"
        \\dht = false
        \\
        ,
    });
    try tmp.dir.setAsCwd();
    defer cwd.setAsCwd() catch unreachable;

    var loaded = try load(std.testing.allocator, "full-network.toml");
    defer loaded.deinit();
    const net = loaded.value.network;
    const disp = net.resolveTransportDisposition();
    try std.testing.expect(disp.outgoing_tcp and !disp.outgoing_utp);
    try std.testing.expect(disp.incoming_tcp and !disp.incoming_utp);
    try std.testing.expectEqual(@as(u16, 7000), net.port_min);
    try std.testing.expectEqual(@as(u16, 7100), net.port_max);
    try std.testing.expectEqual(@as(u32, 200), net.max_peers);
    try std.testing.expectEqualSlices(u8, "forced", net.encryption);
    try std.testing.expect(!net.dht);
}
