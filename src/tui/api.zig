//! HTTP API client for communicating with the varuna daemon.
//!
//! Talks to the qBittorrent-compatible WebAPI over HTTP using dusty
//! (a zio-native HTTP client library).  All I/O runs inside zio
//! coroutines -- no blocking syscalls or extra threads.
//! JSON parsing uses std.json.

const std = @import("std");
const dusty = @import("dusty");

const Allocator = std.mem.Allocator;

// ── Data types mirroring the qBittorrent WebAPI JSON schema ──────────

pub const TorrentInfo = struct {
    hash: []const u8 = "",
    name: []const u8 = "",
    size: i64 = 0,
    progress: f64 = 0,
    dlspeed: i64 = 0,
    upspeed: i64 = 0,
    num_seeds: i64 = 0,
    num_leechs: i64 = 0,
    state: []const u8 = "",
    eta: i64 = 0,
    ratio: f64 = 0,
    added_on: i64 = 0,
    completed: i64 = 0,
    total_size: i64 = 0,
    downloaded: i64 = 0,
    uploaded: i64 = 0,
    save_path: []const u8 = "",
    category: []const u8 = "",
    tags: []const u8 = "",
    tracker: []const u8 = "",
    num_complete: i64 = 0,
    num_incomplete: i64 = 0,
    seq_dl: bool = false,
    super_seeding: bool = false,
    dl_limit: i64 = 0,
    up_limit: i64 = 0,
};

pub const TransferInfo = struct {
    dl_info_speed: i64 = 0,
    dl_info_data: i64 = 0,
    up_info_speed: i64 = 0,
    up_info_data: i64 = 0,
    dl_rate_limit: i64 = 0,
    up_rate_limit: i64 = 0,
    dht_nodes: i64 = 0,
    connection_status: []const u8 = "",
};

pub const TorrentProperties = struct {
    hash: []const u8 = "",
    name: []const u8 = "",
    save_path: []const u8 = "",
    total_size: i64 = 0,
    pieces_num: i64 = 0,
    piece_size: i64 = 0,
    creation_date: i64 = 0,
    comment: []const u8 = "",
    nb_connections: i64 = 0,
    seeds: i64 = 0,
    peers: i64 = 0,
    seeds_total: i64 = 0,
    peers_total: i64 = 0,
    dl_speed: i64 = 0,
    up_speed: i64 = 0,
    addition_date: i64 = 0,
    completion_date: i64 = 0,
};

pub const TorrentFile = struct {
    index: i64 = 0,
    name: []const u8 = "",
    size: i64 = 0,
    progress: f64 = 0,
    priority: i64 = 0,
    availability: f64 = 0,
};

pub const TrackerEntry = struct {
    url: []const u8 = "",
    status: i64 = 0,
    tier: i64 = 0,
    num_peers: i64 = 0,
    num_seeds: i64 = 0,
    num_leeches: i64 = 0,
    msg: []const u8 = "",
};

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
    save_path: []const u8 = "",
    enable_utp: bool = false,
    web_ui_port: i64 = 0,
};

// ── API Client ───────────────────────────────────────────────────────

pub const ApiClient = struct {
    allocator: Allocator,
    http: dusty.Client,
    base_url: []const u8,
    sid: ?[]const u8,

    pub fn init(allocator: Allocator, host: []const u8, port: u16) !ApiClient {
        const base_url = try std.fmt.allocPrint(allocator, "http://{s}:{d}", .{ host, port });
        return .{
            .allocator = allocator,
            .http = dusty.Client.init(allocator, .{}),
            .base_url = base_url,
            .sid = null,
        };
    }

    pub fn deinit(self: *ApiClient) void {
        self.http.deinit();
        if (self.sid) |s| self.allocator.free(s);
        self.allocator.free(self.base_url);
    }

    /// Authenticate with the daemon. Returns true on success.
    pub fn login(self: *ApiClient, username: []const u8, password: []const u8) !bool {
        const body_str = try std.fmt.allocPrint(self.allocator, "username={s}&password={s}", .{ username, password });
        defer self.allocator.free(body_str);

        const url = try std.fmt.allocPrint(self.allocator, "{s}/api/v2/auth/login", .{self.base_url});
        defer self.allocator.free(url);

        var headers: dusty.Headers = .{};
        defer headers.deinit(self.allocator);
        try headers.put(self.allocator, "Content-Type", "application/x-www-form-urlencoded");
        self.addCookieHeader(&headers);

        var response = self.http.fetch(url, .{
            .method = .post,
            .headers = &headers,
            .body = body_str,
        }) catch return false;
        defer response.deinit();

        const status = response.status();
        if (status != .ok) return false;

        // Extract SID from Set-Cookie header
        self.extractSidCookie(&response);
        return true;
    }

    /// Fetch the list of all torrents.
    pub fn getTorrents(self: *ApiClient, arena: Allocator) ![]TorrentInfo {
        const body = self.httpGet("/api/v2/torrents/info", arena) catch return &[_]TorrentInfo{};
        return parseTorrentList(arena, body) catch &[_]TorrentInfo{};
    }

    /// Fetch global transfer statistics.
    pub fn getTransferInfo(self: *ApiClient, arena: Allocator) !TransferInfo {
        const body = self.httpGet("/api/v2/transfer/info", arena) catch return .{};
        return parseTransferInfo(arena, body) catch .{};
    }

    /// Fetch properties for a specific torrent.
    pub fn getTorrentProperties(self: *ApiClient, arena: Allocator, hash: []const u8) !TorrentProperties {
        const path = try std.fmt.allocPrint(arena, "/api/v2/torrents/properties?hash={s}", .{hash});
        const body = self.httpGet(path, arena) catch return .{};
        return parseTorrentProperties(arena, body) catch .{};
    }

    /// Fetch files for a specific torrent.
    pub fn getTorrentFiles(self: *ApiClient, arena: Allocator, hash: []const u8) ![]TorrentFile {
        const path = try std.fmt.allocPrint(arena, "/api/v2/torrents/files?hash={s}", .{hash});
        const body = self.httpGet(path, arena) catch return &[_]TorrentFile{};
        return parseTorrentFiles(arena, body) catch &[_]TorrentFile{};
    }

    /// Fetch trackers for a specific torrent.
    pub fn getTorrentTrackers(self: *ApiClient, arena: Allocator, hash: []const u8) ![]TrackerEntry {
        const path = try std.fmt.allocPrint(arena, "/api/v2/torrents/trackers?hash={s}", .{hash});
        const body = self.httpGet(path, arena) catch return &[_]TrackerEntry{};
        return parseTrackerList(arena, body) catch &[_]TrackerEntry{};
    }

    /// Fetch daemon preferences.
    pub fn getPreferences(self: *ApiClient, arena: Allocator) !Preferences {
        const body = self.httpGet("/api/v2/app/preferences", arena) catch return .{};
        return parsePreferences(arena, body) catch .{};
    }

    /// Add a torrent by file path.
    pub fn addTorrentFile(self: *ApiClient, file_path: []const u8) !bool {
        // Read the torrent file
        const file_data = std.fs.cwd().readFileAlloc(self.allocator, file_path, 10 * 1024 * 1024) catch return false;
        defer self.allocator.free(file_data);

        const boundary = "----VarunaTUIBoundary";
        const body_str = try std.fmt.allocPrint(
            self.allocator,
            "--{s}\r\nContent-Disposition: form-data; name=\"torrents\"; filename=\"torrent.torrent\"\r\nContent-Type: application/x-bittorrent\r\n\r\n{s}\r\n--{s}--\r\n",
            .{ boundary, file_data, boundary },
        );
        defer self.allocator.free(body_str);

        const content_type = try std.fmt.allocPrint(self.allocator, "multipart/form-data; boundary={s}", .{boundary});
        defer self.allocator.free(content_type);

        return self.httpPostAction("/api/v2/torrents/add", body_str, content_type);
    }

    /// Add a torrent by magnet link.
    pub fn addTorrentMagnet(self: *ApiClient, magnet_uri: []const u8) !bool {
        const body_str = try std.fmt.allocPrint(self.allocator, "urls={s}", .{magnet_uri});
        defer self.allocator.free(body_str);
        return self.httpPostAction("/api/v2/torrents/add", body_str, "application/x-www-form-urlencoded");
    }

    /// Delete a torrent.
    pub fn deleteTorrent(self: *ApiClient, hash: []const u8, delete_files: bool) !bool {
        const df_str: []const u8 = if (delete_files) "true" else "false";
        const body_str = try std.fmt.allocPrint(self.allocator, "hashes={s}&deleteFiles={s}", .{ hash, df_str });
        defer self.allocator.free(body_str);
        return self.httpPostAction("/api/v2/torrents/delete", body_str, "application/x-www-form-urlencoded");
    }

    /// Pause a torrent.
    pub fn pauseTorrent(self: *ApiClient, hash: []const u8) !bool {
        const body_str = try std.fmt.allocPrint(self.allocator, "hashes={s}", .{hash});
        defer self.allocator.free(body_str);
        return self.httpPostAction("/api/v2/torrents/pause", body_str, "application/x-www-form-urlencoded");
    }

    /// Resume a torrent.
    pub fn resumeTorrent(self: *ApiClient, hash: []const u8) !bool {
        const body_str = try std.fmt.allocPrint(self.allocator, "hashes={s}", .{hash});
        defer self.allocator.free(body_str);
        return self.httpPostAction("/api/v2/torrents/resume", body_str, "application/x-www-form-urlencoded");
    }

    /// Set daemon preferences.
    pub fn setPreferences(self: *ApiClient, json_body: []const u8) !bool {
        const body_str = try std.fmt.allocPrint(self.allocator, "json={s}", .{json_body});
        defer self.allocator.free(body_str);
        return self.httpPostAction("/api/v2/app/setPreferences", body_str, "application/x-www-form-urlencoded");
    }

    // ── HTTP transport (uses dusty + zio) ────────────────────────────

    fn httpGet(self: *ApiClient, path: []const u8, arena: Allocator) ![]const u8 {
        const url = try std.fmt.allocPrint(arena, "{s}{s}", .{ self.base_url, path });

        var headers: dusty.Headers = .{};
        defer headers.deinit(self.allocator);
        self.addCookieHeader(&headers);

        var response = try self.http.fetch(url, .{
            .headers = &headers,
        });
        defer response.deinit();

        const status = response.status();

        // Handle auth required
        if (status == .forbidden or status == .unauthorized) {
            return error.AuthRequired;
        }

        if (status != .ok) return error.HttpError;

        const body = response.body() catch return error.HttpError;
        if (body) |b| {
            return try arena.dupe(u8, b);
        }
        return error.HttpError;
    }

    fn httpPostAction(self: *ApiClient, path: []const u8, body: []const u8, content_type: []const u8) bool {
        const url = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ self.base_url, path }) catch return false;
        defer self.allocator.free(url);

        var headers: dusty.Headers = .{};
        defer headers.deinit(self.allocator);
        headers.put(self.allocator, "Content-Type", content_type) catch return false;
        self.addCookieHeader(&headers);

        var response = self.http.fetch(url, .{
            .method = .post,
            .headers = &headers,
            .body = body,
        }) catch return false;
        defer response.deinit();

        const status = response.status();
        return status == .ok;
    }

    fn addCookieHeader(self: *const ApiClient, headers: *dusty.Headers) void {
        if (self.sid) |s| {
            const cookie = std.fmt.allocPrint(self.allocator, "SID={s}", .{s}) catch return;
            headers.put(self.allocator, "Cookie", cookie) catch {
                self.allocator.free(cookie);
            };
        }
    }

    fn extractSidCookie(self: *ApiClient, response: *dusty.ClientResponse) void {
        const resp_headers = response.headers();
        const cookie_val = resp_headers.get("Set-Cookie") orelse return;
        if (std.mem.indexOf(u8, cookie_val, "SID=")) |sid_start| {
            const sid_val = cookie_val[sid_start + 4 ..];
            const end = std.mem.indexOfAny(u8, sid_val, ";, ") orelse sid_val.len;
            const new_sid = self.allocator.dupe(u8, sid_val[0..end]) catch return;
            if (self.sid) |old| self.allocator.free(old);
            self.sid = new_sid;
        }
    }

    // ── JSON parsers ──────────────────────────────────────────────────

    fn parseTorrentList(arena: Allocator, body: []const u8) ![]TorrentInfo {
        const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
        defer parsed.deinit();

        const arr = switch (parsed.value) {
            .array => |a| a,
            else => return &[_]TorrentInfo{},
        };

        var list = try arena.alloc(TorrentInfo, arr.items.len);
        for (arr.items, 0..) |item, i| {
            list[i] = extractTorrentInfo(item);
        }
        return list;
    }

    fn extractTorrentInfo(val: std.json.Value) TorrentInfo {
        const obj = switch (val) {
            .object => |o| o,
            else => return .{},
        };
        return .{
            .hash = getStr(obj, "hash"),
            .name = getStr(obj, "name"),
            .size = getInt(obj, "size"),
            .progress = getFloat(obj, "progress"),
            .dlspeed = getInt(obj, "dlspeed"),
            .upspeed = getInt(obj, "upspeed"),
            .num_seeds = getInt(obj, "num_seeds"),
            .num_leechs = getInt(obj, "num_leechs"),
            .state = getStr(obj, "state"),
            .eta = getInt(obj, "eta"),
            .ratio = getFloat(obj, "ratio"),
            .added_on = getInt(obj, "added_on"),
            .completed = getInt(obj, "completed"),
            .total_size = getInt(obj, "total_size"),
            .downloaded = getInt(obj, "downloaded"),
            .uploaded = getInt(obj, "uploaded"),
            .save_path = getStr(obj, "save_path"),
            .category = getStr(obj, "category"),
            .tags = getStr(obj, "tags"),
            .tracker = getStr(obj, "tracker"),
            .num_complete = getInt(obj, "num_complete"),
            .num_incomplete = getInt(obj, "num_incomplete"),
            .seq_dl = getBool(obj, "seq_dl"),
            .super_seeding = getBool(obj, "super_seeding"),
            .dl_limit = getInt(obj, "dl_limit"),
            .up_limit = getInt(obj, "up_limit"),
        };
    }

    fn parseTransferInfo(arena: Allocator, body: []const u8) !TransferInfo {
        const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return .{},
        };
        return .{
            .dl_info_speed = getInt(obj, "dl_info_speed"),
            .dl_info_data = getInt(obj, "dl_info_data"),
            .up_info_speed = getInt(obj, "up_info_speed"),
            .up_info_data = getInt(obj, "up_info_data"),
            .dl_rate_limit = getInt(obj, "dl_rate_limit"),
            .up_rate_limit = getInt(obj, "up_rate_limit"),
            .dht_nodes = getInt(obj, "dht_nodes"),
            .connection_status = getStr(obj, "connection_status"),
        };
    }

    fn parseTorrentProperties(arena: Allocator, body: []const u8) !TorrentProperties {
        const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return .{},
        };
        return .{
            .save_path = getStr(obj, "save_path"),
            .total_size = getInt(obj, "total_size"),
            .pieces_num = getInt(obj, "pieces_num"),
            .piece_size = getInt(obj, "piece_size"),
            .creation_date = getInt(obj, "creation_date"),
            .comment = getStr(obj, "comment"),
            .nb_connections = getInt(obj, "nb_connections"),
            .seeds = getInt(obj, "seeds"),
            .peers = getInt(obj, "peers"),
            .seeds_total = getInt(obj, "seeds_total"),
            .peers_total = getInt(obj, "peers_total"),
            .dl_speed = getInt(obj, "dl_speed"),
            .up_speed = getInt(obj, "up_speed"),
            .addition_date = getInt(obj, "addition_date"),
            .completion_date = getInt(obj, "completion_date"),
        };
    }

    fn parseTorrentFiles(arena: Allocator, body: []const u8) ![]TorrentFile {
        const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
        defer parsed.deinit();

        const arr = switch (parsed.value) {
            .array => |a| a,
            else => return &[_]TorrentFile{},
        };

        var list = try arena.alloc(TorrentFile, arr.items.len);
        for (arr.items, 0..) |item, i| {
            const obj = switch (item) {
                .object => |o| o,
                else => {
                    list[i] = .{};
                    continue;
                },
            };
            list[i] = .{
                .index = getInt(obj, "index"),
                .name = getStr(obj, "name"),
                .size = getInt(obj, "size"),
                .progress = getFloat(obj, "progress"),
                .priority = getInt(obj, "priority"),
                .availability = getFloat(obj, "availability"),
            };
        }
        return list;
    }

    fn parseTrackerList(arena: Allocator, body: []const u8) ![]TrackerEntry {
        const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
        defer parsed.deinit();

        const arr = switch (parsed.value) {
            .array => |a| a,
            else => return &[_]TrackerEntry{},
        };

        var list = try arena.alloc(TrackerEntry, arr.items.len);
        for (arr.items, 0..) |item, i| {
            const obj = switch (item) {
                .object => |o| o,
                else => {
                    list[i] = .{};
                    continue;
                },
            };
            list[i] = .{
                .url = getStr(obj, "url"),
                .status = getInt(obj, "status"),
                .tier = getInt(obj, "tier"),
                .num_peers = getInt(obj, "num_peers"),
                .num_seeds = getInt(obj, "num_seeds"),
                .num_leeches = getInt(obj, "num_leeches"),
                .msg = getStr(obj, "msg"),
            };
        }
        return list;
    }

    fn parsePreferences(arena: Allocator, body: []const u8) !Preferences {
        const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
        defer parsed.deinit();

        const obj = switch (parsed.value) {
            .object => |o| o,
            else => return .{},
        };
        return .{
            .listen_port = getInt(obj, "listen_port"),
            .dl_limit = getInt(obj, "dl_limit"),
            .up_limit = getInt(obj, "up_limit"),
            .max_connec = getInt(obj, "max_connec"),
            .max_connec_per_torrent = getInt(obj, "max_connec_per_torrent"),
            .max_uploads = getInt(obj, "max_uploads"),
            .max_uploads_per_torrent = getInt(obj, "max_uploads_per_torrent"),
            .dht = getBool(obj, "dht"),
            .pex = getBool(obj, "pex"),
            .save_path = getStr(obj, "save_path"),
            .enable_utp = getBool(obj, "enable_utp"),
            .web_ui_port = getInt(obj, "web_ui_port"),
        };
    }

    // ── JSON helpers ──────────────────────────────────────────────────

    fn getStr(obj: std.json.ObjectMap, key: []const u8) []const u8 {
        if (obj.get(key)) |v| {
            switch (v) {
                .string => |s| return s,
                else => {},
            }
        }
        return "";
    }

    fn getInt(obj: std.json.ObjectMap, key: []const u8) i64 {
        if (obj.get(key)) |v| {
            switch (v) {
                .integer => |n| return n,
                .float => |f| return @intFromFloat(f),
                else => {},
            }
        }
        return 0;
    }

    fn getFloat(obj: std.json.ObjectMap, key: []const u8) f64 {
        if (obj.get(key)) |v| {
            switch (v) {
                .float => |f| return f,
                .integer => |n| return @floatFromInt(n),
                else => {},
            }
        }
        return 0;
    }

    fn getBool(obj: std.json.ObjectMap, key: []const u8) bool {
        if (obj.get(key)) |v| {
            switch (v) {
                .bool => |bv| return bv,
                else => {},
            }
        }
        return false;
    }
};
