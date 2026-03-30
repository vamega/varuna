const std = @import("std");
const server = @import("server.zig");
const auth = @import("auth.zig");
const multipart = @import("multipart.zig");
const sync_mod = @import("sync.zig");
const json_mod = @import("json.zig");
const SessionManager = @import("../daemon/session_manager.zig").SessionManager;
const TorrentSession = @import("../daemon/torrent_session.zig");
const metainfo_mod = @import("../torrent/metainfo.zig");

/// API handler that routes requests to the appropriate endpoint.
/// Holds a reference to the SessionManager for state access.
pub const ApiHandler = struct {
    session_manager: *SessionManager,
    session_store: auth.SessionStore = .{},
    sync_state: sync_mod.SyncState,
    api_username: []const u8 = "admin",
    api_password: []const u8 = "adminadmin",

    pub fn handle(self: *ApiHandler, allocator: std.mem.Allocator, request: server.Request) server.Response {
        // Auth endpoints are always accessible
        if (std.mem.eql(u8, request.path, "/api/v2/auth/login") and std.mem.eql(u8, request.method, "POST")) {
            return self.handleLogin(allocator, request.body);
        }
        if (std.mem.eql(u8, request.path, "/api/v2/auth/logout")) {
            return self.handleLogout(request.cookie_sid);
        }

        // All other endpoints require a valid session
        const sid = request.cookie_sid orelse
            return .{ .status = 403, .body = "Forbidden" };
        if (!self.session_store.validateSession(sid)) {
            return .{ .status = 403, .body = "Forbidden" };
        }

        if (std.mem.eql(u8, request.path, "/api/v2/app/webapiVersion")) {
            return .{ .body = "\"2.9.3\"" };
        }

        if (std.mem.eql(u8, request.path, "/api/v2/app/preferences")) {
            return self.handlePreferences(allocator);
        }

        if (std.mem.eql(u8, request.path, "/api/v2/app/setPreferences") and std.mem.eql(u8, request.method, "POST")) {
            return self.handleSetPreferences(allocator, request.body);
        }

        if (std.mem.eql(u8, request.path, "/api/v2/transfer/info")) {
            return self.handleTransferInfo(allocator);
        }

        if (std.mem.eql(u8, request.path, "/api/v2/transfer/speedLimitsMode")) {
            return self.handleSpeedLimitsMode(allocator);
        }

        if (std.mem.startsWith(u8, request.path, "/api/v2/torrents/")) {
            const action = request.path["/api/v2/torrents/".len..];
            return self.handleTorrents(allocator, request.method, action, request.body, request.content_type);
        }

        if (std.mem.startsWith(u8, request.path, "/api/v2/sync/maindata")) {
            return self.handleSyncMaindata(allocator, request.path);
        }

        return .{ .status = 404, .body = "{\"error\":\"not found\"}" };
    }

    fn handleLogin(self: *ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const username = extractParam(body, "username") orelse
            return .{ .status = 400, .body = "missing username" };
        const password = extractParam(body, "password") orelse
            return .{ .status = 400, .body = "missing password" };

        if (!std.mem.eql(u8, username, self.api_username) or !std.mem.eql(u8, password, self.api_password)) {
            return .{ .body = "Fails.", .content_type = "text/plain" };
        }

        const sid = self.session_store.createSession();
        const cookie_header = std.fmt.allocPrint(allocator, "Set-Cookie: SID={s}; HttpOnly; path=/\r\n", .{sid}) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{
            .body = "Ok.",
            .content_type = "text/plain",
            .extra_headers = cookie_header,
            .owned_extra_headers = cookie_header,
        };
    }

    fn handleLogout(self: *ApiHandler, cookie_sid: ?[]const u8) server.Response {
        if (cookie_sid) |sid| {
            self.session_store.removeSession(sid);
        }
        return .{ .body = "Ok.", .content_type = "text/plain" };
    }

    fn handleTransferInfo(self: *const ApiHandler, allocator: std.mem.Allocator) server.Response {
        const stats = self.session_manager.getAllStats(allocator) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        defer allocator.free(stats);

        var total_dl_speed: u64 = 0;
        var total_ul_speed: u64 = 0;
        var total_dl_data: u64 = 0;
        var total_ul_data: u64 = 0;
        for (stats) |stat| {
            total_dl_speed += stat.download_speed;
            total_ul_speed += stat.upload_speed;
            total_dl_data += stat.bytes_downloaded;
            total_ul_data += stat.bytes_uploaded;
        }

        const el = self.session_manager.shared_event_loop;
        const dl_limit: u64 = if (el) |e| e.getGlobalDlLimit() else 0;
        const ul_limit: u64 = if (el) |e| e.getGlobalUlLimit() else 0;

        const body = std.fmt.allocPrint(allocator, "{{\"dl_info_speed\":{},\"up_info_speed\":{},\"dl_info_data\":{},\"up_info_data\":{},\"dl_rate_limit\":{},\"up_rate_limit\":{},\"active_torrents\":{}}}", .{ total_dl_speed, total_ul_speed, total_dl_data, total_ul_data, dl_limit, ul_limit, stats.len }) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .body = body, .owned_body = body };
    }

    fn handleTorrents(self: *const ApiHandler, allocator: std.mem.Allocator, method: []const u8, action: []const u8, body: []const u8, content_type: ?[]const u8) server.Response {
        // Split action from query string (e.g. "files?hash=abc" -> "files", "hash=abc")
        const query_sep = std.mem.indexOf(u8, action, "?");
        const action_name = if (query_sep) |q| action[0..q] else action;
        const query = if (query_sep) |q| action[q + 1 ..] else "";

        // For GET endpoints, parameters come from query string; for POST, from body.
        // Some GET endpoints use query params (hash=...), so merge them.
        // The `params` variable provides a unified source for parameter extraction.
        const params = if (body.len > 0) body else query;

        if (std.mem.eql(u8, action_name, "info")) {
            return self.handleTorrentsInfo(allocator);
        }

        if (std.mem.startsWith(u8, action_name, "add") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsAdd(allocator, body, query, content_type);
        }

        if (std.mem.eql(u8, action_name, "delete") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsDelete(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "pause") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsPause(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "resume") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsResume(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "setDownloadLimit") and std.mem.eql(u8, method, "POST")) {
            return self.handleSetTorrentDlLimit(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "setUploadLimit") and std.mem.eql(u8, method, "POST")) {
            return self.handleSetTorrentUlLimit(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "downloadLimit") and std.mem.eql(u8, method, "POST")) {
            return self.handleGetTorrentDlLimit(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "uploadLimit") and std.mem.eql(u8, method, "POST")) {
            return self.handleGetTorrentUlLimit(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "files")) {
            return self.handleTorrentsFiles(allocator, params);
        }

        if (std.mem.eql(u8, action_name, "trackers")) {
            return self.handleTorrentsTrackers(allocator, params);
        }

        if (std.mem.eql(u8, action_name, "properties")) {
            return self.handleTorrentsProperties(allocator, params);
        }

        if (std.mem.eql(u8, action_name, "filePrio") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsFilePrio(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "setSequentialDownload") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsSetSequentialDownload(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "forceReannounce") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsForceReannounce(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "recheck") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsRecheck(allocator, body);
        }

        // Category endpoints
        if (std.mem.eql(u8, action_name, "categories")) {
            return self.handleCategories(allocator);
        }

        if (std.mem.eql(u8, action_name, "createCategory") and std.mem.eql(u8, method, "POST")) {
            return self.handleCreateCategory(allocator, params);
        }

        if (std.mem.eql(u8, action_name, "removeCategories") and std.mem.eql(u8, method, "POST")) {
            return self.handleRemoveCategories(params);
        }

        if (std.mem.eql(u8, action_name, "editCategory") and std.mem.eql(u8, method, "POST")) {
            return self.handleEditCategory(allocator, params);
        }

        if (std.mem.eql(u8, action_name, "setCategory") and std.mem.eql(u8, method, "POST")) {
            return self.handleSetCategory(allocator, params);
        }

        // Tag endpoints
        if (std.mem.eql(u8, action_name, "tags")) {
            return self.handleTags(allocator);
        }

        if (std.mem.eql(u8, action_name, "createTags") and std.mem.eql(u8, method, "POST")) {
            return self.handleCreateTags(params);
        }

        if (std.mem.eql(u8, action_name, "deleteTags") and std.mem.eql(u8, method, "POST")) {
            return self.handleDeleteTags(params);
        }

        if (std.mem.eql(u8, action_name, "addTags") and std.mem.eql(u8, method, "POST")) {
            return self.handleAddTags(allocator, params);
        }

        if (std.mem.eql(u8, action_name, "removeTags") and std.mem.eql(u8, method, "POST")) {
            return self.handleRemoveTags(allocator, params);
        }

        return .{ .status = 404, .body = "{\"error\":\"unknown action\"}" };
    }

    fn handleTorrentsInfo(self: *const ApiHandler, allocator: std.mem.Allocator) server.Response {
        const stats = self.session_manager.getAllStats(allocator) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        defer allocator.free(stats);

        var json = std.ArrayList(u8).empty;
        defer json.deinit(allocator);

        json.append(allocator, '[') catch return .{ .status = 500, .body = "[]" };
        for (stats, 0..) |stat, i| {
            if (i > 0) json.append(allocator, ',') catch {};
            serializeTorrentInfo(allocator, &json, stat) catch {};
        }
        json.append(allocator, ']') catch {};

        const body = json.toOwnedSlice(allocator) catch return .{ .status = 500, .body = "[]" };
        return .{ .body = body, .owned_body = body };
    }

    fn handleTorrentsAdd(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8, query: []const u8, content_type: ?[]const u8) server.Response {
        var torrent_data: []const u8 = body;
        var save_path: []const u8 = extractParam(query, "savepath") orelse self.session_manager.default_save_path;
        var category_param: ?[]const u8 = extractParam(query, "category");

        // Parse multipart/form-data if that's the content type (qBittorrent/Flood WebUI)
        if (multipart.isMultipart(content_type)) {
            const parts = multipart.parse(allocator, content_type.?, body) catch {
                return .{ .status = 400, .body = "{\"error\":\"malformed multipart body\"}" };
            };
            defer multipart.freeParts(allocator, parts);

            // Extract torrent file data
            const torrent_part = multipart.findPart(parts, "torrents") orelse {
                return .{ .status = 400, .body = "{\"error\":\"no torrents part in multipart\"}" };
            };
            torrent_data = torrent_part.data;

            // Extract optional parameters from form fields
            if (multipart.findPart(parts, "savepath")) |sp| {
                if (sp.data.len > 0) save_path = sp.data;
            }
            if (multipart.findPart(parts, "category")) |cp| {
                if (cp.data.len > 0) category_param = cp.data;
            }
        } else {
            // Also check body for form-encoded category param
            if (category_param == null) {
                category_param = extractParam(body, "category");
            }
        }

        if (torrent_data.len == 0) {
            return .{ .status = 400, .body = "{\"error\":\"no torrent data\"}" };
        }

        const session = self.session_manager.addTorrent(torrent_data, save_path) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
            return .{ .status = 400, .body = msg, .owned_body = msg };
        };

        // Set category if provided (best-effort, don't fail the add)
        if (category_param) |cat| {
            if (cat.len > 0) {
                self.session_manager.setTorrentCategory(&session.info_hash_hex, cat) catch {};
            }
        }

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleTorrentsDelete(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        // Expect hash in body as form param: hashes=<hash>
        const hash = extractParam(body, "hashes") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };

        self.session_manager.removeTorrent(hash) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
            return .{ .status = 404, .body = msg, .owned_body = msg };
        };

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleTorrentsPause(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParam(body, "hashes") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };

        self.session_manager.pauseTorrent(hash) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
            return .{ .status = 404, .body = msg, .owned_body = msg };
        };

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleTorrentsResume(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParam(body, "hashes") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };

        self.session_manager.resumeTorrent(hash) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
            return .{ .status = 404, .body = msg, .owned_body = msg };
        };

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    // ── Speed limit handlers ─────────────────────────────

    fn handlePreferences(self: *const ApiHandler, allocator: std.mem.Allocator) server.Response {
        const el = self.session_manager.shared_event_loop;
        const dl_limit: u64 = if (el) |e| e.getGlobalDlLimit() else 0;
        const ul_limit: u64 = if (el) |e| e.getGlobalUlLimit() else 0;

        const body = std.fmt.allocPrint(allocator, "{{\"dl_limit\":{},\"up_limit\":{}}}", .{ dl_limit, ul_limit }) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .body = body, .owned_body = body };
    }

    fn handleSetPreferences(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        _ = allocator;
        const el = self.session_manager.shared_event_loop orelse
            return .{ .status = 500, .body = "{\"error\":\"no event loop\"}" };

        // Parse simple form params: dl_limit=N&up_limit=N
        if (extractParam(body, "dl_limit")) |dl_str| {
            if (std.fmt.parseInt(u64, dl_str, 10)) |dl| {
                el.setGlobalDlLimit(dl);
            } else |_| {}
        }
        if (extractParam(body, "up_limit")) |ul_str| {
            if (std.fmt.parseInt(u64, ul_str, 10)) |ul| {
                el.setGlobalUlLimit(ul);
            } else |_| {}
        }

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleSpeedLimitsMode(_: *const ApiHandler, _: std.mem.Allocator) server.Response {
        // qBittorrent uses 0 = normal, 1 = alternative limits active.
        // We always report 0 (no alternative mode).
        return .{ .body = "0" };
    }

    fn handleSetTorrentDlLimit(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParam(body, "hashes") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const limit_str = extractParam(body, "limit") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing limit\"}" };
        const limit = std.fmt.parseInt(u64, limit_str, 10) catch
            return .{ .status = 400, .body = "{\"error\":\"invalid limit\"}" };

        self.session_manager.setTorrentDlLimit(hash, limit) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
            return .{ .status = 404, .body = msg, .owned_body = msg };
        };
        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleSetTorrentUlLimit(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParam(body, "hashes") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const limit_str = extractParam(body, "limit") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing limit\"}" };
        const limit = std.fmt.parseInt(u64, limit_str, 10) catch
            return .{ .status = 400, .body = "{\"error\":\"invalid limit\"}" };

        self.session_manager.setTorrentUlLimit(hash, limit) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
            return .{ .status = 404, .body = msg, .owned_body = msg };
        };
        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleGetTorrentDlLimit(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParam(body, "hashes") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };

        const stats = self.session_manager.getStats(hash) catch
            return .{ .status = 404, .body = "{\"error\":\"torrent not found\"}" };

        const resp = std.fmt.allocPrint(allocator, "{}", .{stats.dl_limit}) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .body = resp, .owned_body = resp };
    }

    fn handleGetTorrentUlLimit(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParam(body, "hashes") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };

        const stats = self.session_manager.getStats(hash) catch
            return .{ .status = 404, .body = "{\"error\":\"torrent not found\"}" };

        const resp = std.fmt.allocPrint(allocator, "{}", .{stats.ul_limit}) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .body = resp, .owned_body = resp };
    }

    // ── New endpoints ────────────────────────────────────

    fn handleTorrentsFiles(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParam(body, "hash") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" };

        const files = self.session_manager.getSessionFiles(allocator, hash) catch |err| switch (err) {
            error.TorrentNotFound => return .{ .status = 404, .body = "{\"error\":\"torrent not found\"}" },
            error.TorrentNotReady => return .{ .status = 409, .body = "{\"error\":\"torrent metadata not ready\"}" },
            else => return .{ .status = 500, .body = "{\"error\":\"internal\"}" },
        };
        defer SessionManager.freeFileInfos(allocator, files);

        var json = std.ArrayList(u8).empty;
        defer json.deinit(allocator);

        json.append(allocator, '[') catch return .{ .status = 500, .body = "[]" };

        for (files, 0..) |file, i| {
            if (i > 0) json.append(allocator, ',') catch {};

            json.print(allocator, "{{\"name\":\"{f}\",\"size\":{},\"progress\":{d:.4},\"priority\":{}}}", .{
                json_mod.jsonSafe(file.name),
                file.size,
                file.progress,
                file.priority,
            }) catch {};
        }

        json.append(allocator, ']') catch {};
        const result = json.toOwnedSlice(allocator) catch return .{ .status = 500, .body = "[]" };
        return .{ .body = result, .owned_body = result };
    }

    fn handleTorrentsTrackers(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParam(body, "hash") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" };

        const trackers = self.session_manager.getSessionTrackers(allocator, hash) catch |err| switch (err) {
            error.TorrentNotFound => return .{ .status = 404, .body = "{\"error\":\"torrent not found\"}" },
            error.TorrentNotReady => return .{ .status = 409, .body = "{\"error\":\"torrent metadata not ready\"}" },
            else => return .{ .status = 500, .body = "{\"error\":\"internal\"}" },
        };
        defer SessionManager.freeTrackerInfos(allocator, trackers);

        var json = std.ArrayList(u8).empty;
        defer json.deinit(allocator);

        json.append(allocator, '[') catch return .{ .status = 500, .body = "[]" };

        for (trackers, 0..) |tracker, i| {
            if (i > 0) json.append(allocator, ',') catch {};
            json.print(allocator, "{{\"url\":\"{f}\",\"status\":{},\"tier\":{},\"num_peers\":{},\"num_seeds\":{},\"num_leeches\":{},\"num_downloaded\":{}}}", .{
                json_mod.jsonSafe(tracker.url),
                tracker.status,
                tracker.tier,
                tracker.num_peers,
                tracker.num_seeds,
                tracker.num_leeches,
                tracker.num_downloaded,
            }) catch {};
        }

        json.append(allocator, ']') catch {};
        const result = json.toOwnedSlice(allocator) catch return .{ .status = 500, .body = "[]" };
        return .{ .body = result, .owned_body = result };
    }

    fn handleTorrentsProperties(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParam(body, "hash") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" };

        const info = self.session_manager.getSessionProperties(allocator, hash) catch |err| switch (err) {
            error.TorrentNotFound => return .{ .status = 404, .body = "{\"error\":\"torrent not found\"}" },
            else => return .{ .status = 500, .body = "{\"error\":\"internal\"}" },
        };
        defer SessionManager.freePropertiesInfo(allocator, info);

        // Time active since added
        const now = std.time.timestamp();
        const time_active: i64 = now - info.added_on;
        const seeding_time: i64 = if (info.state == .seeding) time_active else 0;
        const esc = json_mod.jsonSafe;

        var json = std.ArrayList(u8).empty;
        defer json.deinit(allocator);

        json.print(allocator, "{{\"save_path\":\"{f}\",\"creation_date\":-1,\"piece_size\":{},\"comment\":\"{f}\",\"total_size\":{},\"pieces_have\":{},\"pieces_num\":{},\"dl_speed\":{},\"up_speed\":{},\"dl_limit\":{},\"up_limit\":{},\"eta\":{},\"ratio\":{d:.4},\"time_active\":{},\"seeding_time\":{},\"nb_connections\":{},\"addition_date\":{},\"total_downloaded\":{},\"total_uploaded\":{},\"seq_dl\":{},\"is_private\":{}}}", .{
            esc(info.save_path),
            info.piece_size,
            esc(info.comment),
            info.total_size,
            info.pieces_have,
            info.pieces_total,
            info.download_speed,
            info.upload_speed,
            info.dl_limit,
            info.ul_limit,
            info.eta,
            info.ratio,
            time_active,
            seeding_time,
            info.peers_connected,
            info.added_on,
            info.bytes_downloaded,
            info.bytes_uploaded,
            @as(u8, if (info.sequential_download) 1 else 0),
            @as(u8, if (info.is_private) 1 else 0),
        }) catch return .{ .status = 500, .body = "{\"error\":\"internal\"}" };

        const result = json.toOwnedSlice(allocator) catch return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .body = result, .owned_body = result };
    }

    fn handleTorrentsFilePrio(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParam(body, "hash") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" };
        const id_str = extractParam(body, "id") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing id\"}" };
        const prio_str = extractParam(body, "priority") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing priority\"}" };

        const priority = std.fmt.parseInt(u8, prio_str, 10) catch
            return .{ .status = 400, .body = "{\"error\":\"invalid priority\"}" };

        // Validate priority value
        if (priority != 0 and priority != 1 and priority != 6 and priority != 7) {
            return .{ .status = 400, .body = "{\"error\":\"priority must be 0, 1, 6, or 7\"}" };
        }

        // Parse comma-separated file indices
        var indices = std.ArrayList(u32).empty;
        defer indices.deinit(allocator);

        var iter = std.mem.splitScalar(u8, id_str, '|');
        while (iter.next()) |idx_str| {
            const idx = std.fmt.parseInt(u32, idx_str, 10) catch continue;
            indices.append(allocator, idx) catch continue;
        }

        if (indices.items.len == 0) {
            return .{ .status = 400, .body = "{\"error\":\"no valid file indices\"}" };
        }

        self.session_manager.setFilePriority(hash, indices.items, priority) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
            return .{ .status = 404, .body = msg, .owned_body = msg };
        };

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleTorrentsSetSequentialDownload(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParam(body, "hash") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" };
        const value_str = extractParam(body, "value") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing value\"}" };

        const enabled = std.mem.eql(u8, value_str, "true");

        self.session_manager.setSequentialDownload(hash, enabled) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
            return .{ .status = 404, .body = msg, .owned_body = msg };
        };

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleTorrentsForceReannounce(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParam(body, "hashes") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };

        self.session_manager.forceReannounce(hash) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
            return .{ .status = 404, .body = msg, .owned_body = msg };
        };

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleTorrentsRecheck(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParam(body, "hashes") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };

        self.session_manager.forceRecheck(hash) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
            return .{ .status = 404, .body = msg, .owned_body = msg };
        };

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    // ── Category endpoints ────────────────────────────────

    fn handleCategories(self: *const ApiHandler, allocator: std.mem.Allocator) server.Response {
        self.session_manager.mutex.lock();
        defer self.session_manager.mutex.unlock();

        const body = self.session_manager.category_store.serializeJson(allocator) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .body = body, .owned_body = body };
    }

    fn handleCreateCategory(self: *const ApiHandler, allocator: std.mem.Allocator, params: []const u8) server.Response {
        const name = extractParam(params, "category") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing category\"}" };
        const save_path = extractParam(params, "savePath") orelse "";

        self.session_manager.mutex.lock();
        defer self.session_manager.mutex.unlock();

        self.session_manager.category_store.create(name, save_path) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
            return .{ .status = 409, .body = msg, .owned_body = msg };
        };

        // Persist to DB
        if (self.session_manager.resume_db) |*db| db.saveCategory(name, save_path) catch {};

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleRemoveCategories(self: *const ApiHandler, params: []const u8) server.Response {
        const names = extractParam(params, "categories") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing categories\"}" };

        self.session_manager.mutex.lock();
        defer self.session_manager.mutex.unlock();

        // Categories are newline-separated per qBittorrent API
        var iter = std.mem.splitScalar(u8, names, '\n');
        while (iter.next()) |raw_name| {
            const name = std.mem.trim(u8, raw_name, " \r");
            if (name.len == 0) continue;
            self.session_manager.category_store.remove(name);

            // Persist removal to DB
            if (self.session_manager.resume_db) |*db| {
                db.removeCategory(name) catch {};
                db.clearCategoryFromTorrents(name) catch {};
            }

            // Clear category from any torrents that had it
            var sess_iter = self.session_manager.sessions.iterator();
            while (sess_iter.next()) |entry| {
                const session = entry.value_ptr.*;
                if (session.category) |cat| {
                    if (std.mem.eql(u8, cat, name)) {
                        self.session_manager.allocator.free(cat);
                        session.category = null;
                    }
                }
            }
        }

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleEditCategory(self: *const ApiHandler, allocator: std.mem.Allocator, params: []const u8) server.Response {
        const name = extractParam(params, "category") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing category\"}" };
        const save_path = extractParam(params, "savePath") orelse "";

        self.session_manager.mutex.lock();
        defer self.session_manager.mutex.unlock();

        self.session_manager.category_store.edit(name, save_path) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
            return .{ .status = 409, .body = msg, .owned_body = msg };
        };

        // Persist to DB (saveCategory upserts)
        if (self.session_manager.resume_db) |*db| db.saveCategory(name, save_path) catch {};

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleSetCategory(self: *const ApiHandler, allocator: std.mem.Allocator, params: []const u8) server.Response {
        const hash = extractParam(params, "hashes") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const category = extractParam(params, "category") orelse "";

        self.session_manager.setTorrentCategory(hash, category) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
            return .{ .status = 404, .body = msg, .owned_body = msg };
        };

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    // ── Tag endpoints ────────────────────────────────────

    fn handleTags(self: *const ApiHandler, allocator: std.mem.Allocator) server.Response {
        self.session_manager.mutex.lock();
        defer self.session_manager.mutex.unlock();

        const body = self.session_manager.tag_store.serializeJson(allocator) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .body = body, .owned_body = body };
    }

    fn handleCreateTags(self: *const ApiHandler, params: []const u8) server.Response {
        const tags_str = extractParam(params, "tags") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing tags\"}" };

        self.session_manager.mutex.lock();
        defer self.session_manager.mutex.unlock();

        var iter = std.mem.splitScalar(u8, tags_str, ',');
        while (iter.next()) |raw_tag| {
            const tag = std.mem.trim(u8, raw_tag, " ");
            if (tag.len == 0) continue;
            self.session_manager.tag_store.create(tag) catch continue;
            if (self.session_manager.resume_db) |*db| db.saveGlobalTag(tag) catch {};
        }

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleDeleteTags(self: *const ApiHandler, params: []const u8) server.Response {
        const tags_str = extractParam(params, "tags") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing tags\"}" };

        self.session_manager.mutex.lock();
        defer self.session_manager.mutex.unlock();

        var iter = std.mem.splitScalar(u8, tags_str, ',');
        while (iter.next()) |raw_tag| {
            const tag = std.mem.trim(u8, raw_tag, " ");
            if (tag.len == 0) continue;
            self.session_manager.tag_store.delete(tag);

            // Persist removal to DB
            if (self.session_manager.resume_db) |*db| {
                db.removeGlobalTag(tag) catch {};
                db.removeTagFromTorrents(tag) catch {};
            }

            // Also remove from all torrents that have this tag
            var sess_iter = self.session_manager.sessions.iterator();
            while (sess_iter.next()) |entry| {
                const session = entry.value_ptr.*;
                var i: usize = 0;
                while (i < session.tags.items.len) {
                    if (std.mem.eql(u8, session.tags.items[i], tag)) {
                        self.session_manager.allocator.free(session.tags.items[i]);
                        _ = session.tags.swapRemove(i);
                        session.rebuildTagsString();
                        break;
                    }
                    i += 1;
                }
            }
        }

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleAddTags(self: *const ApiHandler, allocator: std.mem.Allocator, params: []const u8) server.Response {
        const hash = extractParam(params, "hashes") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const tags_str = extractParam(params, "tags") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing tags\"}" };

        self.session_manager.addTorrentTags(hash, tags_str) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
            return .{ .status = 404, .body = msg, .owned_body = msg };
        };

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleRemoveTags(self: *const ApiHandler, allocator: std.mem.Allocator, params: []const u8) server.Response {
        const hash = extractParam(params, "hashes") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const tags_str = extractParam(params, "tags") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing tags\"}" };

        self.session_manager.removeTorrentTags(hash, tags_str) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
            return .{ .status = 404, .body = msg, .owned_body = msg };
        };

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleSyncMaindata(self: *ApiHandler, allocator: std.mem.Allocator, path: []const u8) server.Response {
        // Parse rid from query string: /api/v2/sync/maindata?rid=N
        var request_rid: u64 = 0;
        if (std.mem.indexOf(u8, path, "?")) |q| {
            const query = path[q + 1 ..];
            if (extractParam(query, "rid")) |rid_str| {
                request_rid = std.fmt.parseInt(u64, rid_str, 10) catch 0;
            }
        }

        const body = self.sync_state.computeDelta(
            self.session_manager,
            allocator,
            request_rid,
        ) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .body = body, .owned_body = body };
    }
};

fn serializeTorrentInfo(allocator: std.mem.Allocator, json: *std.ArrayList(u8), stat: TorrentSession.Stats) !void {
    const esc = json_mod.jsonSafe;
    try json.print(
        allocator,
        "{{\"name\":\"{f}\",\"hash\":\"{s}\",\"state\":\"{s}\",\"size\":{},\"progress\":{d:.4},\"dlspeed\":{},\"upspeed\":{},\"num_seeds\":{},\"num_leechs\":{},\"added_on\":{},\"save_path\":\"{f}\",\"pieces_have\":{},\"pieces_num\":{},\"dl_limit\":{},\"up_limit\":{},\"eta\":{},\"ratio\":{d:.4},\"seq_dl\":{},\"is_private\":{},\"category\":\"{f}\",\"tags\":\"{f}\"}}",
        .{
            esc(stat.name),
            stat.info_hash_hex,
            @tagName(stat.state),
            stat.total_size,
            stat.progress,
            stat.download_speed,
            stat.upload_speed,
            stat.scrape_complete,
            stat.peers_connected,
            stat.added_on,
            esc(stat.save_path),
            stat.pieces_have,
            stat.pieces_total,
            stat.dl_limit,
            stat.ul_limit,
            stat.eta,
            stat.ratio,
            @as(u8, if (stat.sequential_download) 1 else 0),
            @as(u8, if (stat.is_private) 1 else 0),
            esc(stat.category),
            esc(stat.tags),
        },
    );
}

fn extractParam(body: []const u8, key: []const u8) ?[]const u8 {
    // Simple form-encoded parameter extraction: key=value&key2=value2
    var iter = std.mem.splitScalar(u8, body, '&');
    while (iter.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            if (std.mem.eql(u8, pair[0..eq], key)) {
                return pair[eq + 1 ..];
            }
        }
    }
    return null;
}

test "extract form param" {
    try std.testing.expectEqualStrings("abc123", extractParam("hashes=abc123&deleteFiles=false", "hashes").?);
    try std.testing.expectEqualStrings("false", extractParam("hashes=abc123&deleteFiles=false", "deleteFiles").?);
    try std.testing.expect(extractParam("hashes=abc", "missing") == null);
}
