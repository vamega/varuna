const std = @import("std");
const server = @import("server.zig");
const SessionManager = @import("../daemon/session_manager.zig").SessionManager;
const TorrentSession = @import("../daemon/torrent_session.zig");

/// API handler that routes requests to the appropriate endpoint.
/// Holds a reference to the SessionManager for state access.
pub const ApiHandler = struct {
    session_manager: *SessionManager,

    pub fn handle(self: *const ApiHandler, allocator: std.mem.Allocator, request: server.Request) server.Response {
        if (std.mem.eql(u8, request.path, "/api/v2/app/webapiVersion")) {
            return .{ .body = "\"2.9.3\"" };
        }

        if (std.mem.eql(u8, request.path, "/api/v2/app/preferences")) {
            return .{ .body = "{}" };
        }

        if (std.mem.eql(u8, request.path, "/api/v2/transfer/info")) {
            return self.handleTransferInfo(allocator);
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

        const body = std.fmt.allocPrint(allocator, "{{\"dl_info_speed\":{},\"up_info_speed\":{},\"dl_info_data\":{},\"up_info_data\":{},\"active_torrents\":{}}}", .{ total_dl_speed, total_ul_speed, total_dl_data, total_ul_data, stats.len }) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .body = body, .owned_body = body };
    }

    fn handleTorrents(self: *const ApiHandler, allocator: std.mem.Allocator, method: []const u8, action: []const u8, body: []const u8) server.Response {
        if (std.mem.eql(u8, action, "info")) {
            return self.handleTorrentsInfo(allocator);
        }

        if (std.mem.startsWith(u8, action, "add") and std.mem.eql(u8, method, "POST")) {
            // Extract query string from action (e.g. "add?savepath=/foo")
            const query = if (std.mem.indexOf(u8, action, "?")) |q| action[q + 1 ..] else "";
            return self.handleTorrentsAdd(allocator, body, query);
        }

        if (std.mem.eql(u8, action, "delete") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsDelete(allocator, body);
        }

        if (std.mem.eql(u8, action, "pause") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsPause(allocator, body);
        }

        if (std.mem.eql(u8, action, "resume") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsResume(allocator, body);
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
};

fn serializeTorrentInfo(allocator: std.mem.Allocator, json: *std.ArrayList(u8), stat: TorrentSession.Stats) !void {
    try json.print(
        allocator,
        "{{\"name\":\"{s}\",\"hash\":\"{s}\",\"state\":\"{s}\",\"size\":{},\"progress\":{d:.4},\"dlspeed\":{},\"upspeed\":{},\"num_seeds\":0,\"num_leechs\":{},\"added_on\":{},\"save_path\":\"{s}\",\"pieces_have\":{},\"pieces_num\":{}}}",
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
