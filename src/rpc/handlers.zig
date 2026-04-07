const std = @import("std");
const server = @import("server.zig");
const auth = @import("auth.zig");
const multipart = @import("multipart.zig");
const sync_mod = @import("sync.zig");
const json_mod = @import("json.zig");
const compat = @import("compat.zig");
const mse = @import("../crypto/mse.zig");
const SessionManager = @import("../daemon/session_manager.zig").SessionManager;
const TorrentSession = @import("../daemon/torrent_session.zig");
const metainfo_mod = @import("../torrent/metainfo.zig");
const BanList = @import("../net/ban_list.zig").BanList;
const ipfilter_parser = @import("../net/ipfilter_parser.zig");

/// API handler that routes requests to the appropriate endpoint.
/// Holds a reference to the SessionManager for state access.
pub const ApiHandler = struct {
    session_manager: *SessionManager,
    session_store: auth.SessionStore = .{},
    sync_state: sync_mod.SyncState,
    api_username: []const u8 = "admin",
    api_password: []const u8 = "adminadmin",

    /// Standard CORS headers attached to every API response.
    const cors_headers = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Cookie, Authorization\r\nAccess-Control-Allow-Credentials: true\r\n";

    /// Wrap a response with CORS headers.
    fn withCors(resp: server.Response) server.Response {
        var r = resp;
        r.extra_headers = if (r.extra_headers) |existing| blk: {
            // Caller already has extra headers (e.g. Set-Cookie from login).
            // We must not overwrite them -- the sendResponse path concatenates
            // extra_headers into the response verbatim, so we concatenate here.
            _ = existing;
            break :blk r.extra_headers;
        } else cors_headers;
        return r;
    }

    pub fn handle(self: *ApiHandler, allocator: std.mem.Allocator, request: server.Request) server.Response {
        // CORS preflight
        if (std.mem.eql(u8, request.method, "OPTIONS")) {
            return .{
                .status = 200,
                .content_type = "text/plain",
                .body = "",
                .extra_headers = cors_headers,
            };
        }

        // Auth endpoints are always accessible
        if (std.mem.eql(u8, request.path, "/api/v2/auth/login") and std.mem.eql(u8, request.method, "POST")) {
            return self.handleLogin(allocator, request.body);
        }
        if (std.mem.eql(u8, request.path, "/api/v2/auth/logout")) {
            return withCors(self.handleLogout(request.cookie_sid));
        }

        // All other endpoints require a valid session
        const sid = request.cookie_sid orelse
            return withCors(.{ .status = 403, .body = "Forbidden" });
        if (!self.session_store.validateSession(sid)) {
            return withCors(.{ .status = 403, .body = "Forbidden" });
        }

        if (std.mem.eql(u8, request.path, "/api/v2/app/webapiVersion")) {
            return withCors(.{ .body = "\"2.9.3\"", .content_type = "text/plain" });
        }

        if (std.mem.eql(u8, request.path, "/api/v2/app/version")) {
            return withCors(.{ .body = "v5.0.0", .content_type = "text/plain" });
        }

        if (std.mem.eql(u8, request.path, "/api/v2/app/buildInfo")) {
            return withCors(.{ .body = "{\"qt\":\"N/A\",\"libtorrent\":\"N/A\",\"boost\":\"N/A\",\"openssl\":\"N/A\",\"bitness\":64}" });
        }

        if (std.mem.eql(u8, request.path, "/api/v2/app/preferences")) {
            return withCors(self.handlePreferences(allocator));
        }

        if (std.mem.eql(u8, request.path, "/api/v2/app/setPreferences") and std.mem.eql(u8, request.method, "POST")) {
            return withCors(self.handleSetPreferences(allocator, request.body));
        }

        if (std.mem.eql(u8, request.path, "/api/v2/transfer/info")) {
            return withCors(self.handleTransferInfo(allocator));
        }

        if (std.mem.eql(u8, request.path, "/api/v2/transfer/speedLimitsMode")) {
            return withCors(self.handleSpeedLimitsMode(allocator));
        }

        // ── Ban management endpoints ──────────────────────────
        if (std.mem.eql(u8, request.path, "/api/v2/transfer/banPeers") and std.mem.eql(u8, request.method, "POST")) {
            return withCors(self.handleBanPeers(allocator, request.body));
        }

        if (std.mem.eql(u8, request.path, "/api/v2/transfer/unbanPeers") and std.mem.eql(u8, request.method, "POST")) {
            return withCors(self.handleUnbanPeers(allocator, request.body));
        }

        if (std.mem.eql(u8, request.path, "/api/v2/transfer/bannedPeers")) {
            return withCors(self.handleBannedPeers(allocator));
        }

        if (std.mem.eql(u8, request.path, "/api/v2/transfer/importBanList") and std.mem.eql(u8, request.method, "POST")) {
            return withCors(self.handleImportBanList(allocator, request.body, request.content_type));
        }

        if (std.mem.startsWith(u8, request.path, "/api/v2/torrents/")) {
            const action = request.path["/api/v2/torrents/".len..];
            return withCors(self.handleTorrents(allocator, request.method, action, request.body, request.content_type));
        }

        if (std.mem.startsWith(u8, request.path, "/api/v2/sync/maindata")) {
            return withCors(self.handleSyncMaindata(allocator, request.path));
        }

        if (std.mem.startsWith(u8, request.path, "/api/v2/sync/torrentPeers")) {
            return withCors(self.handleSyncTorrentPeers(allocator, request.path));
        }

        return withCors(.{ .status = 404, .body = "{\"error\":\"not found\"}" });
    }

    fn handleLogin(self: *ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const username = extractParam(body, "username") orelse
            return withCors(.{ .status = 400, .body = "missing username" });
        const password = extractParam(body, "password") orelse
            return withCors(.{ .status = 400, .body = "missing password" });

        if (!std.mem.eql(u8, username, self.api_username) or !std.mem.eql(u8, password, self.api_password)) {
            return withCors(.{ .body = "Fails.", .content_type = "text/plain" });
        }

        const sid = self.session_store.createSession();
        const header = std.fmt.allocPrint(allocator, "Set-Cookie: SID={s}; HttpOnly; path=/\r\n" ++ cors_headers, .{sid}) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{
            .body = "Ok.",
            .content_type = "text/plain",
            .extra_headers = header,
            .owned_extra_headers = header,
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
        const dht_nodes: usize = if (el) |e| e.getDhtNodeCount() else 0;

        const body = std.fmt.allocPrint(allocator, "{{\"connection_status\":\"connected\",\"dht_nodes\":{},\"dl_info_speed\":{},\"up_info_speed\":{},\"dl_info_data\":{},\"up_info_data\":{},\"dl_rate_limit\":{},\"up_rate_limit\":{}}}", .{ dht_nodes, total_dl_speed, total_ul_speed, total_dl_data, total_ul_data, dl_limit, ul_limit }) catch
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

        if (std.mem.eql(u8, action_name, "addTrackers") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsAddTrackers(allocator, body);
        }

        if (std.mem.startsWith(u8, action_name, "add") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsAdd(allocator, body, query, content_type);
        }

        if (std.mem.eql(u8, action_name, "removeTrackers") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsRemoveTrackers(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "editTracker") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsEditTracker(allocator, body);
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

        if (std.mem.eql(u8, action_name, "setSuperSeeding") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsSetSuperSeeding(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "recheck") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsRecheck(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "setLocation") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsSetLocation(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "connDiagnostics")) {
            return self.handleTorrentsConnDiagnostics(allocator, params);
        }

        if (std.mem.eql(u8, action_name, "setShareLimits") and std.mem.eql(u8, method, "POST")) {
            return self.handleSetShareLimits(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "webSeeds")) {
            return self.handleTorrentsWebSeeds(allocator, params);
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

        // Queue management endpoints (qBittorrent-compatible)
        if (std.mem.eql(u8, action_name, "increasePrio") and std.mem.eql(u8, method, "POST")) {
            return self.handleQueueIncreasePrio(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "decreasePrio") and std.mem.eql(u8, method, "POST")) {
            return self.handleQueueDecreasePrio(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "topPrio") and std.mem.eql(u8, method, "POST")) {
            return self.handleQueueTopPrio(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "bottomPrio") and std.mem.eql(u8, method, "POST")) {
            return self.handleQueueBottomPrio(allocator, body);
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
        var magnet_url: ?[]const u8 = extractParam(query, "urls") orelse extractParam(body, "urls");

        // Parse multipart/form-data if that's the content type (qBittorrent/Flood WebUI)
        if (multipart.isMultipart(content_type)) {
            const parts = multipart.parse(allocator, content_type.?, body) catch {
                return .{ .status = 400, .body = "{\"error\":\"malformed multipart body\"}" };
            };
            defer multipart.freeParts(allocator, parts);

            // Check for magnet URL in multipart "urls" field
            if (multipart.findPart(parts, "urls")) |urls_part| {
                if (urls_part.data.len > 0 and std.mem.startsWith(u8, urls_part.data, "magnet:")) {
                    magnet_url = urls_part.data;
                }
            }

            // Extract torrent file data (may be absent for magnet links)
            if (multipart.findPart(parts, "torrents")) |torrent_part| {
                torrent_data = torrent_part.data;
            } else {
                torrent_data = "";
            }

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

        // Handle magnet link (BEP 9)
        if (magnet_url) |magnet| {
            if (std.mem.startsWith(u8, magnet, "magnet:")) {
                const session = self.session_manager.addMagnet(magnet, save_path) catch |err| {
                    const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                        return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
                    return .{ .status = 400, .body = msg, .owned_body = msg };
                };

                if (category_param) |cat| {
                    if (cat.len > 0) {
                        self.session_manager.setTorrentCategory(&session.info_hash_hex, cat) catch {};
                    }
                }

                return .{ .body = "{\"status\":\"ok\"}" };
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
        // Expect hash in body as form param: hashes=<hash>&deleteFiles=true
        const hash = extractParam(body, "hashes") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };

        const delete_files = if (extractParam(body, "deleteFiles")) |v|
            std.mem.eql(u8, v, "true")
        else
            false;

        self.session_manager.removeTorrentEx(hash, delete_files) catch |err| {
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
        const sm = self.session_manager;
        const el = sm.shared_event_loop;
        const dl_limit: u64 = if (el) |e| e.getGlobalDlLimit() else 0;
        const ul_limit: u64 = if (el) |e| e.getGlobalUlLimit() else 0;
        const esc = json_mod.jsonSafe;
        const save_path = sm.default_save_path;

        // qBittorrent encryption: 0 = prefer, 1 = force, 2 = disable
        const enc_mode: u8 = if (el) |e| switch (e.encryption_mode) {
            .forced => 1,
            .preferred => 0,
            .enabled => 0,
            .disabled => 2,
        } else 0;

        const piece_cache_enabled = if (el) |e|
            (if (e.huge_page_cache) |*hpc| hpc.isAllocated() else false)
        else
            false;

        // Build banned_IPs string for preferences
        const banned_ips_str: []const u8 = if (sm.ban_list) |bl|
            bl.getBannedIpsString(allocator) catch ""
        else
            "";
        defer if (banned_ips_str.len > 0 and sm.ban_list != null) allocator.free(banned_ips_str);

        const qcfg = self.session_manager.queue_manager.config;

        const body = std.fmt.allocPrint(allocator,
            \\{{"dl_limit":{},"up_limit":{},"alt_dl_limit":0,"alt_up_limit":0,
            \\"save_path":"{f}","temp_path":"","temp_path_enabled":false,
            \\"queueing_enabled":{s},"max_active_downloads":{},"max_active_torrents":{},
            \\"max_active_uploads":{},"max_active_checking_torrents":1,
            \\"listen_port":6881,"random_port":false,"upnp":false,"upnp_lease_duration":0,
            \\"bittorrent_protocol":0,"utp_tcp_mixed_mode":0,
            \\"current_network_interface":"","current_interface_address":"",
            \\"announce_ip":"","reannounce_when_address_changed":false,
            \\"max_connec":500,"max_connec_per_torrent":100,
            \\"max_uploads":-1,"max_uploads_per_torrent":-1,
            \\"enable_multi_connections_from_same_ip":false,
            \\"outgoing_ports_min":0,"outgoing_ports_max":0,
            \\"limit_lan_peers":true,"limit_tcp_overhead":false,"limit_utp_rate":true,
            \\"peer_tos":0,"socket_backlog_size":30,
            \\"send_buffer_watermark":500,"send_buffer_low_watermark":10,
            \\"send_buffer_watermark_factor":50,
            \\"max_concurrent_http_announces":50,"request_queue_size":500,
            \\"stop_tracker_timeout":5,
            \\"max_ratio_enabled":{s},"max_ratio":{d:.4},"max_ratio_act":{},
            \\"max_seeding_time_enabled":{s},"max_seeding_time":{},
            \\"auto_tmm_enabled":false,"save_resume_data_interval":60,
            \\"start_paused_enabled":false,
            \\"dht":{s},"pex":{s},"lsd":false,"encryption":{},"anonymous_mode":false,
            \\"enable_utp":{s},
            \\"piece_cache_enabled":{},
            \\"ip_filter_enabled":false,"ip_filter_path":"","ip_filter_trackers":false,
            \\"banned_IPs":"{f}"}}
        , .{
            dl_limit,
            ul_limit,
            esc(save_path),
            @as([]const u8, if (qcfg.enabled) "true" else "false"),
            qcfg.max_active_downloads,
            qcfg.max_active_torrents,
            qcfg.max_active_uploads,
            @as([]const u8, if (sm.max_ratio_enabled) "true" else "false"),
            sm.max_ratio,
            sm.max_ratio_act,
            @as([]const u8, if (sm.max_seeding_time_enabled) "true" else "false"),
            sm.max_seeding_time,
            @as([]const u8, if (el) |e| (if (e.dht_engine != null) "true" else "false") else "false"),
            @as([]const u8, if (el) |e| (if (e.pex_enabled) "true" else "false") else "false"),
            enc_mode,
            @as([]const u8, if (el) |e| (if (e.utp_enabled) "true" else "false") else "false"),
            @as(u8, if (piece_cache_enabled) 1 else 0),
            esc(banned_ips_str),
        }) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .body = body, .owned_body = body };
    }

    fn handleSetPreferences(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        _ = allocator;
        const el = self.session_manager.shared_event_loop orelse
            return .{ .status = 500, .body = "{\"error\":\"no event loop\"}" };

        // Try form params first: dl_limit=N&up_limit=N
        // Also try extracting from JSON body: {"dl_limit":N,"up_limit":N}
        if (extractParam(body, "dl_limit")) |dl_str| {
            if (std.fmt.parseInt(u64, dl_str, 10)) |dl| {
                el.setGlobalDlLimit(dl);
            } else |_| {}
        } else if (extractJsonInt(body, "dl_limit")) |dl| {
            el.setGlobalDlLimit(dl);
        }
        if (extractParam(body, "up_limit")) |ul_str| {
            if (std.fmt.parseInt(u64, ul_str, 10)) |ul| {
                el.setGlobalUlLimit(ul);
            } else |_| {}
        } else if (extractJsonInt(body, "up_limit")) |ul| {
            el.setGlobalUlLimit(ul);
        }

        // Handle share ratio and seeding time limits
        {
            const sm = self.session_manager;

            // max_ratio_enabled: bool
            if (extractParam(body, "max_ratio_enabled")) |v| {
                sm.max_ratio_enabled = std.mem.eql(u8, v, "true");
            } else if (extractJsonBool(body, "max_ratio_enabled")) |v| {
                sm.max_ratio_enabled = v;
            }

            // max_ratio: float
            if (extractParam(body, "max_ratio")) |v| {
                sm.max_ratio = std.fmt.parseFloat(f64, v) catch sm.max_ratio;
            } else if (extractJsonFloat(body, "max_ratio")) |v| {
                sm.max_ratio = v;
            }

            // max_ratio_act: 0=pause, 1=remove
            if (extractParam(body, "max_ratio_act")) |v| {
                sm.max_ratio_act = std.fmt.parseInt(u8, v, 10) catch sm.max_ratio_act;
            } else if (extractJsonInt(body, "max_ratio_act")) |v| {
                sm.max_ratio_act = @intCast(@min(v, 1));
            }

            // max_seeding_time_enabled: bool
            if (extractParam(body, "max_seeding_time_enabled")) |v| {
                sm.max_seeding_time_enabled = std.mem.eql(u8, v, "true");
            } else if (extractJsonBool(body, "max_seeding_time_enabled")) |v| {
                sm.max_seeding_time_enabled = v;
            }

            // max_seeding_time: minutes (-1=disabled)
            if (extractParam(body, "max_seeding_time")) |v| {
                sm.max_seeding_time = std.fmt.parseInt(i64, v, 10) catch sm.max_seeding_time;
            } else if (extractJsonInt(body, "max_seeding_time")) |v| {
                sm.max_seeding_time = @intCast(v);
            }
        }

        // Handle banned_IPs: newline-separated list of IPs and CIDRs
        if (extractParam(body, "banned_IPs")) |banned_str| {
            if (self.session_manager.ban_list) |bl| {
                // URL-decode newlines: %0A -> \n
                const alloc = self.session_manager.allocator;
                var decoded = std.ArrayList(u8).empty;
                defer decoded.deinit(alloc);
                var i: usize = 0;
                while (i < banned_str.len) {
                    if (i + 2 < banned_str.len and banned_str[i] == '%' and banned_str[i + 1] == '0' and (banned_str[i + 2] == 'A' or banned_str[i + 2] == 'a')) {
                        decoded.append(alloc, '\n') catch break;
                        i += 3;
                    } else {
                        decoded.append(alloc, banned_str[i]) catch break;
                        i += 1;
                    }
                }
                bl.setBannedIpsFromString(decoded.items) catch {};
                el.ban_list_dirty.store(true, .release);
                self.session_manager.persistBanList();
            }
        }

        // Handle queue settings
        var queue_changed = false;
        if (extractParam(body, "queueing_enabled")) |val| {
            self.session_manager.queue_manager.config.enabled = std.mem.eql(u8, val, "true");
            queue_changed = true;
        } else if (extractJsonBool(body, "queueing_enabled")) |val| {
            self.session_manager.queue_manager.config.enabled = val;
            queue_changed = true;
        }
        if (extractParam(body, "max_active_downloads")) |val| {
            if (std.fmt.parseInt(i32, val, 10)) |v| {
                self.session_manager.queue_manager.config.max_active_downloads = v;
                queue_changed = true;
            } else |_| {}
        } else if (extractJsonInt(body, "max_active_downloads")) |v| {
            self.session_manager.queue_manager.config.max_active_downloads = @intCast(v);
            queue_changed = true;
        }
        if (extractParam(body, "max_active_uploads")) |val| {
            if (std.fmt.parseInt(i32, val, 10)) |v| {
                self.session_manager.queue_manager.config.max_active_uploads = v;
                queue_changed = true;
            } else |_| {}
        } else if (extractJsonInt(body, "max_active_uploads")) |v| {
            self.session_manager.queue_manager.config.max_active_uploads = @intCast(v);
            queue_changed = true;
        }
        if (extractParam(body, "max_active_torrents")) |val| {
            if (std.fmt.parseInt(i32, val, 10)) |v| {
                self.session_manager.queue_manager.config.max_active_torrents = v;
                queue_changed = true;
            } else |_| {}
        } else if (extractJsonInt(body, "max_active_torrents")) |v| {
            self.session_manager.queue_manager.config.max_active_torrents = @intCast(v);
            queue_changed = true;
        }

        // If queue settings changed, re-evaluate the queue
        if (queue_changed) {
            self.session_manager.runQueueEnforcement();
        }

        // DHT toggle (runtime: stops/starts DHT peer discovery)
        if (extractParam(body, "dht")) |v| {
            self.session_manager.setDhtEnabled(std.mem.eql(u8, v, "true"));
        } else if (extractJsonBool(body, "dht")) |v| {
            self.session_manager.setDhtEnabled(v);
        }

        // PEX toggle (runtime: stops sending/receiving PEX messages)
        if (extractParam(body, "pex")) |v| {
            el.pex_enabled = std.mem.eql(u8, v, "true");
        } else if (extractJsonBool(body, "pex")) |v| {
            el.pex_enabled = v;
        }

        // uTP toggle (runtime: controls whether new connections use uTP transport)
        if (extractParam(body, "enable_utp")) |v| {
            el.utp_enabled = std.mem.eql(u8, v, "true");
        } else if (extractJsonBool(body, "enable_utp")) |v| {
            el.utp_enabled = v;
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

            json.print(allocator, "{{\"index\":{},\"name\":\"{f}\",\"size\":{},\"progress\":{d:.4},\"priority\":{},\"availability\":{d:.4},\"is_seed\":false,\"piece_range\":[{},{}]}}", .{
                i,
                json_mod.jsonSafe(file.name),
                file.size,
                file.progress,
                file.priority,
                file.progress, // availability approximated by progress
                file.first_piece,
                file.last_piece,
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
            json.print(allocator, "{{\"url\":\"{f}\",\"status\":{},\"tier\":{},\"num_peers\":{},\"num_seeds\":{},\"num_leeches\":{},\"num_downloaded\":{},\"msg\":\"\"}}", .{
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
        const esc = json_mod.jsonSafe;

        const v2_hex = if (info.info_hash_v2 != null) compat.formatInfoHashV2(info.info_hash_v2) else [_]u8{0} ** 64;
        const v2_str: []const u8 = if (info.info_hash_v2 != null) &v2_hex else "";
        const completion_date: i64 = if (info.completion_on > 0) info.completion_on else if (info.state == .seeding) info.added_on else -1;

        var json = std.ArrayList(u8).empty;
        defer json.deinit(allocator);

        // Split into two print calls to stay under Zig's 32-argument format limit
        json.print(allocator, "{{\"save_path\":\"{f}\",\"download_path\":\"\",\"creation_date\":{},\"piece_size\":{},\"comment\":\"{f}\",\"created_by\":\"{f}\",\"total_size\":{},\"pieces_have\":{},\"pieces_num\":{},\"dl_speed\":{},\"dl_speed_avg\":0,\"up_speed\":{},\"up_speed_avg\":0,\"dl_limit\":{},\"up_limit\":{},\"eta\":{},\"hash\":\"{s}\",\"infohash_v1\":\"{s}\",\"infohash_v2\":\"{s}\",\"name\":\"{f}\",\"ratio\":{d:.4},\"share_ratio\":{d:.4},\"time_elapsed\":{},\"time_active\":{},\"seeding_time\":{},\"nb_connections\":{},\"nb_connections_limit\":500,", .{
            esc(info.save_path),
            info.creation_date,
            info.piece_size,
            esc(info.comment),
            esc(info.created_by),
            info.total_size,
            info.pieces_have,
            info.pieces_total,
            info.download_speed,
            info.upload_speed,
            info.dl_limit,
            info.ul_limit,
            info.eta,
            info.info_hash_hex,
            info.info_hash_hex,
            v2_str,
            esc(info.name),
            info.ratio,
            info.ratio,
            time_active,
            time_active,
            info.seeding_time,
            info.peers_connected,
        }) catch return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        json.print(allocator, "\"peers\":{},\"peers_total\":{},\"seeds\":{},\"seeds_total\":{},\"last_seen\":-1,\"reannounce\":0,\"addition_date\":{},\"completion_date\":{},\"total_downloaded\":{},\"total_downloaded_session\":{},\"total_uploaded\":{},\"total_uploaded_session\":{},\"total_wasted\":0,\"is_private\":{s},\"seq_dl\":{s},\"super_seeding\":{},\"web_seeds_count\":{},\"partial_seed\":{s},\"ratio_limit\":{d:.4},\"seeding_time_limit\":{}}}", .{
            info.scrape_incomplete,
            info.scrape_complete,
            info.scrape_complete,
            info.scrape_complete,
            info.added_on,
            completion_date,
            info.bytes_downloaded,
            info.bytes_downloaded,
            info.bytes_uploaded,
            info.bytes_uploaded,
            @as([]const u8, if (info.is_private) "true" else "false"),
            @as([]const u8, if (info.sequential_download) "true" else "false"),
            @as(u8, if (info.super_seeding) 1 else 0),
            info.web_seeds_count,
            @as([]const u8, if (info.partial_seed) "true" else "false"),
            info.ratio_limit,
            info.seeding_time_limit,
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

    fn handleTorrentsSetSuperSeeding(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParam(body, "hashes") orelse (extractParam(body, "hash") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" });
        const value_str = extractParam(body, "value") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing value\"}" };

        const enabled = std.mem.eql(u8, value_str, "true");

        self.session_manager.setSuperSeeding(hash, enabled) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
            return .{ .status = 404, .body = msg, .owned_body = msg };
        };

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    // ── Tracker editing handlers ────────────────────────────

    fn handleTorrentsAddTrackers(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParam(body, "hash") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" };
        const urls_str = extractParam(body, "urls") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing urls\"}" };

        // URLs are newline-separated (qBittorrent compat: %0A is \n)
        var url_list = std.ArrayList([]const u8).empty;
        defer url_list.deinit(allocator);
        var iter = std.mem.splitSequence(u8, urls_str, "%0A");
        while (iter.next()) |part| {
            // Also handle literal newlines
            var sub_iter = std.mem.splitScalar(u8, part, '\n');
            while (sub_iter.next()) |url| {
                const trimmed = std.mem.trim(u8, url, " \r\t");
                if (trimmed.len > 0) {
                    url_list.append(allocator, trimmed) catch continue;
                }
            }
        }

        if (url_list.items.len == 0) {
            return .{ .status = 400, .body = "{\"error\":\"no valid urls\"}" };
        }

        self.session_manager.addTrackers(hash, url_list.items) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
            return .{ .status = 404, .body = msg, .owned_body = msg };
        };

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleTorrentsRemoveTrackers(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParam(body, "hash") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" };
        const urls_str = extractParam(body, "urls") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing urls\"}" };

        // URLs are pipe-separated (qBittorrent compat: %7C is |)
        var url_list = std.ArrayList([]const u8).empty;
        defer url_list.deinit(allocator);
        var iter = std.mem.splitSequence(u8, urls_str, "%7C");
        while (iter.next()) |part| {
            var sub_iter = std.mem.splitScalar(u8, part, '|');
            while (sub_iter.next()) |url| {
                const trimmed = std.mem.trim(u8, url, " \r\t\n");
                if (trimmed.len > 0) {
                    url_list.append(allocator, trimmed) catch continue;
                }
            }
        }

        if (url_list.items.len == 0) {
            return .{ .status = 400, .body = "{\"error\":\"no valid urls\"}" };
        }

        self.session_manager.removeTrackers(hash, url_list.items) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
            return .{ .status = 404, .body = msg, .owned_body = msg };
        };

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleTorrentsEditTracker(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParam(body, "hash") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" };
        const orig_url = extractParam(body, "origUrl") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing origUrl\"}" };
        const new_url = extractParam(body, "newUrl") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing newUrl\"}" };

        self.session_manager.editTracker(hash, orig_url, new_url) catch |err| {
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

    fn handleTorrentsSetLocation(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParam(body, "hashes") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const location = extractParam(body, "location") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing location\"}" };

        if (location.len == 0) {
            return .{ .status = 400, .body = "{\"error\":\"empty location\"}" };
        }

        self.session_manager.setLocation(hash, location) catch |err| {
            const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
            return .{ .status = 409, .body = msg, .owned_body = msg };
        };

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleTorrentsConnDiagnostics(self: *const ApiHandler, allocator: std.mem.Allocator, params: []const u8) server.Response {
        const hash = extractParam(params, "hash") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" };

        const diag = self.session_manager.getConnDiagnostics(hash) catch
            return .{ .status = 404, .body = "{\"error\":\"torrent not found\"}" };

        const body = std.fmt.allocPrint(allocator, "{{\"connection_attempts\":{},\"connection_failures\":{},\"timeout_failures\":{},\"refused_failures\":{},\"peers_connected\":{},\"peers_half_open\":{}}}", .{
            diag.connection_attempts,
            diag.connection_failures,
            diag.timeout_failures,
            diag.refused_failures,
            diag.peers_connected,
            diag.peers_half_open,
        }) catch return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .body = body, .owned_body = body };
    }

    fn handleSetShareLimits(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        // hashes=<hash1>|<hash2>&ratioLimit=<float>&seedingTimeLimit=<int>
        const hashes_str = extractParam(body, "hashes") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };

        // Parse ratio limit (-2 = use global, -1 = no limit, >=0 = specific)
        const ratio_limit: f64 = if (extractParam(body, "ratioLimit")) |v|
            std.fmt.parseFloat(f64, v) catch -2.0
        else
            -2.0;

        // Parse seeding time limit in minutes (-2 = use global, -1 = no limit, >=0 = minutes)
        const seeding_time_limit: i64 = if (extractParam(body, "seedingTimeLimit")) |v|
            std.fmt.parseInt(i64, v, 10) catch -2
        else
            -2;

        // Apply to each hash (pipe-separated)
        var hash_iter = std.mem.splitScalar(u8, hashes_str, '|');
        while (hash_iter.next()) |hash| {
            if (hash.len == 0) continue;
            self.session_manager.setShareLimits(hash, ratio_limit, seeding_time_limit) catch |err| {
                const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                    return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
                return .{ .status = 404, .body = msg, .owned_body = msg };
            };
        }
        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleTorrentsWebSeeds(self: *const ApiHandler, allocator: std.mem.Allocator, params: []const u8) server.Response {
        const hash = extractParam(params, "hash") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" };

        const urls = self.session_manager.getWebSeedUrls(allocator, hash) catch
            return .{ .status = 404, .body = "{\"error\":\"torrent not found\"}" };
        defer {
            for (urls) |u| allocator.free(u);
            allocator.free(urls);
        }

        var json = std.ArrayList(u8).empty;
        defer json.deinit(allocator);

        const esc = json_mod.jsonSafe;
        json.appendSlice(allocator, "[") catch return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        for (urls, 0..) |url, i| {
            if (i > 0) json.appendSlice(allocator, ",") catch return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
            json.print(allocator, "{{\"url\":\"{f}\"}}", .{esc(url)}) catch return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        }
        json.appendSlice(allocator, "]") catch return .{ .status = 500, .body = "{\"error\":\"internal\"}" };

        const body = json.toOwnedSlice(allocator) catch return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .body = body, .owned_body = body };
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

    fn handleSyncTorrentPeers(self: *const ApiHandler, allocator: std.mem.Allocator, path: []const u8) server.Response {
        // Parse hash from query string: /api/v2/sync/torrentPeers?hash=...&rid=...
        var hash: ?[]const u8 = null;
        if (std.mem.indexOf(u8, path, "?")) |q| {
            const query = path[q + 1 ..];
            hash = extractParam(query, "hash");
        }

        const hash_val = hash orelse
            return .{ .body = "{\"rid\":1,\"full_update\":true,\"peers\":{}}" };

        const peers = self.session_manager.getTorrentPeers(allocator, hash_val) catch
            return .{ .body = "{\"rid\":1,\"full_update\":true,\"peers\":{}}" };
        defer SessionManager.freePeerInfos(allocator, peers);

        var json = std.ArrayList(u8).empty;
        defer json.deinit(allocator);

        json.appendSlice(allocator, "{\"rid\":1,\"full_update\":true,\"peers\":{") catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };

        const esc = json_mod.jsonSafe;

        for (peers, 0..) |peer, i| {
            if (i > 0) json.append(allocator, ',') catch {};
            // Key is ip:port, value is peer object
            json.print(allocator, "\"{f}\":{{\"client\":\"{f}\",\"connection\":\"\",\"country\":\"\",\"country_code\":\"\",\"dl_speed\":{},\"downloaded\":{},\"files\":\"\",\"flags\":\"{f}\",\"flags_desc\":\"\",\"ip\":\"{f}\",\"port\":{},\"progress\":{d:.4},\"relevance\":1,\"up_speed\":{},\"uploaded\":{},\"upload_only\":{}}}", .{
                esc(peer.ip),
                esc(peer.client),
                peer.dl_speed,
                peer.downloaded,
                esc(peer.flags),
                esc(peer.ip),
                peer.port,
                peer.progress,
                peer.ul_speed,
                peer.uploaded,
                peer.upload_only,
            }) catch {};
        }

        json.appendSlice(allocator, "}}") catch {};

        const body = json.toOwnedSlice(allocator) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .body = body, .owned_body = body };
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

        var arena_state = std.heap.ArenaAllocator.init(allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();

        const arena_body = self.sync_state.computeDelta(
            self.session_manager,
            arena,
            request_rid,
        ) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };

        const body = allocator.dupe(u8, arena_body) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .body = body, .owned_body = body };
    }

    // ── Ban management handlers ────────────────────────────

    /// POST /api/v2/transfer/banPeers -- qBittorrent-compatible ban endpoint.
    /// peers=ip:port|ip:port|... (pipe-separated)
    fn handleBanPeers(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        _ = allocator;
        const bl = self.session_manager.ban_list orelse
            return .{ .status = 500, .body = "{\"error\":\"ban list not initialized\"}" };

        const peers_str = extractParam(body, "peers") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing peers parameter\"}" };

        // Parse pipe-separated peer list
        var iter = std.mem.splitScalar(u8, peers_str, '|');
        while (iter.next()) |peer_str| {
            const trimmed = std.mem.trim(u8, peer_str, " \t");
            if (trimmed.len == 0) continue;

            const addr = BanList.parseIpPort(trimmed) orelse continue;
            _ = bl.banIp(addr, null, .manual) catch continue;
        }

        // Signal event loop to enforce bans on existing peers
        if (self.session_manager.shared_event_loop) |el| {
            el.ban_list_dirty.store(true, .release);
        }

        // Persist to SQLite (background thread)
        self.session_manager.persistBanList();

        return .{ .body = "" };
    }

    /// POST /api/v2/transfer/unbanPeers -- Varuna extension.
    /// ips=ip|ip|... (pipe-separated)
    fn handleUnbanPeers(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const bl = self.session_manager.ban_list orelse
            return .{ .status = 500, .body = "{\"error\":\"ban list not initialized\"}" };

        const ips_str = extractParam(body, "ips") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing ips parameter\"}" };

        var removed: usize = 0;
        var iter = std.mem.splitScalar(u8, ips_str, '|');
        while (iter.next()) |ip_str| {
            const trimmed = std.mem.trim(u8, ip_str, " \t");
            if (trimmed.len == 0) continue;

            if (bl.unbanIpStr(trimmed)) {
                removed += 1;
            }
        }

        // Persist to SQLite (background thread)
        self.session_manager.persistBanList();

        const resp = std.fmt.allocPrint(allocator, "{{\"removed\":{}}}", .{removed}) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .body = resp, .owned_body = resp };
    }

    /// GET /api/v2/transfer/bannedPeers -- list all bans.
    fn handleBannedPeers(self: *const ApiHandler, allocator: std.mem.Allocator) server.Response {
        const bl = self.session_manager.ban_list orelse
            return .{ .body = "{\"individual\":[],\"ranges\":[],\"total_rules\":0}" };

        const bans = bl.listBans(allocator) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        defer {
            for (bans) |info| {
                allocator.free(info.ip_str);
                if (info.reason) |r| allocator.free(r);
            }
            allocator.free(bans);
        }

        const ranges = bl.listRanges(allocator) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        defer {
            for (ranges) |info| {
                allocator.free(info.start_str);
                allocator.free(info.end_str);
            }
            allocator.free(ranges);
        }

        const esc = json_mod.jsonSafe;
        var json_buf = std.ArrayList(u8).empty;
        defer json_buf.deinit(allocator);

        json_buf.appendSlice(allocator, "{\"individual\":[") catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };

        for (bans, 0..) |info, idx| {
            if (idx > 0) json_buf.append(allocator, ',') catch {};
            const source_str: []const u8 = if (info.source == .manual) "manual" else "ipfilter";
            if (info.reason) |r| {
                json_buf.writer(allocator).print("{{\"ip\":\"{f}\",\"source\":\"{s}\",\"reason\":\"{f}\",\"created_at\":{}}}", .{
                    esc(info.ip_str), source_str, esc(r), info.created_at,
                }) catch {};
            } else {
                json_buf.writer(allocator).print("{{\"ip\":\"{f}\",\"source\":\"{s}\",\"reason\":null,\"created_at\":{}}}", .{
                    esc(info.ip_str), source_str, info.created_at,
                }) catch {};
            }
        }

        json_buf.appendSlice(allocator, "],\"ranges\":[") catch {};

        for (ranges, 0..) |info, idx| {
            if (idx > 0) json_buf.append(allocator, ',') catch {};
            const source_str: []const u8 = if (info.source == .manual) "manual" else "ipfilter";
            json_buf.writer(allocator).print("{{\"start\":\"{f}\",\"end\":\"{f}\",\"source\":\"{s}\",\"created_at\":{}}}", .{
                esc(info.start_str), esc(info.end_str), source_str, info.created_at,
            }) catch {};
        }

        const total = bl.ruleCount();
        json_buf.writer(allocator).print("],\"total_rules\":{}}}", .{total}) catch {};

        const resp_body = json_buf.toOwnedSlice(allocator) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .body = resp_body, .owned_body = resp_body };
    }

    /// POST /api/v2/transfer/importBanList -- import an ipfilter file.
    /// Accepts either raw body content or form-encoded with file= parameter.
    fn handleImportBanList(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8, content_type: ?[]const u8) server.Response {
        _ = content_type;
        const bl = self.session_manager.ban_list orelse
            return .{ .status = 500, .body = "{\"error\":\"ban list not initialized\"}" };

        // Extract file content: try form-encoded file= parameter first, then raw body
        const file_data: []const u8 = extractParam(body, "file") orelse body;

        // Determine format from form-encoded format= parameter
        const format_str = extractParam(body, "format") orelse "auto";
        const format: ipfilter_parser.Format = if (std.mem.eql(u8, format_str, "dat"))
            .dat
        else if (std.mem.eql(u8, format_str, "p2p"))
            .p2p
        else if (std.mem.eql(u8, format_str, "cidr"))
            .cidr
        else
            .auto;

        const result = ipfilter_parser.parseFile(bl, file_data, format);

        // Signal event loop to enforce bans
        if (self.session_manager.shared_event_loop) |el| {
            el.ban_list_dirty.store(true, .release);
        }

        // Persist to SQLite
        self.session_manager.persistBanList();

        const resp = std.fmt.allocPrint(allocator, "{{\"imported\":{},\"errors\":{}}}", .{ result.imported, result.errors }) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .body = resp, .owned_body = resp };
    }

    // ── Queue management endpoints (qBittorrent-compatible) ──

    fn handleQueueIncreasePrio(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        return self.handleQueuePrioAction(allocator, body, .increase);
    }

    fn handleQueueDecreasePrio(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        return self.handleQueuePrioAction(allocator, body, .decrease);
    }

    fn handleQueueTopPrio(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        return self.handleQueuePrioAction(allocator, body, .top);
    }

    fn handleQueueBottomPrio(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        return self.handleQueuePrioAction(allocator, body, .bottom);
    }

    const QueueAction = enum { increase, decrease, top, bottom };

    fn handleQueuePrioAction(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8, action: QueueAction) server.Response {
        const hashes_str = extractParam(body, "hashes") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };

        // Support multiple hashes separated by |
        var iter = std.mem.splitScalar(u8, hashes_str, '|');
        while (iter.next()) |hash| {
            if (hash.len == 0) continue;
            const result = switch (action) {
                .increase => self.session_manager.queueIncreasePrio(hash),
                .decrease => self.session_manager.queueDecreasePrio(hash),
                .top => self.session_manager.queueTopPrio(hash),
                .bottom => self.session_manager.queueBottomPrio(hash),
            };
            result catch |err| {
                const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
                    return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
                return .{ .status = 404, .body = msg, .owned_body = msg };
            };
        }

        return .{ .body = "{\"status\":\"ok\"}" };
    }
};

fn serializeTorrentInfo(allocator: std.mem.Allocator, json: *std.ArrayList(u8), stat: TorrentSession.Stats) !void {
    const esc = json_mod.jsonSafe;
    const qbt_state = compat.torrentStateString(stat.state, stat.progress);
    const now = std.time.timestamp();
    const time_active: i64 = now - stat.added_on;
    const amount_left: u64 = if (stat.total_size > stat.bytes_downloaded) stat.total_size - stat.bytes_downloaded else 0;
    const completion_on: i64 = if (stat.progress >= 1.0) stat.added_on else -1;

    // Build content_path: save_path + "/" + name for the full path
    const content_path = buildContentPath(allocator, stat.save_path, stat.name) catch stat.save_path;
    defer if (content_path.ptr != stat.save_path.ptr) allocator.free(content_path);

    // Build magnet URI: magnet:?xt=urn:btih:<hex>&dn=<name>&tr=<tracker>
    const magnet_uri = buildMagnetUri(allocator, &stat.info_hash_hex, stat.name, stat.tracker) catch "";
    defer if (magnet_uri.len > 0) allocator.free(magnet_uri);

    // Split into two print calls to stay under the 32-argument limit.
    const v2_hex = if (stat.info_hash_v2 != null) compat.formatInfoHashV2(stat.info_hash_v2) else [_]u8{0} ** 64;
    const v2_str: []const u8 = if (stat.info_hash_v2 != null) &v2_hex else "";
    try json.print(
        allocator,
        "{{\"name\":\"{f}\",\"hash\":\"{s}\",\"infohash_v1\":\"{s}\",\"infohash_v2\":\"{s}\",\"state\":\"{s}\",\"size\":{},\"total_size\":{},\"progress\":{d:.4},\"dlspeed\":{},\"upspeed\":{},\"num_seeds\":{},\"num_leechs\":{},\"num_complete\":{},\"num_incomplete\":{},\"added_on\":{},\"completion_on\":{},\"save_path\":\"{f}\",\"content_path\":\"{f}\",\"download_path\":\"\",\"pieces_have\":{},\"pieces_num\":{},\"dl_limit\":{},\"up_limit\":{},\"eta\":{},\"ratio\":{d:.4},\"seq_dl\":{s},\"private\":{s}",
        .{
            esc(stat.name),
            stat.info_hash_hex,
            stat.info_hash_hex,
            v2_str,
            qbt_state,
            stat.total_size,
            stat.total_size,
            stat.progress,
            stat.download_speed,
            stat.upload_speed,
            stat.scrape_complete,
            stat.peers_connected,
            stat.scrape_complete,
            stat.scrape_incomplete,
            stat.added_on,
            completion_on,
            esc(stat.save_path),
            esc(content_path),
            stat.pieces_have,
            stat.pieces_total,
            stat.dl_limit,
            stat.ul_limit,
            stat.eta,
            stat.ratio,
            @as([]const u8, if (stat.sequential_download) "true" else "false"),
            @as([]const u8, if (stat.is_private) "true" else "false"),
        },
    );

    try json.print(
        allocator,
        ",\"f_l_piece_prio\":false,\"force_start\":false,\"super_seeding\":{s},\"partial_seed\":{s},\"auto_tmm\":false,\"category\":\"{f}\",\"tags\":\"{f}\",\"tracker\":\"{f}\",\"trackers_count\":{},\"amount_left\":{},\"completed\":{},\"downloaded\":{},\"downloaded_session\":{},\"uploaded\":{},\"uploaded_session\":{},\"time_active\":{},\"seeding_time\":{},\"last_activity\":{},\"seen_complete\":-1,\"priority\":{},\"availability\":-1,\"max_ratio\":-1,\"max_seeding_time\":-1,\"ratio_limit\":{d:.4},\"seeding_time_limit\":{},\"popularity\":0,\"magnet_uri\":\"{f}\",\"reannounce\":0}}",
        .{
            @as([]const u8, if (stat.super_seeding) "true" else "false"),
            @as([]const u8, if (stat.partial_seed) "true" else "false"),
            esc(stat.category),
            esc(stat.tags),
            esc(stat.tracker),
            stat.trackers_count,
            amount_left,
            stat.bytes_downloaded,
            stat.bytes_downloaded,
            stat.bytes_downloaded,
            stat.bytes_uploaded,
            stat.bytes_uploaded,
            time_active,
            stat.seeding_time,
            now,
            stat.queue_position,
            stat.ratio_limit,
            stat.seeding_time_limit,
            esc(magnet_uri),
        },
    );
}

// buildContentPath and buildMagnetUri are in compat.zig (shared with sync.zig).
const buildContentPath = compat.buildContentPath;
const buildMagnetUri = compat.buildMagnetUri;

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

/// Extract an integer value from a simple JSON object by key.
/// Handles: {"key":123} or {"key": 123} patterns without a full JSON parser.
fn extractJsonInt(body: []const u8, key: []const u8) ?u64 {
    // Search for "key": or "key":
    var needle_buf: [128]u8 = undefined;
    if (key.len + 3 > needle_buf.len) return null;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1..][0..key.len], key);
    needle_buf[key.len + 1] = '"';
    needle_buf[key.len + 2] = ':';
    const needle = needle_buf[0 .. key.len + 3];

    const key_pos = std.mem.indexOf(u8, body, needle) orelse return null;
    var val_start = key_pos + needle.len;

    // Skip whitespace
    while (val_start < body.len and body[val_start] == ' ') val_start += 1;
    if (val_start >= body.len) return null;

    // Read digits
    var val_end = val_start;
    while (val_end < body.len and body[val_end] >= '0' and body[val_end] <= '9') val_end += 1;
    if (val_end == val_start) return null;

    return std.fmt.parseInt(u64, body[val_start..val_end], 10) catch null;
}

/// Extract a boolean value from a simple JSON object by key.
/// Handles: {"key":true} or {"key": false} patterns without a full JSON parser.
fn extractJsonBool(body: []const u8, key: []const u8) ?bool {
    var needle_buf: [128]u8 = undefined;
    if (key.len + 3 > needle_buf.len) return null;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1..][0..key.len], key);
    needle_buf[key.len + 1] = '"';
    needle_buf[key.len + 2] = ':';
    const needle = needle_buf[0 .. key.len + 3];

    const key_pos = std.mem.indexOf(u8, body, needle) orelse return null;
    var val_start = key_pos + needle.len;

    // Skip whitespace
    while (val_start < body.len and body[val_start] == ' ') val_start += 1;
    if (val_start >= body.len) return null;

    if (val_start + 4 <= body.len and std.mem.eql(u8, body[val_start..][0..4], "true")) return true;
    if (val_start + 5 <= body.len and std.mem.eql(u8, body[val_start..][0..5], "false")) return false;
    return null;
}

/// Extract a float value from a simple JSON object by key.
/// Handles: {"key":1.5} or {"key": -1} patterns without a full JSON parser.
fn extractJsonFloat(body: []const u8, key: []const u8) ?f64 {
    var needle_buf: [128]u8 = undefined;
    if (key.len + 3 > needle_buf.len) return null;
    needle_buf[0] = '"';
    @memcpy(needle_buf[1..][0..key.len], key);
    needle_buf[key.len + 1] = '"';
    needle_buf[key.len + 2] = ':';
    const needle = needle_buf[0 .. key.len + 3];

    const key_pos = std.mem.indexOf(u8, body, needle) orelse return null;
    var val_start = key_pos + needle.len;

    // Skip whitespace
    while (val_start < body.len and body[val_start] == ' ') val_start += 1;
    if (val_start >= body.len) return null;

    // Read number characters (digits, minus, dot)
    var val_end = val_start;
    while (val_end < body.len and (body[val_end] == '-' or body[val_end] == '.' or (body[val_end] >= '0' and body[val_end] <= '9'))) val_end += 1;
    if (val_end == val_start) return null;

    return std.fmt.parseFloat(f64, body[val_start..val_end]) catch null;
}

test "extract form param" {
    try std.testing.expectEqualStrings("abc123", extractParam("hashes=abc123&deleteFiles=false", "hashes").?);
    try std.testing.expectEqualStrings("false", extractParam("hashes=abc123&deleteFiles=false", "deleteFiles").?);
    try std.testing.expect(extractParam("hashes=abc", "missing") == null);
}

test "extract json int" {
    try std.testing.expectEqual(@as(?u64, 1024), extractJsonInt("{\"dl_limit\":1024,\"up_limit\":512}", "dl_limit"));
    try std.testing.expectEqual(@as(?u64, 512), extractJsonInt("{\"dl_limit\":1024,\"up_limit\":512}", "up_limit"));
    try std.testing.expectEqual(@as(?u64, 100), extractJsonInt("{\"dl_limit\": 100}", "dl_limit"));
    try std.testing.expect(extractJsonInt("{\"dl_limit\":1024}", "missing") == null);
    try std.testing.expect(extractJsonInt("dl_limit=1024", "dl_limit") == null);
}

test "extract json bool" {
    try std.testing.expectEqual(@as(?bool, true), extractJsonBool("{\"max_ratio_enabled\":true}", "max_ratio_enabled"));
    try std.testing.expectEqual(@as(?bool, false), extractJsonBool("{\"max_ratio_enabled\":false}", "max_ratio_enabled"));
    try std.testing.expectEqual(@as(?bool, true), extractJsonBool("{\"max_ratio_enabled\": true}", "max_ratio_enabled"));
    try std.testing.expect(extractJsonBool("{\"max_ratio_enabled\":1}", "max_ratio_enabled") == null);
    try std.testing.expect(extractJsonBool("{}", "max_ratio_enabled") == null);
}

test "extract json float" {
    const eps = 0.0001;
    const v1 = extractJsonFloat("{\"max_ratio\":2.5}", "max_ratio").?;
    try std.testing.expect(@abs(v1 - 2.5) < eps);
    const v2 = extractJsonFloat("{\"max_ratio\":-1}", "max_ratio").?;
    try std.testing.expect(@abs(v2 - (-1.0)) < eps);
    const v3 = extractJsonFloat("{\"max_ratio\": 0.75}", "max_ratio").?;
    try std.testing.expect(@abs(v3 - 0.75) < eps);
    try std.testing.expect(extractJsonFloat("{}", "max_ratio") == null);
}

// ── Additional parameter extraction tests ────────────────

test "extractParam returns empty string for key with no value" {
    try std.testing.expectEqualStrings("", extractParam("hashes=&deleteFiles=true", "hashes").?);
}

test "extractParam returns first match for duplicate keys" {
    try std.testing.expectEqualStrings("first", extractParam("key=first&key=second", "key").?);
}

test "extractParam handles single param without ampersand" {
    try std.testing.expectEqualStrings("val", extractParam("key=val", "key").?);
}

test "extractParam returns null for empty body" {
    try std.testing.expect(extractParam("", "key") == null);
}

test "extractParam does not match partial key names" {
    // "hash" should not match "hashes=abc"
    try std.testing.expect(extractParam("hashes=abc", "hash") == null);
}

test "extractParam handles value with equals sign" {
    // "url=http://host?a=b" -- value contains '='
    try std.testing.expectEqualStrings("http://host?a", extractParam("url=http://host?a=b", "url").?);
}

test "extractParam handles url-encoded special chars in value" {
    try std.testing.expectEqualStrings("hello%20world", extractParam("name=hello%20world", "name").?);
}

test "extractJsonInt returns null for non-numeric value" {
    try std.testing.expect(extractJsonInt("{\"dl_limit\":\"abc\"}", "dl_limit") == null);
}

test "extractJsonInt handles zero value" {
    try std.testing.expectEqual(@as(?u64, 0), extractJsonInt("{\"dl_limit\":0}", "dl_limit"));
}

test "extractJsonInt handles large value" {
    try std.testing.expectEqual(@as(?u64, 999999999), extractJsonInt("{\"dl_limit\":999999999}", "dl_limit"));
}

test "extractJsonInt returns null for empty body" {
    try std.testing.expect(extractJsonInt("", "dl_limit") == null);
}

test "extractJsonInt handles multiple spaces after colon" {
    try std.testing.expectEqual(@as(?u64, 42), extractJsonInt("{\"dl_limit\":  42}", "dl_limit"));
}

test "extractJsonBool returns null for empty body" {
    try std.testing.expect(extractJsonBool("", "enabled") == null);
}

test "extractJsonBool handles key with multiple whitespace" {
    try std.testing.expectEqual(@as(?bool, false), extractJsonBool("{\"enabled\":   false}", "enabled"));
}

test "extractJsonBool returns null for string true" {
    // "true" in quotes should not match
    try std.testing.expect(extractJsonBool("{\"enabled\":\"true\"}", "enabled") == null);
}

test "extractJsonFloat handles zero" {
    const eps = 0.0001;
    const v = extractJsonFloat("{\"ratio\":0.0}", "ratio").?;
    try std.testing.expect(@abs(v) < eps);
}

test "extractJsonFloat handles negative decimal" {
    const eps = 0.0001;
    const v = extractJsonFloat("{\"ratio\":-2.5}", "ratio").?;
    try std.testing.expect(@abs(v - (-2.5)) < eps);
}

test "extractJsonFloat returns null for boolean value" {
    try std.testing.expect(extractJsonFloat("{\"ratio\":true}", "ratio") == null);
}

test "extractJsonFloat returns null for empty body" {
    try std.testing.expect(extractJsonFloat("", "ratio") == null);
}

test "extractJsonInt key length near buffer limit" {
    // Key that is exactly 125 chars (128 - 3 for quotes and colon)
    const long_key = "a" ** 125;
    const body = "\"" ++ long_key ++ "\":42";
    try std.testing.expectEqual(@as(?u64, 42), extractJsonInt(body, long_key));
}

test "extractJsonInt key too long for needle buffer" {
    // Key that exceeds 125 chars should return null gracefully
    const long_key = "a" ** 126;
    try std.testing.expect(extractJsonInt("{}", long_key) == null);
}

// ── serializeTorrentInfo tests ───────────────────────────

test "serializeTorrentInfo produces valid JSON object" {
    const allocator = std.testing.allocator;
    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    const stat = TorrentSession.Stats{
        .state = .downloading,
        .progress = 0.5,
        .download_speed = 1024000,
        .upload_speed = 512000,
        .pieces_have = 50,
        .pieces_total = 100,
        .total_size = 1048576,
        .bytes_downloaded = 524288,
        .bytes_uploaded = 262144,
        .peers_connected = 5,
        .name = "test_torrent",
        .info_hash_hex = "abcdef0123456789abcdef0123456789abcdef01".*,
        .save_path = "/downloads",
        .added_on = 1000000,
    };

    try serializeTorrentInfo(allocator, &json, stat);

    const body = json.items;
    // Must start with { and end with }
    try std.testing.expect(body.len > 0);
    try std.testing.expectEqual(@as(u8, '{'), body[0]);
    try std.testing.expectEqual(@as(u8, '}'), body[body.len - 1]);

    // Must contain required qBittorrent fields
    try std.testing.expect(std.mem.indexOf(u8, body, "\"name\":\"test_torrent\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"hash\":\"abcdef0123456789abcdef0123456789abcdef01\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"state\":\"downloading\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"progress\":0.5000") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"dlspeed\":1024000") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"upspeed\":512000") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"total_size\":1048576") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"save_path\":\"/downloads\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content_path\":\"/downloads/test_torrent\"") != null);
}

test "serializeTorrentInfo maps completed torrent state to uploading" {
    const allocator = std.testing.allocator;
    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    const stat = TorrentSession.Stats{
        .state = .downloading,
        .progress = 1.0,
        .name = "completed_torrent",
        .info_hash_hex = "1111111111111111111111111111111111111111".*,
        .save_path = "/data",
    };

    try serializeTorrentInfo(allocator, &json, stat);
    const body = json.items;

    // Progress 1.0 + downloading state -> "uploading" per qBittorrent compat
    try std.testing.expect(std.mem.indexOf(u8, body, "\"state\":\"uploading\"") != null);
    // completion_on should be set (not -1) when progress >= 1.0
    try std.testing.expect(std.mem.indexOf(u8, body, "\"completion_on\":-1") == null);
}

test "serializeTorrentInfo includes seeding-related fields" {
    const allocator = std.testing.allocator;
    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    const stat = TorrentSession.Stats{
        .state = .seeding,
        .progress = 1.0,
        .sequential_download = true,
        .is_private = true,
        .super_seeding = true,
        .name = "private_torrent",
        .info_hash_hex = "2222222222222222222222222222222222222222".*,
        .save_path = "/data",
        .ratio = 2.5,
        .category = "movies",
        .tags = "hd,favorite",
    };

    try serializeTorrentInfo(allocator, &json, stat);
    const body = json.items;

    try std.testing.expect(std.mem.indexOf(u8, body, "\"seq_dl\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"private\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"super_seeding\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"category\":\"movies\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"tags\":\"hd,favorite\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"ratio\":2.5000") != null);
}

test "serializeTorrentInfo escapes special characters in name" {
    const allocator = std.testing.allocator;
    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    const stat = TorrentSession.Stats{
        .state = .downloading,
        .progress = 0.0,
        .name = "file \"with\" quotes",
        .info_hash_hex = "3333333333333333333333333333333333333333".*,
        .save_path = "/path/to/dir",
    };

    try serializeTorrentInfo(allocator, &json, stat);
    const body = json.items;

    // Quotes in name must be escaped for valid JSON
    try std.testing.expect(std.mem.indexOf(u8, body, "\\\"with\\\"") != null);
}

test "serializeTorrentInfo computes amount_left correctly" {
    const allocator = std.testing.allocator;
    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    const stat = TorrentSession.Stats{
        .state = .downloading,
        .progress = 0.75,
        .total_size = 1000,
        .bytes_downloaded = 750,
        .name = "partial",
        .info_hash_hex = "4444444444444444444444444444444444444444".*,
        .save_path = "/dl",
    };

    try serializeTorrentInfo(allocator, &json, stat);
    const body = json.items;

    // amount_left = total_size - bytes_downloaded = 250
    try std.testing.expect(std.mem.indexOf(u8, body, "\"amount_left\":250") != null);
}

test "serializeTorrentInfo includes v2 info hash when present" {
    const allocator = std.testing.allocator;
    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    var v2_hash: [32]u8 = undefined;
    for (&v2_hash, 0..) |*b, i| b.* = @intCast(i);

    const stat = TorrentSession.Stats{
        .state = .downloading,
        .progress = 0.0,
        .name = "v2_torrent",
        .info_hash_hex = "5555555555555555555555555555555555555555".*,
        .info_hash_v2 = v2_hash,
        .save_path = "/dl",
    };

    try serializeTorrentInfo(allocator, &json, stat);
    const body = json.items;

    // v2 hash should be the 64-char hex representation
    try std.testing.expect(std.mem.indexOf(u8, body, "\"infohash_v2\":\"000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f\"") != null);
}

test "serializeTorrentInfo omits v2 info hash for pure v1 torrent" {
    const allocator = std.testing.allocator;
    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    const stat = TorrentSession.Stats{
        .state = .downloading,
        .progress = 0.0,
        .name = "v1_torrent",
        .info_hash_hex = "6666666666666666666666666666666666666666".*,
        .info_hash_v2 = null,
        .save_path = "/dl",
    };

    try serializeTorrentInfo(allocator, &json, stat);
    const body = json.items;

    // v2 hash should be empty string for pure v1
    try std.testing.expect(std.mem.indexOf(u8, body, "\"infohash_v2\":\"\"") != null);
}

test "serializeTorrentInfo includes magnet_uri field" {
    const allocator = std.testing.allocator;
    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    const stat = TorrentSession.Stats{
        .state = .downloading,
        .progress = 0.0,
        .name = "magnet_test",
        .info_hash_hex = "7777777777777777777777777777777777777777".*,
        .save_path = "/dl",
        .tracker = "http://tracker.example.com/announce",
    };

    try serializeTorrentInfo(allocator, &json, stat);
    const body = json.items;

    // Must contain a magnet URI with the info hash
    try std.testing.expect(std.mem.indexOf(u8, body, "\"magnet_uri\":\"magnet:?xt=urn:btih:7777777777777777777777777777777777777777") != null);
}

test "serializeTorrentInfo includes queue position and share limits" {
    const allocator = std.testing.allocator;
    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    const stat = TorrentSession.Stats{
        .state = .queued,
        .progress = 0.3,
        .name = "queued_torrent",
        .info_hash_hex = "8888888888888888888888888888888888888888".*,
        .save_path = "/dl",
        .queue_position = 3,
        .ratio_limit = 1.5,
        .seeding_time_limit = 7200,
    };

    try serializeTorrentInfo(allocator, &json, stat);
    const body = json.items;

    try std.testing.expect(std.mem.indexOf(u8, body, "\"priority\":3") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"ratio_limit\":1.5000") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"seeding_time_limit\":7200") != null);
}

test "serializeTorrentInfo handles zero-size torrent" {
    const allocator = std.testing.allocator;
    var json = std.ArrayList(u8).empty;
    defer json.deinit(allocator);

    const stat = TorrentSession.Stats{
        .state = .downloading,
        .progress = 0.0,
        .total_size = 0,
        .bytes_downloaded = 0,
        .name = "empty",
        .info_hash_hex = "9999999999999999999999999999999999999999".*,
        .save_path = "/dl",
    };

    try serializeTorrentInfo(allocator, &json, stat);
    const body = json.items;

    // amount_left should be 0 when total_size is 0
    try std.testing.expect(std.mem.indexOf(u8, body, "\"amount_left\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"total_size\":0") != null);
}

test "enable_utp form param parsing" {
    try std.testing.expectEqualStrings("true", extractParam("enable_utp=true", "enable_utp").?);
    try std.testing.expectEqualStrings("false", extractParam("enable_utp=false", "enable_utp").?);
    try std.testing.expectEqualStrings("true", extractParam("pex=true&enable_utp=true&dht=false", "enable_utp").?);
}

test "enable_utp json bool parsing" {
    try std.testing.expectEqual(@as(?bool, true), extractJsonBool("{\"enable_utp\":true}", "enable_utp"));
    try std.testing.expectEqual(@as(?bool, false), extractJsonBool("{\"enable_utp\":false}", "enable_utp"));
    try std.testing.expectEqual(@as(?bool, true), extractJsonBool("{\"dht\":false,\"enable_utp\":true,\"pex\":true}", "enable_utp"));
}
