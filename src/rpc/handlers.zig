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

        const body = std.fmt.allocPrint(allocator, "{{\"connection_status\":\"connected\",\"dht_nodes\":0,\"dl_info_speed\":{},\"up_info_speed\":{},\"dl_info_data\":{},\"up_info_data\":{},\"dl_rate_limit\":{},\"up_rate_limit\":{}}}", .{ total_dl_speed, total_ul_speed, total_dl_data, total_ul_data, dl_limit, ul_limit }) catch
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
        const el = self.session_manager.shared_event_loop;
        const dl_limit: u64 = if (el) |e| e.getGlobalDlLimit() else 0;
        const ul_limit: u64 = if (el) |e| e.getGlobalUlLimit() else 0;
        const esc = json_mod.jsonSafe;
        const save_path = self.session_manager.default_save_path;

        // qBittorrent encryption: 0 = prefer, 1 = force, 2 = disable
        const enc_mode: u8 = if (el) |e| switch (e.encryption_mode) {
            .forced => 1,
            .preferred => 0,
            .enabled => 0,
            .disabled => 2,
        } else 0;

        const has_hpc = if (el) |e| e.huge_page_cache != null else false;
        const hpc_allocated = if (el) |e| (if (e.huge_page_cache) |*hpc| hpc.isAllocated() else false) else false;
        const hpc_using_huge = if (el) |e| (if (e.huge_page_cache) |hpc| hpc.using_huge_pages else false) else false;

        const body = std.fmt.allocPrint(allocator,
            \\{{"dl_limit":{},"up_limit":{},"alt_dl_limit":0,"alt_up_limit":0,
            \\"save_path":"{f}","temp_path":"","temp_path_enabled":false,
            \\"queueing_enabled":false,"max_active_downloads":-1,"max_active_torrents":-1,
            \\"max_active_uploads":-1,"max_active_checking_torrents":1,
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
            \\"max_ratio_enabled":false,"max_ratio":-1,
            \\"max_seeding_time_enabled":false,"max_seeding_time":-1,
            \\"auto_tmm_enabled":false,"save_resume_data_interval":60,
            \\"start_paused_enabled":false,
            \\"dht":false,"pex":false,"lsd":false,"encryption":{},"anonymous_mode":false,
            \\"piece_cache_enabled":{},"piece_cache_allocated":{},"piece_cache_huge_pages":{}}}
        , .{ dl_limit, ul_limit, esc(save_path), enc_mode, @as(u8, if (has_hpc) 1 else 0), @as(u8, if (hpc_allocated) 1 else 0), @as(u8, if (hpc_using_huge) 1 else 0) }) catch
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
        const seeding_time: i64 = if (info.state == .seeding) time_active else 0;
        const esc = json_mod.jsonSafe;

        var json = std.ArrayList(u8).empty;
        defer json.deinit(allocator);

        json.print(allocator, "{{\"save_path\":\"{f}\",\"download_path\":\"\",\"creation_date\":{},\"piece_size\":{},\"comment\":\"{f}\",\"created_by\":\"{f}\",\"total_size\":{},\"pieces_have\":{},\"pieces_num\":{},\"dl_speed\":{},\"dl_speed_avg\":0,\"up_speed\":{},\"up_speed_avg\":0,\"dl_limit\":{},\"up_limit\":{},\"eta\":{},\"hash\":\"{s}\",\"infohash_v1\":\"{s}\",\"infohash_v2\":\"\",\"name\":\"{f}\",\"ratio\":{d:.4},\"share_ratio\":{d:.4},\"time_elapsed\":{},\"time_active\":{},\"seeding_time\":{},\"nb_connections\":{},\"nb_connections_limit\":500,\"peers\":{},\"peers_total\":0,\"seeds\":0,\"seeds_total\":0,\"last_seen\":-1,\"reannounce\":0,\"addition_date\":{},\"completion_date\":-1,\"total_downloaded\":{},\"total_downloaded_session\":{},\"total_uploaded\":{},\"total_uploaded_session\":{},\"total_wasted\":0,\"is_private\":{s},\"seq_dl\":{s},\"super_seeding\":{}}}", .{
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
            esc(info.name),
            info.ratio,
            info.ratio,
            time_active,
            time_active,
            seeding_time,
            info.peers_connected,
            info.peers_connected,
            info.added_on,
            info.bytes_downloaded,
            info.bytes_downloaded,
            info.bytes_uploaded,
            info.bytes_uploaded,
            @as([]const u8, if (info.is_private) "true" else "false"),
            @as([]const u8, if (info.sequential_download) "true" else "false"),
            @as(u8, if (info.super_seeding) 1 else 0),
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
            json.print(allocator, "\"{f}\":{{\"client\":\"{f}\",\"connection\":\"\",\"country\":\"\",\"country_code\":\"\",\"dl_speed\":{},\"downloaded\":{},\"files\":\"\",\"flags\":\"{f}\",\"flags_desc\":\"\",\"ip\":\"{f}\",\"port\":{},\"progress\":{d:.4},\"relevance\":1,\"up_speed\":{},\"uploaded\":{}}}", .{
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
    try json.print(
        allocator,
        "{{\"name\":\"{f}\",\"hash\":\"{s}\",\"infohash_v1\":\"{s}\",\"infohash_v2\":\"\",\"state\":\"{s}\",\"size\":{},\"total_size\":{},\"progress\":{d:.4},\"dlspeed\":{},\"upspeed\":{},\"num_seeds\":{},\"num_leechs\":{},\"num_complete\":{},\"num_incomplete\":{},\"added_on\":{},\"completion_on\":{},\"save_path\":\"{f}\",\"content_path\":\"{f}\",\"download_path\":\"\",\"pieces_have\":{},\"pieces_num\":{},\"dl_limit\":{},\"up_limit\":{},\"eta\":{},\"ratio\":{d:.4},\"seq_dl\":{s},\"private\":{s}",
        .{
            esc(stat.name),
            stat.info_hash_hex,
            stat.info_hash_hex,
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
        ",\"f_l_piece_prio\":false,\"force_start\":false,\"super_seeding\":{s},\"auto_tmm\":false,\"category\":\"{f}\",\"tags\":\"{f}\",\"tracker\":\"{f}\",\"trackers_count\":{},\"amount_left\":{},\"completed\":{},\"downloaded\":{},\"downloaded_session\":{},\"uploaded\":{},\"uploaded_session\":{},\"time_active\":{},\"seeding_time\":{},\"last_activity\":{},\"seen_complete\":-1,\"priority\":0,\"availability\":-1,\"max_ratio\":-1,\"max_seeding_time\":-1,\"ratio_limit\":-1,\"seeding_time_limit\":-1,\"popularity\":0,\"magnet_uri\":\"{f}\",\"reannounce\":0}}",
        .{
            @as([]const u8, if (stat.super_seeding) "true" else "false"),
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
            @as(i64, if (stat.state == .seeding) time_active else 0),
            now,
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
