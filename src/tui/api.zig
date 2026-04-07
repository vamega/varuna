//! HTTP API client for communicating with the varuna daemon.
//!
//! Talks to the qBittorrent-compatible WebAPI over HTTP.  Uses standard
//! library networking for HTTP transport (this code runs on background
//! threads via zigzag's AsyncRunner, not on the main zio event loop).
//! Parsing is done with std.json.

const std = @import("std");

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
    host: []const u8,
    port: u16,
    sid: ?[]const u8,

    /// Persistent buffer for HTTP request/response work.
    buf: []u8,

    pub fn init(allocator: Allocator, host: []const u8, port: u16) !ApiClient {
        return .{
            .allocator = allocator,
            .host = host,
            .port = port,
            .sid = null,
            .buf = try allocator.alloc(u8, 64 * 1024),
        };
    }

    pub fn deinit(self: *ApiClient) void {
        if (self.sid) |s| self.allocator.free(s);
        self.allocator.free(self.buf);
    }

    /// Authenticate with the daemon. Returns true on success.
    pub fn login(self: *ApiClient, username: []const u8, password: []const u8) !bool {
        const body_str = try std.fmt.allocPrint(self.allocator, "username={s}&password={s}", .{ username, password });
        defer self.allocator.free(body_str);

        const response = try self.httpPost("/api/v2/auth/login", body_str, "application/x-www-form-urlencoded");
        defer self.allocator.free(response.body);

        if (response.status != 200) return false;

        // Extract SID from Set-Cookie header if present
        if (response.cookie) |cookie| {
            if (self.sid) |old| self.allocator.free(old);
            self.sid = try self.allocator.dupe(u8, cookie);
        }
        return true;
    }

    /// Fetch the list of all torrents.
    pub fn getTorrents(self: *ApiClient) ![]TorrentInfo {
        const response = try self.httpGet("/api/v2/torrents/info");
        defer self.allocator.free(response.body);

        if (response.status != 200) return &[_]TorrentInfo{};

        return self.parseTorrentList(response.body) catch &[_]TorrentInfo{};
    }

    /// Fetch global transfer statistics.
    pub fn getTransferInfo(self: *ApiClient) !TransferInfo {
        const response = try self.httpGet("/api/v2/transfer/info");
        defer self.allocator.free(response.body);

        if (response.status != 200) return .{};

        return self.parseTransferInfo(response.body) catch .{};
    }

    /// Fetch properties for a specific torrent.
    pub fn getTorrentProperties(self: *ApiClient, hash: []const u8) !TorrentProperties {
        const path = try std.fmt.allocPrint(self.allocator, "/api/v2/torrents/properties?hash={s}", .{hash});
        defer self.allocator.free(path);

        const response = try self.httpGet(path);
        defer self.allocator.free(response.body);

        if (response.status != 200) return .{};

        return self.parseTorrentProperties(response.body) catch .{};
    }

    /// Fetch files for a specific torrent.
    pub fn getTorrentFiles(self: *ApiClient, hash: []const u8) ![]TorrentFile {
        const path = try std.fmt.allocPrint(self.allocator, "/api/v2/torrents/files?hash={s}", .{hash});
        defer self.allocator.free(path);

        const response = try self.httpGet(path);
        defer self.allocator.free(response.body);

        if (response.status != 200) return &[_]TorrentFile{};

        return self.parseTorrentFiles(response.body) catch &[_]TorrentFile{};
    }

    /// Fetch trackers for a specific torrent.
    pub fn getTorrentTrackers(self: *ApiClient, hash: []const u8) ![]TrackerEntry {
        const path = try std.fmt.allocPrint(self.allocator, "/api/v2/torrents/trackers?hash={s}", .{hash});
        defer self.allocator.free(path);

        const response = try self.httpGet(path);
        defer self.allocator.free(response.body);

        if (response.status != 200) return &[_]TrackerEntry{};

        return self.parseTrackerList(response.body) catch &[_]TrackerEntry{};
    }

    /// Fetch daemon preferences.
    pub fn getPreferences(self: *ApiClient) !Preferences {
        const response = try self.httpGet("/api/v2/app/preferences");
        defer self.allocator.free(response.body);

        if (response.status != 200) return .{};

        return self.parsePreferences(response.body) catch .{};
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

        const response = try self.httpPost("/api/v2/torrents/add", body_str, content_type);
        defer self.allocator.free(response.body);

        return response.status == 200;
    }

    /// Add a torrent by magnet link.
    pub fn addTorrentMagnet(self: *ApiClient, magnet_uri: []const u8) !bool {
        const body_str = try std.fmt.allocPrint(self.allocator, "urls={s}", .{magnet_uri});
        defer self.allocator.free(body_str);

        const response = try self.httpPost("/api/v2/torrents/add", body_str, "application/x-www-form-urlencoded");
        defer self.allocator.free(response.body);

        return response.status == 200;
    }

    /// Delete a torrent.
    pub fn deleteTorrent(self: *ApiClient, hash: []const u8, delete_files: bool) !bool {
        const df_str: []const u8 = if (delete_files) "true" else "false";
        const body_str = try std.fmt.allocPrint(self.allocator, "hashes={s}&deleteFiles={s}", .{ hash, df_str });
        defer self.allocator.free(body_str);

        const response = try self.httpPost("/api/v2/torrents/delete", body_str, "application/x-www-form-urlencoded");
        defer self.allocator.free(response.body);

        return response.status == 200;
    }

    /// Pause a torrent.
    pub fn pauseTorrent(self: *ApiClient, hash: []const u8) !bool {
        const body_str = try std.fmt.allocPrint(self.allocator, "hashes={s}", .{hash});
        defer self.allocator.free(body_str);

        const response = try self.httpPost("/api/v2/torrents/pause", body_str, "application/x-www-form-urlencoded");
        defer self.allocator.free(response.body);

        return response.status == 200;
    }

    /// Resume a torrent.
    pub fn resumeTorrent(self: *ApiClient, hash: []const u8) !bool {
        const body_str = try std.fmt.allocPrint(self.allocator, "hashes={s}", .{hash});
        defer self.allocator.free(body_str);

        const response = try self.httpPost("/api/v2/torrents/resume", body_str, "application/x-www-form-urlencoded");
        defer self.allocator.free(response.body);

        return response.status == 200;
    }

    // ── HTTP transport (uses zio for non-blocking I/O) ───────────────

    const HttpResponse = struct {
        status: u16,
        body: []const u8,
        cookie: ?[]const u8,
    };

    fn httpGet(self: *ApiClient, path: []const u8) !HttpResponse {
        return self.httpRequest("GET", path, null, null);
    }

    fn httpPost(self: *ApiClient, path: []const u8, body: []const u8, content_type: []const u8) !HttpResponse {
        return self.httpRequest("POST", path, body, content_type);
    }

    fn httpRequest(self: *ApiClient, method: []const u8, path: []const u8, body: ?[]const u8, content_type: ?[]const u8) !HttpResponse {
        // Build the HTTP request
        var header_buf: [4096]u8 = undefined;
        var header_len: usize = 0;

        // Request line
        header_len += (try std.fmt.bufPrint(header_buf[header_len..], "{s} {s} HTTP/1.1\r\n", .{ method, path })).len;
        header_len += (try std.fmt.bufPrint(header_buf[header_len..], "Host: {s}:{d}\r\n", .{ self.host, self.port })).len;
        header_len += (try std.fmt.bufPrint(header_buf[header_len..], "Connection: close\r\n", .{})).len;

        if (self.sid) |s| {
            header_len += (try std.fmt.bufPrint(header_buf[header_len..], "Cookie: SID={s}\r\n", .{s})).len;
        }

        if (content_type) |ct| {
            header_len += (try std.fmt.bufPrint(header_buf[header_len..], "Content-Type: {s}\r\n", .{ct})).len;
        }

        if (body) |b| {
            header_len += (try std.fmt.bufPrint(header_buf[header_len..], "Content-Length: {d}\r\n", .{b.len})).len;
        }

        header_len += (try std.fmt.bufPrint(header_buf[header_len..], "\r\n", .{})).len;

        // Connect via standard library TCP
        const addr = try std.net.Address.parseIp4(self.host, self.port);
        const stream = try std.net.tcpConnectToAddress(addr);
        defer stream.close();

        // Send request headers
        _ = try stream.write(header_buf[0..header_len]);
        if (body) |b| {
            _ = try stream.write(b);
        }

        // Read response into a growable buffer
        var response_buf: std.ArrayList(u8) = .empty;
        defer response_buf.deinit(self.allocator);

        var read_buf: [8192]u8 = undefined;
        while (true) {
            const n = stream.read(&read_buf) catch break;
            if (n == 0) break;
            try response_buf.appendSlice(self.allocator, read_buf[0..n]);
        }

        const raw = try response_buf.toOwnedSlice(self.allocator);

        // Parse HTTP response
        return self.parseHttpResponse(raw);
    }

    fn parseHttpResponse(self: *ApiClient, raw: []const u8) !HttpResponse {
        // Find the header/body separator
        const separator = "\r\n\r\n";
        const sep_pos = std.mem.indexOf(u8, raw, separator) orelse {
            return .{ .status = 0, .body = raw, .cookie = null };
        };

        const headers = raw[0..sep_pos];
        const body_start = sep_pos + separator.len;
        const body = try self.allocator.dupe(u8, raw[body_start..]);

        // Parse status code from first line: "HTTP/1.1 200 OK"
        var status: u16 = 0;
        if (std.mem.indexOf(u8, headers, " ")) |space_pos| {
            const after_space = headers[space_pos + 1 ..];
            if (std.mem.indexOf(u8, after_space, " ")) |second_space| {
                status = std.fmt.parseInt(u16, after_space[0..second_space], 10) catch 0;
            }
        }

        // Extract SID cookie
        var cookie: ?[]const u8 = null;
        var line_iter = std.mem.splitSequence(u8, headers, "\r\n");
        while (line_iter.next()) |line| {
            if (std.ascii.startsWithIgnoreCase(line, "set-cookie:")) {
                const val = std.mem.trimLeft(u8, line["set-cookie:".len..], " ");
                if (std.mem.indexOf(u8, val, "SID=")) |sid_start| {
                    const sid_val = val[sid_start + 4 ..];
                    const end = std.mem.indexOfAny(u8, sid_val, ";, ") orelse sid_val.len;
                    cookie = try self.allocator.dupe(u8, sid_val[0..end]);
                }
            }
        }

        self.allocator.free(raw);
        return .{ .status = status, .body = body, .cookie = cookie };
    }

    // ── JSON parsers ──────────────────────────────────────────────────

    fn parseTorrentList(self: *ApiClient, body: []const u8) ![]TorrentInfo {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();

        const arr = switch (parsed.value) {
            .array => |a| a,
            else => return &[_]TorrentInfo{},
        };

        var list = try self.allocator.alloc(TorrentInfo, arr.items.len);
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

    fn parseTransferInfo(self: *ApiClient, body: []const u8) !TransferInfo {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
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

    fn parseTorrentProperties(self: *ApiClient, body: []const u8) !TorrentProperties {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
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

    fn parseTorrentFiles(self: *ApiClient, body: []const u8) ![]TorrentFile {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();

        const arr = switch (parsed.value) {
            .array => |a| a,
            else => return &[_]TorrentFile{},
        };

        var list = try self.allocator.alloc(TorrentFile, arr.items.len);
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

    fn parseTrackerList(self: *ApiClient, body: []const u8) ![]TrackerEntry {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
        defer parsed.deinit();

        const arr = switch (parsed.value) {
            .array => |a| a,
            else => return &[_]TrackerEntry{},
        };

        var list = try self.allocator.alloc(TrackerEntry, arr.items.len);
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

    fn parsePreferences(self: *ApiClient, body: []const u8) !Preferences {
        const parsed = try std.json.parseFromSlice(std.json.Value, self.allocator, body, .{});
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
