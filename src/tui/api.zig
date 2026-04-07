/// HTTP client for communicating with the varuna daemon's qBittorrent-compatible WebAPI.
/// Uses std.http.Client since the TUI is not performance-critical (per AGENTS.md).
const std = @import("std");

const Allocator = std.mem.Allocator;

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
};

/// Summary of a single torrent, parsed from /api/v2/torrents/info.
pub const TorrentInfo = struct {
    name: []const u8,
    hash: []const u8,
    state: TorrentState,
    size: u64,
    progress: f64,
    dlspeed: u64,
    upspeed: u64,
    num_seeds: u64,
    num_leechs: u64,
    eta: i64,
    ratio: f64,
    save_path: []const u8,
    tracker: []const u8,
    category: []const u8,
    added_on: i64,
};

/// Global transfer statistics from /api/v2/transfer/info.
pub const TransferInfo = struct {
    dl_info_speed: u64 = 0,
    up_info_speed: u64 = 0,
    dl_info_data: u64 = 0,
    up_info_data: u64 = 0,
    dht_nodes: u64 = 0,
};

/// Tracker entry from /api/v2/torrents/trackers.
pub const TrackerEntry = struct {
    url: []const u8,
    status: []const u8,
    msg: []const u8,
};

/// Peer entry from /api/v2/sync/torrentPeers.
pub const PeerEntry = struct {
    ip: []const u8,
    client: []const u8,
    dl_speed: u64,
    up_speed: u64,
    progress: f64,
};

/// File entry from /api/v2/torrents/files.
pub const FileEntry = struct {
    name: []const u8,
    size: u64,
    progress: f64,
    priority: u8,
};

pub const ApiError = error{
    ConnectionRefused,
    HttpError,
    ParseError,
    Timeout,
    OutOfMemory,
    Unexpected,
};

/// Client for the varuna daemon API.
pub const ApiClient = struct {
    allocator: Allocator,
    base_url: []const u8,

    pub fn init(allocator: Allocator, base_url: []const u8) ApiClient {
        return .{
            .allocator = allocator,
            .base_url = base_url,
        };
    }

    pub fn deinit(self: *ApiClient) void {
        _ = self;
    }

    /// Fetch the list of all torrents.
    pub fn fetchTorrents(self: *ApiClient, allocator: Allocator) ApiError![]TorrentInfo {
        const body = self.httpGet(allocator, "/api/v2/torrents/info") catch |err| {
            return mapFetchError(err);
        };
        defer allocator.free(body);

        return parseTorrentsInfo(allocator, body) catch return ApiError.ParseError;
    }

    /// Fetch global transfer stats.
    pub fn fetchTransferInfo(self: *ApiClient, allocator: Allocator) ApiError!TransferInfo {
        const body = self.httpGet(allocator, "/api/v2/transfer/info") catch |err| {
            return mapFetchError(err);
        };
        defer allocator.free(body);

        return parseTransferInfo(body);
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

        return parseTrackers(allocator, body) catch return ApiError.ParseError;
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

        return parseFiles(allocator, body) catch return ApiError.ParseError;
    }

    /// Add a torrent by file path or magnet URI.
    pub fn addTorrent(self: *ApiClient, allocator: Allocator, path_or_magnet: []const u8) ApiError!void {
        var body_buf: [4096]u8 = undefined;

        const body = if (std.mem.startsWith(u8, path_or_magnet, "magnet:"))
            std.fmt.bufPrint(&body_buf, "urls={s}", .{path_or_magnet}) catch return ApiError.Unexpected
        else
            std.fmt.bufPrint(&body_buf, "urls={s}", .{path_or_magnet}) catch return ApiError.Unexpected;

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

    /// Fetch preferences from the daemon.
    pub fn fetchPreferences(self: *ApiClient, allocator: Allocator) ApiError![]const u8 {
        const body = self.httpGet(allocator, "/api/v2/app/preferences") catch |err| {
            return mapFetchError(err);
        };
        return body; // Caller owns the memory
    }

    // ── Internal HTTP helpers ─────────────────────────────

    fn httpGet(self: *ApiClient, allocator: Allocator, path: []const u8) ![]const u8 {
        const url = std.fmt.allocPrint(allocator, "{s}{s}", .{ self.base_url, path }) catch
            return error.OutOfMemory;
        defer allocator.free(url);

        var client: std.http.Client = .{ .allocator = allocator };
        defer client.deinit();

        var body_writer = std.Io.Writer.Allocating.init(allocator);
        errdefer body_writer.deinit();

        const result = client.fetch(.{
            .location = .{ .url = url },
            .response_writer = &body_writer.writer,
        }) catch return error.ConnectionRefused;

        if (result.status != .ok) return error.HttpError;

        const buf = body_writer.writer.buffer;
        const end = body_writer.writer.end;
        if (end == 0) return try allocator.dupe(u8, "");
        // Transfer ownership: return a dupe so the caller can free it
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

        const result = client.fetch(.{
            .location = .{ .url = url },
            .method = .POST,
            .payload = body,
        }) catch return error.ConnectionRefused;

        if (result.status != .ok and result.status != .no_content) return error.HttpError;
    }

    fn mapFetchError(err: anyerror) ApiError {
        return switch (err) {
            error.ConnectionRefused => ApiError.ConnectionRefused,
            error.OutOfMemory => ApiError.OutOfMemory,
            else => ApiError.HttpError,
        };
    }
};

// ── JSON parsing helpers ──────────────────────────────
// We use a lightweight hand-rolled parser since the TUI only needs
// a few fields from the daemon API responses. This avoids pulling
// in a full JSON library dependency.

fn parseTorrentsInfo(allocator: Allocator, body: []const u8) ![]TorrentInfo {
    var torrents: std.ArrayList(TorrentInfo) = .empty;
    errdefer {
        for (torrents.items) |t| {
            allocator.free(t.name);
            allocator.free(t.hash);
            allocator.free(t.save_path);
            allocator.free(t.tracker);
            allocator.free(t.category);
        }
        torrents.deinit(allocator);
    }

    // Walk through each JSON object in the array
    var pos: usize = 0;
    while (pos < body.len) {
        // Find next object start
        if (std.mem.indexOfScalarPos(u8, body, pos, '{')) |obj_start| {
            // Find matching end
            if (findMatchingBrace(body, obj_start)) |obj_end| {
                const obj = body[obj_start .. obj_end + 1];
                const info = TorrentInfo{
                    .name = try dupeJsonString(allocator, obj, "name"),
                    .hash = try dupeJsonString(allocator, obj, "hash"),
                    .state = TorrentState.fromString(extractJsonStringValue(obj, "state") orelse "unknown"),
                    .size = extractJsonUint(obj, "size") orelse 0,
                    .progress = extractJsonFloat(obj, "progress") orelse 0.0,
                    .dlspeed = extractJsonUint(obj, "dlspeed") orelse 0,
                    .upspeed = extractJsonUint(obj, "upspeed") orelse 0,
                    .num_seeds = extractJsonUint(obj, "num_seeds") orelse 0,
                    .num_leechs = extractJsonUint(obj, "num_leechs") orelse 0,
                    .eta = extractJsonInt(obj, "eta") orelse 0,
                    .ratio = extractJsonFloat(obj, "ratio") orelse 0.0,
                    .save_path = try dupeJsonString(allocator, obj, "save_path"),
                    .tracker = try dupeJsonString(allocator, obj, "tracker"),
                    .category = try dupeJsonString(allocator, obj, "category"),
                    .added_on = extractJsonInt(obj, "added_on") orelse 0,
                };
                try torrents.append(allocator, info);
                pos = obj_end + 1;
            } else {
                break;
            }
        } else {
            break;
        }
    }

    return torrents.toOwnedSlice(allocator);
}

fn parseTransferInfo(body: []const u8) TransferInfo {
    return .{
        .dl_info_speed = extractJsonUint(body, "dl_info_speed") orelse 0,
        .up_info_speed = extractJsonUint(body, "up_info_speed") orelse 0,
        .dl_info_data = extractJsonUint(body, "dl_info_data") orelse 0,
        .up_info_data = extractJsonUint(body, "up_info_data") orelse 0,
        .dht_nodes = extractJsonUint(body, "dht_nodes") orelse 0,
    };
}

fn parseTrackers(allocator: Allocator, body: []const u8) ![]TrackerEntry {
    var trackers: std.ArrayList(TrackerEntry) = .empty;
    errdefer {
        for (trackers.items) |t| {
            allocator.free(t.url);
            allocator.free(t.status);
            allocator.free(t.msg);
        }
        trackers.deinit(allocator);
    }

    var pos: usize = 0;
    while (pos < body.len) {
        if (std.mem.indexOfScalarPos(u8, body, pos, '{')) |obj_start| {
            if (findMatchingBrace(body, obj_start)) |obj_end| {
                const obj = body[obj_start .. obj_end + 1];
                try trackers.append(allocator, .{
                    .url = try dupeJsonString(allocator, obj, "url"),
                    .status = try dupeJsonString(allocator, obj, "status"),
                    .msg = try dupeJsonString(allocator, obj, "msg"),
                });
                pos = obj_end + 1;
            } else break;
        } else break;
    }

    return trackers.toOwnedSlice(allocator);
}

fn parseFiles(allocator: Allocator, body: []const u8) ![]FileEntry {
    var files: std.ArrayList(FileEntry) = .empty;
    errdefer {
        for (files.items) |f| allocator.free(f.name);
        files.deinit(allocator);
    }

    var pos: usize = 0;
    while (pos < body.len) {
        if (std.mem.indexOfScalarPos(u8, body, pos, '{')) |obj_start| {
            if (findMatchingBrace(body, obj_start)) |obj_end| {
                const obj = body[obj_start .. obj_end + 1];
                try files.append(allocator, .{
                    .name = try dupeJsonString(allocator, obj, "name"),
                    .size = extractJsonUint(obj, "size") orelse 0,
                    .progress = extractJsonFloat(obj, "progress") orelse 0.0,
                    .priority = @intCast(extractJsonUint(obj, "priority") orelse 1),
                });
                pos = obj_end + 1;
            } else break;
        } else break;
    }

    return files.toOwnedSlice(allocator);
}

fn findMatchingBrace(body: []const u8, start: usize) ?usize {
    var depth: usize = 0;
    var in_string = false;
    var i = start;
    while (i < body.len) : (i += 1) {
        if (in_string) {
            if (body[i] == '\\') {
                i += 1; // skip escaped char
                continue;
            }
            if (body[i] == '"') in_string = false;
            continue;
        }
        switch (body[i]) {
            '"' => in_string = true,
            '{' => depth += 1,
            '}' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

fn extractJsonStringValue(body: []const u8, key: []const u8) ?[]const u8 {
    // Look for "key":"value"
    var search_buf: [128]u8 = undefined;
    if (key.len + 4 > search_buf.len) return null;
    search_buf[0] = '"';
    @memcpy(search_buf[1..][0..key.len], key);
    search_buf[key.len + 1] = '"';
    search_buf[key.len + 2] = ':';
    search_buf[key.len + 3] = '"';
    const needle = search_buf[0 .. key.len + 4];

    const key_pos = std.mem.indexOf(u8, body, needle) orelse return null;
    const val_start = key_pos + needle.len;
    // Find closing quote (handle escaped quotes)
    var i = val_start;
    while (i < body.len) : (i += 1) {
        if (body[i] == '\\') {
            i += 1;
            continue;
        }
        if (body[i] == '"') {
            return body[val_start..i];
        }
    }
    return null;
}

fn dupeJsonString(allocator: Allocator, body: []const u8, key: []const u8) ![]const u8 {
    const val = extractJsonStringValue(body, key) orelse return try allocator.dupe(u8, "");
    return try allocator.dupe(u8, val);
}

fn extractJsonUint(body: []const u8, key: []const u8) ?u64 {
    var search_buf: [128]u8 = undefined;
    if (key.len + 3 > search_buf.len) return null;
    search_buf[0] = '"';
    @memcpy(search_buf[1..][0..key.len], key);
    search_buf[key.len + 1] = '"';
    search_buf[key.len + 2] = ':';
    const needle = search_buf[0 .. key.len + 3];

    const key_pos = std.mem.indexOf(u8, body, needle) orelse return null;
    var val_start = key_pos + needle.len;
    while (val_start < body.len and body[val_start] == ' ') val_start += 1;
    if (val_start >= body.len) return null;

    var val_end = val_start;
    while (val_end < body.len and body[val_end] >= '0' and body[val_end] <= '9') val_end += 1;
    if (val_end == val_start) return null;

    return std.fmt.parseInt(u64, body[val_start..val_end], 10) catch null;
}

fn extractJsonInt(body: []const u8, key: []const u8) ?i64 {
    var search_buf: [128]u8 = undefined;
    if (key.len + 3 > search_buf.len) return null;
    search_buf[0] = '"';
    @memcpy(search_buf[1..][0..key.len], key);
    search_buf[key.len + 1] = '"';
    search_buf[key.len + 2] = ':';
    const needle = search_buf[0 .. key.len + 3];

    const key_pos = std.mem.indexOf(u8, body, needle) orelse return null;
    var val_start = key_pos + needle.len;
    while (val_start < body.len and body[val_start] == ' ') val_start += 1;
    if (val_start >= body.len) return null;

    // Handle negative numbers
    var negative = false;
    if (body[val_start] == '-') {
        negative = true;
        val_start += 1;
    }

    var val_end = val_start;
    while (val_end < body.len and body[val_end] >= '0' and body[val_end] <= '9') val_end += 1;
    if (val_end == val_start) return null;

    const abs_val = std.fmt.parseInt(i64, body[val_start..val_end], 10) catch return null;
    return if (negative) -abs_val else abs_val;
}

fn extractJsonFloat(body: []const u8, key: []const u8) ?f64 {
    var search_buf: [128]u8 = undefined;
    if (key.len + 3 > search_buf.len) return null;
    search_buf[0] = '"';
    @memcpy(search_buf[1..][0..key.len], key);
    search_buf[key.len + 1] = '"';
    search_buf[key.len + 2] = ':';
    const needle = search_buf[0 .. key.len + 3];

    const key_pos = std.mem.indexOf(u8, body, needle) orelse return null;
    var val_start = key_pos + needle.len;
    while (val_start < body.len and body[val_start] == ' ') val_start += 1;
    if (val_start >= body.len) return null;

    var val_end = val_start;
    while (val_end < body.len and (body[val_end] == '.' or body[val_end] == '-' or
        (body[val_end] >= '0' and body[val_end] <= '9'))) val_end += 1;
    if (val_end == val_start) return null;

    return std.fmt.parseFloat(f64, body[val_start..val_end]) catch null;
}

/// Format bytes as human-readable size string.
pub fn formatSize(buf: []u8, bytes: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var value: f64 = @floatFromInt(bytes);
    var unit_idx: usize = 0;

    while (value >= 1024.0 and unit_idx < units.len - 1) {
        value /= 1024.0;
        unit_idx += 1;
    }

    if (unit_idx == 0) {
        return std.fmt.bufPrint(buf, "{d} {s}", .{ bytes, units[0] }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit_idx] }) catch "?";
}

/// Format bytes/sec as human-readable speed string.
pub fn formatSpeed(buf: []u8, bytes_per_sec: u64) []const u8 {
    if (bytes_per_sec == 0) return "0 B/s";

    const units = [_][]const u8{ "B/s", "KB/s", "MB/s", "GB/s" };
    var value: f64 = @floatFromInt(bytes_per_sec);
    var unit_idx: usize = 0;

    while (value >= 1024.0 and unit_idx < units.len - 1) {
        value /= 1024.0;
        unit_idx += 1;
    }

    if (unit_idx == 0) {
        return std.fmt.bufPrint(buf, "{d} {s}", .{ bytes_per_sec, units[0] }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ value, units[unit_idx] }) catch "?";
}

/// Format ETA seconds to human-readable string.
pub fn formatEta(buf: []u8, eta_secs: i64) []const u8 {
    if (eta_secs <= 0 or eta_secs >= 8640000) return "inf";

    const secs: u64 = @intCast(eta_secs);
    const hours = secs / 3600;
    const mins = (secs % 3600) / 60;
    const s = secs % 60;

    if (hours > 0) {
        return std.fmt.bufPrint(buf, "{d}h {d}m", .{ hours, mins }) catch "?";
    }
    if (mins > 0) {
        return std.fmt.bufPrint(buf, "{d}m {d}s", .{ mins, s }) catch "?";
    }
    return std.fmt.bufPrint(buf, "{d}s", .{s}) catch "?";
}

/// Format progress (0.0-1.0) as percentage string.
pub fn formatProgress(buf: []u8, progress: f64) []const u8 {
    const pct = progress * 100.0;
    if (pct >= 99.95) return "100%";
    return std.fmt.bufPrint(buf, "{d:.1}%", .{pct}) catch "?";
}
