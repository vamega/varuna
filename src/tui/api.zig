/// HTTP client for communicating with the varuna daemon's qBittorrent-compatible WebAPI.
///
/// Uses std.json for all JSON parsing with typed response structs.
/// HTTP requests run on a background thread via libxev ThreadPool to keep the
/// UI thread non-blocking. Results are delivered via libxev Async wakeup.
const std = @import("std");

const Allocator = std.mem.Allocator;

// ── API response types ──────────────────────────────────────────

/// Torrent state as reported by the daemon.
pub const TorrentState = enum {
    downloading,
    stalledDL,
    uploading,
    stalledUP,
    pausedDL,
    pausedUP,
    queuedDL,
    queuedUP,
    checking,
    error_state,
    missingFiles,
    moving,
    metaDL,
    unknown,

    pub fn fromString(s: []const u8) TorrentState {
        const map = std.StaticStringMap(TorrentState).initComptime(.{
            .{ "downloading", .downloading },
            .{ "stalledDL", .stalledDL },
            .{ "uploading", .uploading },
            .{ "stalledUP", .stalledUP },
            .{ "pausedDL", .pausedDL },
            .{ "pausedUP", .pausedUP },
            .{ "queuedDL", .queuedDL },
            .{ "queuedUP", .queuedUP },
            .{ "checkingDL", .checking },
            .{ "checkingUP", .checking },
            .{ "checkingResumeData", .checking },
            .{ "error", .error_state },
            .{ "missingFiles", .missingFiles },
            .{ "moving", .moving },
            .{ "metaDL", .metaDL },
            .{ "forcedDL", .downloading },
            .{ "forcedUP", .uploading },
            .{ "forcedMetaDL", .metaDL },
        });
        return map.get(s) orelse .unknown;
    }

    pub fn displayString(self: TorrentState) []const u8 {
        return switch (self) {
            .downloading => "Downloading",
            .stalledDL => "Stalled DL",
            .uploading => "Seeding",
            .stalledUP => "Stalled UP",
            .pausedDL => "Paused",
            .pausedUP => "Paused",
            .queuedDL => "Queued",
            .queuedUP => "Queued",
            .checking => "Checking",
            .error_state => "Error",
            .missingFiles => "Missing",
            .moving => "Moving",
            .metaDL => "Fetching",
            .unknown => "Unknown",
        };
    }

    pub fn symbol(self: TorrentState) []const u8 {
        return switch (self) {
            .downloading, .metaDL => "v",
            .uploading, .stalledUP => "^",
            .pausedDL, .pausedUP => "||",
            .stalledDL => "..",
            .checking => "?",
            .queuedDL, .queuedUP => "Q",
            .error_state, .missingFiles => "!",
            .moving => ">",
            .unknown => "-",
        };
    }
};

/// Summary of a single torrent, parsed from /api/v2/torrents/info.
pub const TorrentInfo = struct {
    name: []const u8 = "",
    hash: []const u8 = "",
    state: TorrentState = .unknown,
    state_str: []const u8 = "",
    size: i64 = 0,
    progress: f64 = 0,
    dlspeed: i64 = 0,
    upspeed: i64 = 0,
    num_seeds: i64 = 0,
    num_leechs: i64 = 0,
    eta: i64 = 0,
    ratio: f64 = 0,
    downloaded: i64 = 0,
    uploaded: i64 = 0,
    save_path: []const u8 = "",
    tracker: []const u8 = "",
    category: []const u8 = "",
    tags: []const u8 = "",
    added_on: i64 = 0,
};

/// Global transfer statistics from /api/v2/transfer/info.
pub const TransferInfo = struct {
    dl_info_speed: i64 = 0,
    up_info_speed: i64 = 0,
    dl_info_data: i64 = 0,
    up_info_data: i64 = 0,
    dht_nodes: i64 = 0,
};

/// Torrent properties from /api/v2/torrents/properties.
pub const TorrentProperties = struct {
    save_path: []const u8 = "",
    total_size: i64 = 0,
    pieces_num: i64 = 0,
    piece_size: i64 = 0,
    nb_connections: i64 = 0,
    seeds_total: i64 = 0,
    peers_total: i64 = 0,
    addition_date: i64 = 0,
    comment: []const u8 = "",
};

/// Tracker entry from /api/v2/torrents/trackers.
pub const TrackerEntry = struct {
    url: []const u8 = "",
    status: i64 = 0,
    msg: []const u8 = "",
    num_seeds: i64 = 0,
    num_leeches: i64 = 0,
    num_peers: i64 = 0,
};

/// File entry from /api/v2/torrents/files.
pub const FileEntry = struct {
    name: []const u8 = "",
    size: i64 = 0,
    progress: f64 = 0,
    priority: i64 = 1,
    index: i64 = 0,
};

/// Daemon preferences from /api/v2/app/preferences.
pub const Preferences = struct {
    listen_port: i64 = 0,
    dl_limit: i64 = 0,
    up_limit: i64 = 0,
    max_connec: i64 = 0,
    max_connec_per_torrent: i64 = 0,
    max_uploads: i64 = 0,
    max_uploads_per_torrent: i64 = 0,
    dht: bool = false,
    pex: bool = false,
    enable_utp: bool = false,
    save_path: []const u8 = "",
    web_ui_port: i64 = 0,
};

pub const ApiError = error{
    ConnectionRefused,
    HttpError,
    ParseError,
    Timeout,
    OutOfMemory,
    Unexpected,
    AuthRequired,
    Forbidden,
};

/// All data fetched from a single poll cycle.
pub const PollResult = struct {
    torrents: ?[]TorrentInfo = null,
    transfer: ?TransferInfo = null,
    properties: ?TorrentProperties = null,
    trackers: ?[]TrackerEntry = null,
    files: ?[]FileEntry = null,
    preferences: ?Preferences = null,
    connected: bool = false,
    auth_required: bool = false,
    error_msg: ?[]const u8 = null,
};

/// Client for the varuna daemon API.
pub const ApiClient = struct {
    allocator: Allocator,
    base_url: []const u8,
    sid_cookie: ?[]const u8,

    pub fn init(allocator: Allocator, base_url: []const u8) ApiClient {
        return .{
            .allocator = allocator,
            .base_url = base_url,
            .sid_cookie = null,
        };
    }

    pub fn deinit(self: *ApiClient) void {
        if (self.sid_cookie) |sid| {
            self.allocator.free(sid);
        }
    }

    // ── Auth ──────────────────────────────────────────────

    /// Authenticate with the daemon. Returns true on success.
    /// Note: SID cookie extraction requires the lower-level Request API.
    /// For now we use fetch() and check the response body for "Ok.".
    pub fn login(self: *ApiClient, username: []const u8, password: []const u8) ApiError!bool {
        var body_buf: [512]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "username={s}&password={s}", .{ username, password }) catch
            return ApiError.Unexpected;

        const allocator = self.allocator;
        const url = std.fmt.allocPrint(allocator, "{s}/api/v2/auth/login", .{self.base_url}) catch
            return ApiError.OutOfMemory;
        defer allocator.free(url);

        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        var body_writer = std.Io.Writer.Allocating.init(allocator);
        defer body_writer.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .response_writer = &body_writer.writer,
        }) catch return ApiError.ConnectionRefused;

        if (result.status == .ok) {
            const buf = body_writer.writer.buffer;
            const end = body_writer.writer.end;
            if (end >= 3) {
                if (std.mem.eql(u8, buf[0..3], "Ok.")) {
                    return true;
                }
            }
        }

        return false;
    }

    // ── Fetch endpoints ──────────────────────────────────

    /// Fetch the list of all torrents.
    pub fn fetchTorrents(self: *ApiClient, allocator: Allocator) ApiError![]TorrentInfo {
        const body = self.httpGet(allocator, "/api/v2/torrents/info") catch |err| {
            return mapFetchError(err);
        };
        defer allocator.free(body);

        return parseTorrentList(allocator, body) catch return ApiError.ParseError;
    }

    /// Fetch global transfer stats.
    pub fn fetchTransferInfo(self: *ApiClient, allocator: Allocator) ApiError!TransferInfo {
        const body = self.httpGet(allocator, "/api/v2/transfer/info") catch |err| {
            return mapFetchError(err);
        };
        defer allocator.free(body);

        return parseTransferInfo(allocator, body) catch return ApiError.ParseError;
    }

    /// Fetch torrent properties.
    pub fn fetchProperties(self: *ApiClient, allocator: Allocator, hash: []const u8) ApiError!TorrentProperties {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v2/torrents/properties?hash={s}", .{hash}) catch
            return ApiError.Unexpected;

        const body = self.httpGet(allocator, path) catch |err| {
            return mapFetchError(err);
        };
        defer allocator.free(body);

        return parseProperties(allocator, body) catch return ApiError.ParseError;
    }

    /// Fetch trackers for a torrent.
    pub fn fetchTrackers(self: *ApiClient, allocator: Allocator, hash: []const u8) ApiError![]TrackerEntry {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v2/torrents/trackers?hash={s}", .{hash}) catch
            return ApiError.Unexpected;

        const body = self.httpGet(allocator, path) catch |err| {
            return mapFetchError(err);
        };
        defer allocator.free(body);

        return parseTrackerList(allocator, body) catch return ApiError.ParseError;
    }

    /// Fetch files for a torrent.
    pub fn fetchFiles(self: *ApiClient, allocator: Allocator, hash: []const u8) ApiError![]FileEntry {
        var path_buf: [256]u8 = undefined;
        const path = std.fmt.bufPrint(&path_buf, "/api/v2/torrents/files?hash={s}", .{hash}) catch
            return ApiError.Unexpected;

        const body = self.httpGet(allocator, path) catch |err| {
            return mapFetchError(err);
        };
        defer allocator.free(body);

        return parseFileList(allocator, body) catch return ApiError.ParseError;
    }

    /// Fetch preferences from the daemon.
    pub fn fetchPreferences(self: *ApiClient, allocator: Allocator) ApiError!Preferences {
        const body = self.httpGet(allocator, "/api/v2/app/preferences") catch |err| {
            return mapFetchError(err);
        };
        defer allocator.free(body);

        return parsePreferences(allocator, body) catch return ApiError.ParseError;
    }

    // ── Action endpoints ─────────────────────────────────

    /// Add a torrent by file path or magnet URI.
    pub fn addTorrent(self: *ApiClient, allocator: Allocator, path_or_magnet: []const u8) ApiError!void {
        var body_buf: [4096]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "urls={s}", .{path_or_magnet}) catch
            return ApiError.Unexpected;

        self.httpPost(allocator, "/api/v2/torrents/add", body) catch |err| {
            return mapFetchError(err);
        };
    }

    /// Remove a torrent.
    pub fn removeTorrent(self: *ApiClient, allocator: Allocator, hash: []const u8, delete_files: bool) ApiError!void {
        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "hashes={s}&deleteFiles={s}", .{
            hash,
            if (delete_files) "true" else "false",
        }) catch return ApiError.Unexpected;

        self.httpPost(allocator, "/api/v2/torrents/delete", body) catch |err| {
            return mapFetchError(err);
        };
    }

    /// Pause a torrent.
    pub fn pauseTorrent(self: *ApiClient, allocator: Allocator, hash: []const u8) ApiError!void {
        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "hashes={s}", .{hash}) catch return ApiError.Unexpected;

        self.httpPost(allocator, "/api/v2/torrents/pause", body) catch |err| {
            return mapFetchError(err);
        };
    }

    /// Resume a torrent.
    pub fn resumeTorrent(self: *ApiClient, allocator: Allocator, hash: []const u8) ApiError!void {
        var body_buf: [256]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "hashes={s}", .{hash}) catch return ApiError.Unexpected;

        self.httpPost(allocator, "/api/v2/torrents/resume", body) catch |err| {
            return mapFetchError(err);
        };
    }

    /// Set daemon preferences.
    pub fn setPreferences(self: *ApiClient, allocator: Allocator, json_data: []const u8) ApiError!void {
        var body_buf: [4096]u8 = undefined;
        const body = std.fmt.bufPrint(&body_buf, "json={s}", .{json_data}) catch
            return ApiError.Unexpected;

        self.httpPost(allocator, "/api/v2/app/setPreferences", body) catch |err| {
            return mapFetchError(err);
        };
    }

    // ── Internal HTTP helpers ────────────────────────────

    fn httpGet(self: *ApiClient, allocator: Allocator, path: []const u8) ![]const u8 {
        const url = std.fmt.allocPrint(allocator, "{s}{s}", .{ self.base_url, path }) catch
            return error.OutOfMemory;
        defer allocator.free(url);

        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        // Build extra headers for SID cookie
        var cookie_buf: [256]u8 = undefined;
        const cookie_header = if (self.sid_cookie) |sid|
            std.fmt.bufPrint(&cookie_buf, "SID={s}", .{sid}) catch null
        else
            null;

        var extra_headers: [1]std.http.Header = undefined;
        const n_extra: usize = if (cookie_header != null) 1 else 0;
        if (cookie_header) |ch| {
            extra_headers[0] = .{ .name = "Cookie", .value = ch };
        }

        var body_writer = std.Io.Writer.Allocating.init(allocator);
        errdefer body_writer.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .GET,
            .extra_headers = extra_headers[0..n_extra],
            .response_writer = &body_writer.writer,
        }) catch return error.ConnectionRefused;

        if (result.status == .unauthorized or result.status == .forbidden) {
            body_writer.deinit();
            return error.AuthRequired;
        }
        if (result.status != .ok) {
            body_writer.deinit();
            return error.HttpError;
        }

        const buf = body_writer.writer.buffer;
        const end = body_writer.writer.end;
        if (end == 0) return try allocator.dupe(u8, "");
        const owned = try allocator.dupe(u8, buf[0..end]);
        body_writer.deinit();
        return owned;
    }

    fn httpPost(self: *ApiClient, allocator: Allocator, path: []const u8, body: []const u8) !void {
        const url = std.fmt.allocPrint(allocator, "{s}{s}", .{ self.base_url, path }) catch
            return error.OutOfMemory;
        defer allocator.free(url);

        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        var cookie_buf: [256]u8 = undefined;
        const cookie_header = if (self.sid_cookie) |sid|
            std.fmt.bufPrint(&cookie_buf, "SID={s}", .{sid}) catch null
        else
            null;

        var extra_headers: [1]std.http.Header = undefined;
        const n_extra: usize = if (cookie_header != null) 1 else 0;
        if (cookie_header) |ch| {
            extra_headers[0] = .{ .name = "Cookie", .value = ch };
        }

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
            .extra_headers = extra_headers[0..n_extra],
        }) catch return error.ConnectionRefused;

        if (result.status == .unauthorized or result.status == .forbidden) {
            return error.AuthRequired;
        }
        if (result.status != .ok and result.status != .no_content) {
            return error.HttpError;
        }
    }

    fn mapFetchError(err: anyerror) ApiError {
        return switch (err) {
            error.ConnectionRefused => ApiError.ConnectionRefused,
            error.OutOfMemory => ApiError.OutOfMemory,
            error.AuthRequired => ApiError.AuthRequired,
            else => ApiError.HttpError,
        };
    }
};

// ── JSON parsing with std.json ──────────────────────────────────

/// JSON shape for a single torrent from /api/v2/torrents/info
const JsonTorrent = struct {
    name: []const u8 = "",
    hash: []const u8 = "",
    state: []const u8 = "unknown",
    size: i64 = 0,
    progress: f64 = 0,
    dlspeed: i64 = 0,
    upspeed: i64 = 0,
    num_seeds: i64 = 0,
    num_leechs: i64 = 0,
    eta: i64 = 0,
    ratio: f64 = 0,
    downloaded: i64 = 0,
    uploaded: i64 = 0,
    save_path: []const u8 = "",
    tracker: []const u8 = "",
    category: []const u8 = "",
    tags: []const u8 = "",
    added_on: i64 = 0,
};

fn parseTorrentList(allocator: Allocator, body: []const u8) ![]TorrentInfo {
    if (body.len == 0) return allocator.alloc(TorrentInfo, 0);

    const parsed = std.json.parseFromSlice([]JsonTorrent, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.ParseError;
    defer parsed.deinit();

    var result = try allocator.alloc(TorrentInfo, parsed.value.len);
    for (parsed.value, 0..) |jt, i| {
        result[i] = .{
            .name = allocator.dupe(u8, jt.name) catch "",
            .hash = allocator.dupe(u8, jt.hash) catch "",
            .state = TorrentState.fromString(jt.state),
            .state_str = allocator.dupe(u8, jt.state) catch "",
            .size = jt.size,
            .progress = jt.progress,
            .dlspeed = jt.dlspeed,
            .upspeed = jt.upspeed,
            .num_seeds = jt.num_seeds,
            .num_leechs = jt.num_leechs,
            .eta = jt.eta,
            .ratio = jt.ratio,
            .downloaded = jt.downloaded,
            .uploaded = jt.uploaded,
            .save_path = allocator.dupe(u8, jt.save_path) catch "",
            .tracker = allocator.dupe(u8, jt.tracker) catch "",
            .category = allocator.dupe(u8, jt.category) catch "",
            .tags = allocator.dupe(u8, jt.tags) catch "",
            .added_on = jt.added_on,
        };
    }
    return result;
}

/// JSON shape for /api/v2/transfer/info
const JsonTransfer = struct {
    dl_info_speed: i64 = 0,
    up_info_speed: i64 = 0,
    dl_info_data: i64 = 0,
    up_info_data: i64 = 0,
    dht_nodes: i64 = 0,
};

fn parseTransferInfo(allocator: Allocator, body: []const u8) !TransferInfo {
    if (body.len == 0) return .{};

    const parsed = std.json.parseFromSlice(JsonTransfer, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.ParseError;
    defer parsed.deinit();

    return .{
        .dl_info_speed = parsed.value.dl_info_speed,
        .up_info_speed = parsed.value.up_info_speed,
        .dl_info_data = parsed.value.dl_info_data,
        .up_info_data = parsed.value.up_info_data,
        .dht_nodes = parsed.value.dht_nodes,
    };
}

/// JSON shape for /api/v2/torrents/properties
const JsonProperties = struct {
    save_path: []const u8 = "",
    total_size: i64 = 0,
    pieces_num: i64 = 0,
    piece_size: i64 = 0,
    nb_connections: i64 = 0,
    seeds_total: i64 = 0,
    peers_total: i64 = 0,
    addition_date: i64 = 0,
    comment: []const u8 = "",
};

fn parseProperties(allocator: Allocator, body: []const u8) !TorrentProperties {
    if (body.len == 0) return .{};

    const parsed = std.json.parseFromSlice(JsonProperties, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.ParseError;
    defer parsed.deinit();

    return .{
        .save_path = allocator.dupe(u8, parsed.value.save_path) catch "",
        .total_size = parsed.value.total_size,
        .pieces_num = parsed.value.pieces_num,
        .piece_size = parsed.value.piece_size,
        .nb_connections = parsed.value.nb_connections,
        .seeds_total = parsed.value.seeds_total,
        .peers_total = parsed.value.peers_total,
        .addition_date = parsed.value.addition_date,
        .comment = allocator.dupe(u8, parsed.value.comment) catch "",
    };
}

/// JSON shape for tracker entries
const JsonTracker = struct {
    url: []const u8 = "",
    status: i64 = 0,
    msg: []const u8 = "",
    num_seeds: i64 = 0,
    num_leeches: i64 = 0,
    num_peers: i64 = 0,
};

fn parseTrackerList(allocator: Allocator, body: []const u8) ![]TrackerEntry {
    if (body.len == 0) return allocator.alloc(TrackerEntry, 0);

    const parsed = std.json.parseFromSlice([]JsonTracker, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.ParseError;
    defer parsed.deinit();

    var result = try allocator.alloc(TrackerEntry, parsed.value.len);
    for (parsed.value, 0..) |jt, i| {
        result[i] = .{
            .url = allocator.dupe(u8, jt.url) catch "",
            .status = jt.status,
            .msg = allocator.dupe(u8, jt.msg) catch "",
            .num_seeds = jt.num_seeds,
            .num_leeches = jt.num_leeches,
            .num_peers = jt.num_peers,
        };
    }
    return result;
}

/// JSON shape for file entries
const JsonFile = struct {
    name: []const u8 = "",
    size: i64 = 0,
    progress: f64 = 0,
    priority: i64 = 1,
    index: i64 = 0,
};

fn parseFileList(allocator: Allocator, body: []const u8) ![]FileEntry {
    if (body.len == 0) return allocator.alloc(FileEntry, 0);

    const parsed = std.json.parseFromSlice([]JsonFile, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.ParseError;
    defer parsed.deinit();

    var result = try allocator.alloc(FileEntry, parsed.value.len);
    for (parsed.value, 0..) |jf, i| {
        result[i] = .{
            .name = allocator.dupe(u8, jf.name) catch "",
            .size = jf.size,
            .progress = jf.progress,
            .priority = jf.priority,
            .index = if (jf.index != 0) jf.index else @as(i64, @intCast(i)),
        };
    }
    return result;
}

/// JSON shape for preferences
const JsonPreferences = struct {
    listen_port: i64 = 0,
    dl_limit: i64 = 0,
    up_limit: i64 = 0,
    max_connec: i64 = 0,
    max_connec_per_torrent: i64 = 0,
    max_uploads: i64 = 0,
    max_uploads_per_torrent: i64 = 0,
    dht: bool = false,
    pex: bool = false,
    enable_utp: bool = false,
    save_path: []const u8 = "",
    web_ui_port: i64 = 0,
};

fn parsePreferences(allocator: Allocator, body: []const u8) !Preferences {
    if (body.len == 0) return .{};

    const parsed = std.json.parseFromSlice(JsonPreferences, allocator, body, .{
        .ignore_unknown_fields = true,
        .allocate = .alloc_always,
    }) catch return error.ParseError;
    defer parsed.deinit();

    return .{
        .listen_port = parsed.value.listen_port,
        .dl_limit = parsed.value.dl_limit,
        .up_limit = parsed.value.up_limit,
        .max_connec = parsed.value.max_connec,
        .max_connec_per_torrent = parsed.value.max_connec_per_torrent,
        .max_uploads = parsed.value.max_uploads,
        .max_uploads_per_torrent = parsed.value.max_uploads_per_torrent,
        .dht = parsed.value.dht,
        .pex = parsed.value.pex,
        .enable_utp = parsed.value.enable_utp,
        .save_path = allocator.dupe(u8, parsed.value.save_path) catch "",
        .web_ui_port = parsed.value.web_ui_port,
    };
}

// ── Format helpers ──────────────────────────────────────────────

/// Format bytes as human-readable size string.
pub fn formatSize(buf: []u8, bytes: i64) []const u8 {
    if (bytes < 0) return "0 B";
    const b: f64 = @floatFromInt(bytes);
    if (bytes < 1024) {
        return std.fmt.bufPrint(buf, "{d} B", .{bytes}) catch "?";
    } else if (bytes < 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1} KB", .{b / 1024.0}) catch "?";
    } else if (bytes < 1024 * 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1} MB", .{b / (1024.0 * 1024.0)}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.2} GB", .{b / (1024.0 * 1024.0 * 1024.0)}) catch "?";
    }
}

/// Format bytes/sec as human-readable speed string.
pub fn formatSpeed(buf: []u8, bytes_per_sec: i64) []const u8 {
    if (bytes_per_sec <= 0) return "0 B/s";
    const b: f64 = @floatFromInt(bytes_per_sec);
    if (bytes_per_sec < 1024) {
        return std.fmt.bufPrint(buf, "{d} B/s", .{bytes_per_sec}) catch "?";
    } else if (bytes_per_sec < 1024 * 1024) {
        return std.fmt.bufPrint(buf, "{d:.1} KB/s", .{b / 1024.0}) catch "?";
    } else {
        return std.fmt.bufPrint(buf, "{d:.1} MB/s", .{b / (1024.0 * 1024.0)}) catch "?";
    }
}

/// Format ETA seconds to human-readable string.
pub fn formatEta(buf: []u8, eta_secs: i64) []const u8 {
    if (eta_secs <= 0 or eta_secs >= 8640000) return "inf";
    const h = @divFloor(eta_secs, 3600);
    const m = @divFloor(@mod(eta_secs, 3600), 60);
    const s = @mod(eta_secs, 60);
    if (h > 0) {
        return std.fmt.bufPrint(buf, "{d}h{d:0>2}m", .{ h, m }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d}m{d:0>2}s", .{ m, s }) catch "?";
}

/// Format progress (0.0-1.0) as percentage string.
pub fn formatProgress(buf: []u8, progress: f64) []const u8 {
    const pct = progress * 100.0;
    if (pct >= 99.95) return "100%";
    return std.fmt.bufPrint(buf, "{d:.1}%", .{pct}) catch "?";
}

// ── Free helpers ────────────────────────────────────────────────

pub fn freeTorrents(allocator: Allocator, torrents: []TorrentInfo) void {
    for (torrents) |t| {
        if (t.name.len > 0) allocator.free(t.name);
        if (t.hash.len > 0) allocator.free(t.hash);
        if (t.state_str.len > 0) allocator.free(t.state_str);
        if (t.save_path.len > 0) allocator.free(t.save_path);
        if (t.tracker.len > 0) allocator.free(t.tracker);
        if (t.category.len > 0) allocator.free(t.category);
        if (t.tags.len > 0) allocator.free(t.tags);
    }
    allocator.free(torrents);
}

pub fn freeTrackers(allocator: Allocator, trackers: []TrackerEntry) void {
    for (trackers) |t| {
        if (t.url.len > 0) allocator.free(t.url);
        if (t.msg.len > 0) allocator.free(t.msg);
    }
    allocator.free(trackers);
}

pub fn freeFiles(allocator: Allocator, files: []FileEntry) void {
    for (files) |f| {
        if (f.name.len > 0) allocator.free(f.name);
    }
    allocator.free(files);
}

pub fn freeProperties(allocator: Allocator, props: TorrentProperties) void {
    if (props.save_path.len > 0) allocator.free(props.save_path);
    if (props.comment.len > 0) allocator.free(props.comment);
}

// ── Tests ───────────────────────────────────────────────────────

test "parseTorrentList parses valid JSON array" {
    const json =
        \\[{"name":"test.iso","hash":"abc123","state":"downloading","size":1024,"progress":0.5,
        \\"dlspeed":100,"upspeed":50,"num_seeds":3,"num_leechs":2,"eta":300,"ratio":0.1,
        \\"downloaded":512,"uploaded":51,"save_path":"/tmp","tracker":"http://t.co",
        \\"category":"linux","tags":"iso","added_on":1000}]
    ;
    const allocator = std.testing.allocator;
    const torrents = try parseTorrentList(allocator, json);
    defer freeTorrents(allocator, torrents);

    try std.testing.expectEqual(@as(usize, 1), torrents.len);
    try std.testing.expectEqualStrings("test.iso", torrents[0].name);
    try std.testing.expectEqualStrings("abc123", torrents[0].hash);
    try std.testing.expectEqual(TorrentState.downloading, torrents[0].state);
    try std.testing.expectEqual(@as(i64, 1024), torrents[0].size);
}

test "parseTorrentList handles empty JSON" {
    const allocator = std.testing.allocator;
    const torrents = try parseTorrentList(allocator, "[]");
    defer allocator.free(torrents);
    try std.testing.expectEqual(@as(usize, 0), torrents.len);
}

test "parseTransferInfo parses valid JSON" {
    const json =
        \\{"dl_info_speed":1024,"up_info_speed":512,"dl_info_data":10000,"up_info_data":5000,"dht_nodes":42}
    ;
    const allocator = std.testing.allocator;
    const info = try parseTransferInfo(allocator, json);
    try std.testing.expectEqual(@as(i64, 1024), info.dl_info_speed);
    try std.testing.expectEqual(@as(i64, 42), info.dht_nodes);
}

test "parsePreferences parses valid JSON" {
    const json =
        \\{"listen_port":6881,"dl_limit":0,"up_limit":0,"max_connec":500,
        \\"max_connec_per_torrent":100,"max_uploads":20,"max_uploads_per_torrent":4,
        \\"dht":true,"pex":true,"enable_utp":true,"save_path":"/downloads","web_ui_port":8080}
    ;
    const allocator = std.testing.allocator;
    const prefs = try parsePreferences(allocator, json);
    defer {
        if (prefs.save_path.len > 0) allocator.free(prefs.save_path);
    }
    try std.testing.expectEqual(@as(i64, 6881), prefs.listen_port);
    try std.testing.expect(prefs.dht);
    try std.testing.expectEqualStrings("/downloads", prefs.save_path);
}

test "formatSize formats various sizes" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B", formatSize(&buf, 0));
    try std.testing.expectEqualStrings("512 B", formatSize(&buf, 512));
    try std.testing.expectEqualStrings("1.0 KB", formatSize(&buf, 1024));
}

test "formatSpeed formats various speeds" {
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("0 B/s", formatSpeed(&buf, 0));
    try std.testing.expectEqualStrings("1.0 KB/s", formatSpeed(&buf, 1024));
}

test "TorrentState.fromString maps known states" {
    try std.testing.expectEqual(TorrentState.downloading, TorrentState.fromString("downloading"));
    try std.testing.expectEqual(TorrentState.checking, TorrentState.fromString("checkingDL"));
    try std.testing.expectEqual(TorrentState.unknown, TorrentState.fromString("garbage"));
}
