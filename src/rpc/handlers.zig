const std = @import("std");
const server = @import("server.zig");
const SessionManager = @import("../daemon/session_manager.zig").SessionManager;
const TorrentSession = @import("../daemon/torrent_session.zig");
const metainfo_mod = @import("../torrent/metainfo.zig");

/// API handler that routes requests to the appropriate endpoint.
/// Holds a reference to the SessionManager for state access.
pub const ApiHandler = struct {
    session_manager: *SessionManager,

    pub fn handle(self: *const ApiHandler, allocator: std.mem.Allocator, request: server.Request) server.Response {
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
            return self.handleTorrents(allocator, request.method, action, request.body);
        }

        return .{ .status = 404, .body = "{\"error\":\"not found\"}" };
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

    fn handleTorrents(self: *const ApiHandler, allocator: std.mem.Allocator, method: []const u8, action: []const u8, body: []const u8) server.Response {
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
            return self.handleTorrentsAdd(allocator, body, query);
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

    fn handleTorrentsAdd(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8, query: []const u8) server.Response {
        // For now, expect raw torrent bytes in body
        // TODO: multipart form parsing for proper qBittorrent compatibility
        if (body.len == 0) {
            return .{ .status = 400, .body = "{\"error\":\"no torrent data\"}" };
        }

        const save_path = extractParam(query, "savepath") orelse self.session_manager.default_save_path;
        _ = self.session_manager.addTorrent(body, save_path) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
            return .{ .status = 400, .body = msg, .owned_body = msg };
        };

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

        const session = self.session_manager.getSession(hash) catch
            return .{ .status = 404, .body = "{\"error\":\"torrent not found\"}" };

        // Need parsed session for file metadata
        const sess = session.session orelse
            return .{ .status = 409, .body = "{\"error\":\"torrent metadata not ready\"}" };

        const meta = sess.metainfo;
        var json = std.ArrayList(u8).empty;
        defer json.deinit(allocator);

        json.append(allocator, '[') catch return .{ .status = 500, .body = "[]" };

        for (meta.files, 0..) |file, i| {
            if (i > 0) json.append(allocator, ',') catch {};

            // Compute per-file progress by checking which pieces overlap this file
            const layout_file = sess.layout.files[i];
            var file_progress: f64 = 0.0;
            if (session.piece_tracker) |*pt| {
                var pieces_complete: u32 = 0;
                var total_file_pieces: u32 = 0;
                var pidx: u32 = layout_file.first_piece;
                while (pidx < layout_file.end_piece_exclusive) : (pidx += 1) {
                    total_file_pieces += 1;
                    // Access the bitfield directly (thread-safe read of complete bits)
                    if (pt.complete.has(pidx)) {
                        pieces_complete += 1;
                    }
                }
                if (total_file_pieces > 0) {
                    file_progress = @as(f64, @floatFromInt(pieces_complete)) / @as(f64, @floatFromInt(total_file_pieces));
                }
            }

            // Build file name from path components
            var name_buf = std.ArrayList(u8).empty;
            defer name_buf.deinit(allocator);
            for (file.path, 0..) |component, ci| {
                if (ci > 0) name_buf.append(allocator, '/') catch {};
                name_buf.appendSlice(allocator, component) catch {};
            }

            // Get file priority (default 1=normal)
            const priority: u8 = if (session.file_priorities) |fp|
                if (i < fp.len) fp[i] else 1
            else
                1;

            json.print(allocator, "{{\"name\":\"{s}\",\"size\":{},\"progress\":{d:.4},\"priority\":{}}}", .{
                name_buf.items,
                file.length,
                file_progress,
                priority,
            }) catch {};
        }

        json.append(allocator, ']') catch {};
        const result = json.toOwnedSlice(allocator) catch return .{ .status = 500, .body = "[]" };
        return .{ .body = result, .owned_body = result };
    }

    fn handleTorrentsTrackers(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParam(body, "hash") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" };

        const session = self.session_manager.getSession(hash) catch
            return .{ .status = 404, .body = "{\"error\":\"torrent not found\"}" };

        const sess = session.session orelse
            return .{ .status = 409, .body = "{\"error\":\"torrent metadata not ready\"}" };

        const meta = sess.metainfo;

        var json = std.ArrayList(u8).empty;
        defer json.deinit(allocator);

        json.append(allocator, '[') catch return .{ .status = 500, .body = "[]" };

        var tier: u32 = 0;
        var first = true;

        // Primary announce URL
        if (meta.announce) |url| {
            if (!first) json.append(allocator, ',') catch {};
            first = false;
            // Status: 1 = contacted, 2 = working, 0 = disabled
            const status: u8 = if (session.state == .downloading or session.state == .seeding) 2 else 1;
            json.print(allocator, "{{\"url\":\"{s}\",\"status\":{},\"tier\":{},\"num_peers\":{}}}", .{
                url,
                status,
                tier,
                session.getStats().peers_connected,
            }) catch {};
            tier += 1;
        }

        // Announce list URLs
        for (meta.announce_list) |url| {
            // Skip if same as primary announce
            if (meta.announce) |primary| {
                if (std.mem.eql(u8, url, primary)) continue;
            }
            if (!first) json.append(allocator, ',') catch {};
            first = false;
            json.print(allocator, "{{\"url\":\"{s}\",\"status\":1,\"tier\":{},\"num_peers\":0}}", .{
                url,
                tier,
            }) catch {};
            tier += 1;
        }

        json.append(allocator, ']') catch {};
        const result = json.toOwnedSlice(allocator) catch return .{ .status = 500, .body = "[]" };
        return .{ .body = result, .owned_body = result };
    }

    fn handleTorrentsProperties(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParam(body, "hash") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" };

        const session = self.session_manager.getSession(hash) catch
            return .{ .status = 404, .body = "{\"error\":\"torrent not found\"}" };

        const stat = session.getStats();

        // Get optional metadata fields
        const comment: []const u8 = if (session.session) |*sess| (sess.metainfo.comment orelse "") else "";
        const piece_size: u32 = if (session.session) |*sess| sess.metainfo.piece_length else 0;

        // Time active since added
        const now = std.time.timestamp();
        const time_active: i64 = now - stat.added_on;
        const seeding_time: i64 = if (stat.state == .seeding) time_active else 0;

        var json = std.ArrayList(u8).empty;
        defer json.deinit(allocator);

        json.print(allocator, "{{\"save_path\":\"{s}\",\"creation_date\":-1,\"piece_size\":{},\"comment\":\"{s}\",\"total_size\":{},\"pieces_have\":{},\"pieces_num\":{},\"dl_speed\":{},\"up_speed\":{},\"dl_limit\":{},\"up_limit\":{},\"eta\":{},\"ratio\":{d:.4},\"time_active\":{},\"seeding_time\":{},\"nb_connections\":{},\"addition_date\":{},\"total_downloaded\":{},\"total_uploaded\":{},\"seq_dl\":{}}}", .{
            stat.save_path,
            piece_size,
            comment,
            stat.total_size,
            stat.pieces_have,
            stat.pieces_total,
            stat.download_speed,
            stat.upload_speed,
            stat.dl_limit,
            stat.ul_limit,
            stat.eta,
            stat.ratio,
            time_active,
            seeding_time,
            stat.peers_connected,
            stat.added_on,
            stat.bytes_downloaded,
            stat.bytes_uploaded,
            @as(u8, if (stat.sequential_download) 1 else 0),
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
};

fn serializeTorrentInfo(allocator: std.mem.Allocator, json: *std.ArrayList(u8), stat: TorrentSession.Stats) !void {
    try json.print(
        allocator,
        "{{\"name\":\"{s}\",\"hash\":\"{s}\",\"state\":\"{s}\",\"size\":{},\"progress\":{d:.4},\"dlspeed\":{},\"upspeed\":{},\"num_seeds\":0,\"num_leechs\":{},\"added_on\":{},\"save_path\":\"{s}\",\"pieces_have\":{},\"pieces_num\":{},\"dl_limit\":{},\"up_limit\":{},\"eta\":{},\"ratio\":{d:.4},\"seq_dl\":{}}}",
        .{
            stat.name,
            stat.info_hash_hex,
            @tagName(stat.state),
            stat.total_size,
            stat.progress,
            stat.download_speed,
            stat.upload_speed,
            stat.peers_connected,
            stat.added_on,
            stat.save_path,
            stat.pieces_have,
            stat.pieces_total,
            stat.dl_limit,
            stat.ul_limit,
            stat.eta,
            stat.ratio,
            @as(u8, if (stat.sequential_download) 1 else 0),
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
