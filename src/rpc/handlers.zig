const std = @import("std");
const server = @import("server.zig");
const auth = @import("auth.zig");
const multipart = @import("multipart.zig");
const sync_mod = @import("sync.zig");
const json_mod = @import("json.zig");
const compat = @import("compat.zig");
const config_mod = @import("../config.zig");
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
    peer_sync_state: sync_mod.PeerSyncState,
    api_username: []const u8 = "admin",
    api_password: []const u8 = "adminadmin",

    /// Standard CORS headers attached to every API response.
    const cors_headers = "Access-Control-Allow-Origin: *\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nAccess-Control-Allow-Headers: Content-Type, Authorization\r\n";

    /// Wrap a response with CORS headers.
    fn withCors(resp: server.Response) server.Response {
        var r = resp;
        if (r.extra_headers == null) {
            r.extra_headers = cors_headers;
        }
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

        if (std.mem.eql(u8, request.path, "/api/v2/app/defaultSavePath")) {
            return withCors(self.handleDefaultSavePath());
        }

        if (std.mem.startsWith(u8, request.path, "/api/v2/app/shutdown") and std.mem.eql(u8, request.method, "POST")) {
            return withCors(self.handleShutdown(request.path, request.body));
        }

        if (std.mem.eql(u8, request.path, "/api/v2/transfer/info")) {
            return withCors(self.handleTransferInfo(allocator));
        }

        if (std.mem.eql(u8, request.path, "/api/v2/transfer/speedLimitsMode")) {
            return withCors(self.handleSpeedLimitsMode(allocator));
        }

        if (std.mem.eql(u8, request.path, "/api/v2/transfer/toggleSpeedLimitsMode") and std.mem.eql(u8, request.method, "POST")) {
            return withCors(self.handleToggleSpeedLimitsMode());
        }

        if (std.mem.eql(u8, request.path, "/api/v2/transfer/downloadLimit")) {
            return withCors(self.handleGlobalDlLimit(allocator));
        }

        if (std.mem.eql(u8, request.path, "/api/v2/transfer/uploadLimit")) {
            return withCors(self.handleGlobalUlLimit(allocator));
        }

        if (std.mem.eql(u8, request.path, "/api/v2/transfer/setDownloadLimit") and std.mem.eql(u8, request.method, "POST")) {
            return withCors(self.handleSetGlobalDlLimit(request.body));
        }

        if (std.mem.eql(u8, request.path, "/api/v2/transfer/setUploadLimit") and std.mem.eql(u8, request.method, "POST")) {
            return withCors(self.handleSetGlobalUlLimit(request.body));
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

        if (std.mem.startsWith(u8, request.path, "/api/v2/varuna/torrents/move")) {
            return withCors(self.handleVarunaMove(allocator, request.method, request.path, request.body));
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
        const username = extractParamMut(body, "username") orelse
            return withCors(.{ .status = 400, .body = "missing username" });
        const password = extractParamMut(body, "password") orelse
            return withCors(.{ .status = 400, .body = "missing password" });

        if (!std.mem.eql(u8, username, self.api_username) or !std.mem.eql(u8, password, self.api_password)) {
            return withCors(.{ .body = "Fails.", .content_type = "text/plain" });
        }

        // Pull the daemon-wide CSPRNG from the shared event loop. In
        // tests that build an ApiHandler without an event loop this
        // path is unreachable because login predates any RPC call,
        // but we defensively fall back to a freshly-seeded
        // realRandom() if the shared event loop is missing.
        const sid = if (self.session_manager.shared_event_loop) |el|
            self.session_store.createSession(&el.random)
        else blk: {
            var fallback = @import("../runtime/random.zig").Random.realRandom();
            break :blk self.session_store.createSession(&fallback);
        };
        const header = std.fmt.allocPrint(allocator, "Set-Cookie: SID={s}; HttpOnly; SameSite=Lax; path=/\r\n" ++ cors_headers, .{sid}) catch
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
        const info = self.session_manager.getTransferInfo(allocator) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };

        const body = std.fmt.allocPrint(allocator, "{{\"connection_status\":\"connected\",\"dht_nodes\":{},\"dl_info_speed\":{},\"up_info_speed\":{},\"dl_info_data\":{},\"up_info_data\":{},\"dl_rate_limit\":{},\"up_rate_limit\":{}}}", .{ info.dht_nodes, info.dl_speed, info.ul_speed, info.dl_data, info.ul_data, info.dl_limit, info.ul_limit }) catch
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
            return self.handleTorrentsInfo(allocator, params);
        }

        if (std.mem.eql(u8, action_name, "addTrackers") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsAddTrackers(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "add") and std.mem.eql(u8, method, "POST")) {
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

        if (std.mem.eql(u8, action_name, "rename") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsRename(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "toggleSequentialDownload") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsToggleSequentialDownload(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "setAutoManagement") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsSetAutoManagement();
        }

        if (std.mem.eql(u8, action_name, "setForceStart") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsSetForceStart(allocator, body);
        }

        if (std.mem.eql(u8, action_name, "pieceStates")) {
            return self.handleTorrentsPieceStates(allocator, params);
        }

        if (std.mem.eql(u8, action_name, "pieceHashes")) {
            return self.handleTorrentsPieceHashes(allocator, params);
        }

        if (std.mem.eql(u8, action_name, "renameFile") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsRenameFile();
        }

        if (std.mem.eql(u8, action_name, "renameFolder") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsRenameFolder();
        }

        if (std.mem.eql(u8, action_name, "export")) {
            return self.handleTorrentsExport(params);
        }

        if (std.mem.eql(u8, action_name, "addPeers") and std.mem.eql(u8, method, "POST")) {
            return self.handleTorrentsAddPeers(allocator, body);
        }

        return .{ .status = 404, .body = "{\"error\":\"unknown action\"}" };
    }

    fn handleTorrentsInfo(self: *const ApiHandler, allocator: std.mem.Allocator, params: []const u8) server.Response {
        const stats = self.session_manager.getAllStats(allocator) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        defer allocator.free(stats);

        var selected_hashes: ?[]const [40]u8 = null;
        if (requireHashes(params)) |hashes_param| {
            selected_hashes = resolveHashesOrAll(self, allocator, hashes_param) catch |err| {
                return hashSelectionErrorResponse(allocator, err);
            };
        }
        defer if (selected_hashes) |hashes| allocator.free(hashes);

        const filter = extractParamMut(params, "filter") orelse "all";
        const category = extractParamMut(params, "category");
        const tag = extractParamMut(params, "tag");
        const sort_key = extractParamMut(params, "sort");
        const reverse = parseBoolLoose(extractParamMut(params, "reverse") orelse "false");
        const limit = parseOptionalI64(params, "limit") orelse -1;
        const offset = parseOptionalI64(params, "offset") orelse 0;

        var filtered = std.ArrayList(TorrentSession.Stats).empty;
        defer filtered.deinit(allocator);
        for (stats) |stat| {
            if (!matchesHashSelection(selected_hashes, stat.info_hash_hex)) continue;
            if (!matchesInfoFilter(stat, filter)) continue;
            if (!matchesCategory(stat, category)) continue;
            if (!matchesTag(stat, tag)) continue;
            filtered.append(allocator, stat) catch return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        }

        if (sort_key) |key| {
            sortTorrentStats(filtered.items, key, reverse);
        }

        const window = pagedWindow(filtered.items.len, offset, limit);

        var json = std.ArrayList(u8).empty;
        defer json.deinit(allocator);

        json.append(allocator, '[') catch return .{ .status = 500, .body = "[]" };
        for (filtered.items[window.start..window.end], 0..) |stat, i| {
            if (i > 0) json.append(allocator, ',') catch {};
            serializeTorrentInfo(allocator, &json, stat) catch {};
        }
        json.append(allocator, ']') catch {};

        const body = json.toOwnedSlice(allocator) catch return .{ .status = 500, .body = "[]" };
        return .{ .body = body, .owned_body = body };
    }

    fn handleTorrentsAdd(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8, query: []const u8, content_type: ?[]const u8) server.Response {
        var torrent_data: []const u8 = body;
        var save_path: []const u8 = extractParamMut(query, "savepath") orelse self.session_manager.default_save_path;
        var category_param: ?[]const u8 = extractParamMut(query, "category");
        var magnet_url: ?[]const u8 = extractParamMut(query, "urls") orelse extractParamMut(body, "urls");

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
                category_param = extractParamMut(body, "category");
            }
        }

        // Handle magnet link (BEP 9)
        if (magnet_url) |magnet| {
            if (std.mem.startsWith(u8, magnet, "magnet:")) {
                const session = self.session_manager.addMagnet(magnet, save_path) catch |err| {
                    return errorResponse(allocator, 400, err);
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
            return errorResponse(allocator, 400, err);
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
        const hashes_param = requireHashes(body) orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const hashes = resolveHashesOrAll(self, allocator, hashes_param) catch |err| {
            return hashSelectionErrorResponse(allocator, err);
        };
        defer allocator.free(hashes);

        const delete_files = if (extractParamMut(body, "deleteFiles")) |v|
            std.mem.eql(u8, v, "true")
        else
            false;

        for (hashes) |hash| {
            self.session_manager.removeTorrentEx(hash[0..], delete_files) catch |err| {
                return errorResponse(allocator, 404, err);
            };
        }

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleTorrentsPause(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hashes_param = requireHashes(body) orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const hashes = resolveHashesOrAll(self, allocator, hashes_param) catch |err| {
            return hashSelectionErrorResponse(allocator, err);
        };
        defer allocator.free(hashes);

        for (hashes) |hash| {
            self.session_manager.pauseTorrent(hash[0..]) catch |err| {
                return errorResponse(allocator, 404, err);
            };
        }

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleTorrentsResume(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hashes_param = requireHashes(body) orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const hashes = resolveHashesOrAll(self, allocator, hashes_param) catch |err| {
            return hashSelectionErrorResponse(allocator, err);
        };
        defer allocator.free(hashes);

        for (hashes) |hash| {
            self.session_manager.resumeTorrent(hash[0..]) catch |err| {
                return errorResponse(allocator, 404, err);
            };
        }

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
            \\"outgoing_tcp":{s},"outgoing_utp":{s},"incoming_tcp":{s},"incoming_utp":{s},
            \\"transport_disposition":{},
            \\"piece_cache_enabled":{},
            \\"web_seed_max_request_bytes":{},
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
            @as([]const u8, if (el) |e| (if (e.transport_disposition.toEnableUtp()) "true" else "false") else "false"),
            @as([]const u8, if (el) |e| (if (e.transport_disposition.outgoing_tcp) "true" else "false") else "true"),
            @as([]const u8, if (el) |e| (if (e.transport_disposition.outgoing_utp) "true" else "false") else "false"),
            @as([]const u8, if (el) |e| (if (e.transport_disposition.incoming_tcp) "true" else "false") else "true"),
            @as([]const u8, if (el) |e| (if (e.transport_disposition.incoming_utp) "true" else "false") else "false"),
            if (el) |e| e.transport_disposition.toBitfield() else @as(u8, 15),
            @as(u8, if (piece_cache_enabled) 1 else 0),
            if (el) |e| e.web_seed_max_request_bytes else @as(u32, 4 * 1024 * 1024),
            esc(banned_ips_str),
        }) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .body = body, .owned_body = body };
    }

    fn handleSetPreferences(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const el = self.session_manager.shared_event_loop orelse
            return .{ .status = 500, .body = "{\"error\":\"no event loop\"}" };

        const trimmed_body = std.mem.trim(u8, body, " \t\r\n");
        const json_param = extractParamMut(body, "json");
        const expects_json = json_param != null or bodyLooksLikeJson(trimmed_body);

        if (expects_json) {
            const json_str = json_param orelse trimmed_body;
            const parsed = std.json.parseFromSlice(PreferencesUpdate, allocator, json_str, .{ .ignore_unknown_fields = true }) catch
                return .{ .status = 400, .body = "{\"error\":\"invalid preferences json\"}" };
            defer parsed.deinit();
            const prefs = parsed.value;

            // Speed limits
            if (prefs.dl_limit) |dl| el.setGlobalDlLimit(dl);
            if (prefs.up_limit) |ul| el.setGlobalUlLimit(ul);

            // Share ratio and seeding time limits
            {
                const sm = self.session_manager;
                if (prefs.max_ratio_enabled) |v| sm.max_ratio_enabled = v;
                if (prefs.max_ratio) |v| sm.max_ratio = v;
                if (prefs.max_ratio_act) |v| sm.max_ratio_act = @min(v, 1);
                if (prefs.max_seeding_time_enabled) |v| sm.max_seeding_time_enabled = v;
                if (prefs.max_seeding_time) |v| sm.max_seeding_time = v;
            }

            // Queue settings
            var queue_changed = false;
            if (prefs.queueing_enabled) |v| {
                self.session_manager.queue_manager.config.enabled = v;
                queue_changed = true;
            }
            if (prefs.max_active_downloads) |v| {
                self.session_manager.queue_manager.config.max_active_downloads = v;
                queue_changed = true;
            }
            if (prefs.max_active_uploads) |v| {
                self.session_manager.queue_manager.config.max_active_uploads = v;
                queue_changed = true;
            }
            if (prefs.max_active_torrents) |v| {
                self.session_manager.queue_manager.config.max_active_torrents = v;
                queue_changed = true;
            }
            if (queue_changed) self.session_manager.runQueueEnforcement();

            // DHT / PEX / uTP toggles
            if (prefs.dht) |v| self.session_manager.setDhtEnabled(v);
            if (prefs.pex) |v| el.pex_enabled = v;

            // Granular transport disposition fields take precedence
            if (prefs.outgoing_tcp) |v| el.transport_disposition.outgoing_tcp = v;
            if (prefs.outgoing_utp) |v| el.transport_disposition.outgoing_utp = v;
            if (prefs.incoming_tcp) |v| el.transport_disposition.incoming_tcp = v;
            if (prefs.incoming_utp) |v| el.transport_disposition.incoming_utp = v;
            if (prefs.transport_disposition) |v| el.transport_disposition = config_mod.TransportDisposition.fromBitfield(v);

            // Legacy enable_utp: only apply if no granular fields were set
            if (prefs.enable_utp) |v| {
                if (prefs.outgoing_tcp == null and prefs.outgoing_utp == null and
                    prefs.incoming_tcp == null and prefs.incoming_utp == null and
                    prefs.transport_disposition == null)
                {
                    el.transport_disposition = config_mod.TransportDisposition.fromEnableUtp(v);
                }
            }

            // Web seed batching limit
            if (prefs.web_seed_max_request_bytes) |v| el.web_seed_max_request_bytes = v;

            // Reconcile listeners: start/stop UDP listener as needed
            el.reconcileListeners();
        } else {
            if (extractParamMut(body, "dl_limit")) |dl_str| {
                const dl = std.fmt.parseInt(u64, dl_str, 10) catch
                    return .{ .status = 400, .body = "{\"error\":\"invalid dl_limit\"}" };
                el.setGlobalDlLimit(dl);
            }
            if (extractParamMut(body, "up_limit")) |ul_str| {
                const ul = std.fmt.parseInt(u64, ul_str, 10) catch
                    return .{ .status = 400, .body = "{\"error\":\"invalid up_limit\"}" };
                el.setGlobalUlLimit(ul);
            }

            {
                const sm = self.session_manager;
                if (extractParamMut(body, "max_ratio_enabled")) |v| sm.max_ratio_enabled = parseBoolPreference(v) catch
                    return .{ .status = 400, .body = "{\"error\":\"invalid max_ratio_enabled\"}" };
                if (extractParamMut(body, "max_ratio")) |v| sm.max_ratio = std.fmt.parseFloat(f64, v) catch
                    return .{ .status = 400, .body = "{\"error\":\"invalid max_ratio\"}" };
                if (extractParamMut(body, "max_ratio_act")) |v| sm.max_ratio_act = std.fmt.parseInt(u8, v, 10) catch
                    return .{ .status = 400, .body = "{\"error\":\"invalid max_ratio_act\"}" };
                if (extractParamMut(body, "max_seeding_time_enabled")) |v| sm.max_seeding_time_enabled = parseBoolPreference(v) catch
                    return .{ .status = 400, .body = "{\"error\":\"invalid max_seeding_time_enabled\"}" };
                if (extractParamMut(body, "max_seeding_time")) |v| sm.max_seeding_time = std.fmt.parseInt(i64, v, 10) catch
                    return .{ .status = 400, .body = "{\"error\":\"invalid max_seeding_time\"}" };
            }

            var queue_changed = false;
            if (extractParamMut(body, "queueing_enabled")) |val| {
                self.session_manager.queue_manager.config.enabled = parseBoolPreference(val) catch
                    return .{ .status = 400, .body = "{\"error\":\"invalid queueing_enabled\"}" };
                queue_changed = true;
            }
            if (extractParamMut(body, "max_active_downloads")) |val| {
                const v = std.fmt.parseInt(i32, val, 10) catch
                    return .{ .status = 400, .body = "{\"error\":\"invalid max_active_downloads\"}" };
                self.session_manager.queue_manager.config.max_active_downloads = v;
                queue_changed = true;
            }
            if (extractParamMut(body, "max_active_uploads")) |val| {
                const v = std.fmt.parseInt(i32, val, 10) catch
                    return .{ .status = 400, .body = "{\"error\":\"invalid max_active_uploads\"}" };
                self.session_manager.queue_manager.config.max_active_uploads = v;
                queue_changed = true;
            }
            if (extractParamMut(body, "max_active_torrents")) |val| {
                const v = std.fmt.parseInt(i32, val, 10) catch
                    return .{ .status = 400, .body = "{\"error\":\"invalid max_active_torrents\"}" };
                self.session_manager.queue_manager.config.max_active_torrents = v;
                queue_changed = true;
            }
            if (queue_changed) self.session_manager.runQueueEnforcement();

            if (extractParamMut(body, "dht")) |v| self.session_manager.setDhtEnabled(parseBoolPreference(v) catch
                return .{ .status = 400, .body = "{\"error\":\"invalid dht\"}" });
            if (extractParamMut(body, "pex")) |v| el.pex_enabled = parseBoolPreference(v) catch
                return .{ .status = 400, .body = "{\"error\":\"invalid pex\"}" };

            // Granular transport disposition fields
            var has_granular_transport = false;
            if (extractParamMut(body, "outgoing_tcp")) |v| {
                el.transport_disposition.outgoing_tcp = parseBoolPreference(v) catch
                    return .{ .status = 400, .body = "{\"error\":\"invalid outgoing_tcp\"}" };
                has_granular_transport = true;
            }
            if (extractParamMut(body, "outgoing_utp")) |v| {
                el.transport_disposition.outgoing_utp = parseBoolPreference(v) catch
                    return .{ .status = 400, .body = "{\"error\":\"invalid outgoing_utp\"}" };
                has_granular_transport = true;
            }
            if (extractParamMut(body, "incoming_tcp")) |v| {
                el.transport_disposition.incoming_tcp = parseBoolPreference(v) catch
                    return .{ .status = 400, .body = "{\"error\":\"invalid incoming_tcp\"}" };
                has_granular_transport = true;
            }
            if (extractParamMut(body, "incoming_utp")) |v| {
                el.transport_disposition.incoming_utp = parseBoolPreference(v) catch
                    return .{ .status = 400, .body = "{\"error\":\"invalid incoming_utp\"}" };
                has_granular_transport = true;
            }
            if (extractParamMut(body, "transport_disposition")) |v| {
                const bitfield = std.fmt.parseInt(u8, v, 10) catch
                    return .{ .status = 400, .body = "{\"error\":\"invalid transport_disposition\"}" };
                el.transport_disposition = config_mod.TransportDisposition.fromBitfield(bitfield);
                has_granular_transport = true;
            }

            // Legacy enable_utp: only apply if no granular fields were set
            if (!has_granular_transport) {
                if (extractParamMut(body, "enable_utp")) |v| {
                    const enable = parseBoolPreference(v) catch
                        return .{ .status = 400, .body = "{\"error\":\"invalid enable_utp\"}" };
                    el.transport_disposition = config_mod.TransportDisposition.fromEnableUtp(enable);
                }
            }

            // Web seed batching limit
            if (extractParamMut(body, "web_seed_max_request_bytes")) |v| {
                el.web_seed_max_request_bytes = std.fmt.parseInt(u32, v, 10) catch
                    return .{ .status = 400, .body = "{\"error\":\"invalid web_seed_max_request_bytes\"}" };
            }

            // Reconcile listeners: start/stop UDP listener as needed
            el.reconcileListeners();
        }

        // Handle banned_IPs: newline-separated list of IPs and CIDRs (form-encoded only)
        if (extractParamMut(body, "banned_IPs")) |banned_str| {
            if (self.session_manager.ban_list) |bl| {
                bl.setBannedIpsFromString(banned_str) catch
                    return .{ .status = 400, .body = "{\"error\":\"invalid banned_IPs\"}" };
                el.ban_list_dirty.store(true, .release);
                self.session_manager.persistBanList();
            }
        }

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleSpeedLimitsMode(_: *const ApiHandler, _: std.mem.Allocator) server.Response {
        // qBittorrent uses 0 = normal, 1 = alternative limits active.
        // We always report 0 (no alternative mode).
        return .{ .body = "0" };
    }

    fn handleSetTorrentDlLimit(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hashes_param = requireHashes(body) orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const hashes = resolveHashesOrAll(self, allocator, hashes_param) catch |err| {
            return hashSelectionErrorResponse(allocator, err);
        };
        defer allocator.free(hashes);
        const limit_str = extractParamMut(body, "limit") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing limit\"}" };
        const limit = std.fmt.parseInt(u64, limit_str, 10) catch
            return .{ .status = 400, .body = "{\"error\":\"invalid limit\"}" };

        for (hashes) |hash| {
            self.session_manager.setTorrentDlLimit(hash[0..], limit) catch |err| {
                return errorResponse(allocator, 404, err);
            };
        }
        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleSetTorrentUlLimit(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hashes_param = requireHashes(body) orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const hashes = resolveHashesOrAll(self, allocator, hashes_param) catch |err| {
            return hashSelectionErrorResponse(allocator, err);
        };
        defer allocator.free(hashes);
        const limit_str = extractParamMut(body, "limit") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing limit\"}" };
        const limit = std.fmt.parseInt(u64, limit_str, 10) catch
            return .{ .status = 400, .body = "{\"error\":\"invalid limit\"}" };

        for (hashes) |hash| {
            self.session_manager.setTorrentUlLimit(hash[0..], limit) catch |err| {
                return errorResponse(allocator, 404, err);
            };
        }
        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleGetTorrentDlLimit(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = requireHashes(body) orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };

        const stats = self.session_manager.getStats(hash) catch
            return .{ .status = 404, .body = "{\"error\":\"torrent not found\"}" };

        const resp = std.fmt.allocPrint(allocator, "{}", .{stats.dl_limit}) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .body = resp, .owned_body = resp };
    }

    fn handleGetTorrentUlLimit(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = requireHashes(body) orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };

        const stats = self.session_manager.getStats(hash) catch
            return .{ .status = 404, .body = "{\"error\":\"torrent not found\"}" };

        const resp = std.fmt.allocPrint(allocator, "{}", .{stats.ul_limit}) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .body = resp, .owned_body = resp };
    }

    // ── New endpoints ────────────────────────────────────

    fn handleTorrentsFiles(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParamMut(body, "hash") orelse
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
        const hash = extractParamMut(body, "hash") orelse
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
        const hash = extractParamMut(body, "hash") orelse
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

        const v2_hex = compat.formatInfoHashV2(info.info_hash_v2);
        const v2_str: []const u8 = if (v2_hex) |*hex| hex else "";
        const completion_date: i64 = if (info.completion_on > 0) info.completion_on else if (info.state == .seeding) info.added_on else -1;

        var json = std.ArrayList(u8).empty;
        defer json.deinit(allocator);

        // Split into two print calls to stay under Zig's 32-argument format limit
        json.print(allocator, "{{\"save_path\":\"{f}\",\"download_path\":\"\",\"creation_date\":{},\"piece_size\":{},\"comment\":\"{f}\",\"created_by\":\"{f}\",\"total_size\":{},\"pieces_have\":{},\"pieces_num\":{},\"dl_speed\":{},\"dl_speed_avg\":0,\"up_speed\":{},\"up_speed_avg\":0,\"dl_limit\":{},\"up_limit\":{},\"eta\":{},\"hash\":\"{s}\",\"infohash_v1\":\"{s}\",\"infohash_v2\":\"{s}\",\"name\":\"{f}\",\"ratio\":{d:.4},\"share_ratio\":{d:.4},\"time_elapsed\":{},\"time_active\":{},\"seeding_time\":{},\"nb_connections\":{},\"nb_connections_limit\":500,", .{
            esc(info.save_path),
            info.creation_date orelse -1,
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
        const hash = extractParamMut(body, "hash") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" };
        const id_str = extractParamMut(body, "id") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing id\"}" };
        const prio_str = extractParamMut(body, "priority") orelse
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
            return errorResponse(allocator, 404, err);
        };

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleTorrentsSetSequentialDownload(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hashes_param = requireHashes(body) orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const hashes = resolveHashesOrAll(self, allocator, hashes_param) catch |err| {
            return hashSelectionErrorResponse(allocator, err);
        };
        defer allocator.free(hashes);
        const value_str = extractParamMut(body, "value") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing value\"}" };

        const enabled = std.mem.eql(u8, value_str, "true");

        for (hashes) |hash| {
            self.session_manager.setSequentialDownload(hash[0..], enabled) catch |err| {
                return errorResponse(allocator, 404, err);
            };
        }

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleTorrentsSetSuperSeeding(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hashes_param = requireHashes(body) orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" };
        const hashes = resolveHashesOrAll(self, allocator, hashes_param) catch |err| {
            return hashSelectionErrorResponse(allocator, err);
        };
        defer allocator.free(hashes);
        const value_str = extractParamMut(body, "value") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing value\"}" };

        const enabled = std.mem.eql(u8, value_str, "true");

        for (hashes) |hash| {
            self.session_manager.setSuperSeeding(hash[0..], enabled) catch |err| {
                return errorResponse(allocator, 404, err);
            };
        }

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    // ── Tracker editing handlers ────────────────────────────

    fn handleTorrentsAddTrackers(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParamMut(body, "hash") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" };
        const urls_str = extractParamMut(body, "urls") orelse
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
            return errorResponse(allocator, 404, err);
        };

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleTorrentsRemoveTrackers(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParamMut(body, "hash") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" };
        const urls_str = extractParamMut(body, "urls") orelse
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
            return errorResponse(allocator, 404, err);
        };

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleTorrentsEditTracker(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParamMut(body, "hash") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" };
        const orig_url = extractParamMut(body, "origUrl") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing origUrl\"}" };
        const new_url = extractParamMut(body, "newUrl") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing newUrl\"}" };

        self.session_manager.editTracker(hash, orig_url, new_url) catch |err| {
            return errorResponse(allocator, 404, err);
        };

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleTorrentsForceReannounce(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hashes_param = requireHashes(body) orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const hashes = resolveHashesOrAll(self, allocator, hashes_param) catch |err| {
            return hashSelectionErrorResponse(allocator, err);
        };
        defer allocator.free(hashes);

        for (hashes) |hash| {
            self.session_manager.forceReannounce(hash[0..]) catch |err| {
                return errorResponse(allocator, 404, err);
            };
        }

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleTorrentsRecheck(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hashes_param = requireHashes(body) orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const hashes = resolveHashesOrAll(self, allocator, hashes_param) catch |err| {
            return hashSelectionErrorResponse(allocator, err);
        };
        defer allocator.free(hashes);

        for (hashes) |hash| {
            self.session_manager.forceRecheck(hash[0..]) catch |err| {
                return errorResponse(allocator, 404, err);
            };
        }

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    /// **Deprecated.** The qBittorrent-compatible setLocation API
    /// returns synchronously after the move completes — that contract
    /// can hold the RPC handler thread for arbitrary time on
    /// cross-filesystem moves of multi-GB torrent data. Varuna refuses
    /// to honour it and points clients at the new async endpoint
    /// (`POST /api/v2/varuna/torrents/move`) which returns a job id
    /// immediately and exposes progress polling through
    /// `GET /api/v2/varuna/torrents/move/<id>`. See
    /// `docs/api-compatibility.md` for the full rationale.
    fn handleTorrentsSetLocation(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        _ = self;
        _ = allocator;
        _ = body;
        return .{
            .status = 400,
            .body = "{\"error\":\"setLocation is synchronous in qBittorrent's API; varuna requires async. Use POST /api/v2/varuna/torrents/move instead.\",\"endpoint\":\"/api/v2/varuna/torrents/move\"}",
        };
    }

    /// Varuna-native async move endpoint. Routes:
    ///
    ///   POST   /api/v2/varuna/torrents/move           — start a move
    ///   GET    /api/v2/varuna/torrents/move/<id>      — poll progress
    ///   POST   /api/v2/varuna/torrents/move/<id>/cancel  — request cancel
    ///   POST   /api/v2/varuna/torrents/move/<id>/commit  — apply save_path
    ///   DELETE /api/v2/varuna/torrents/move/<id>      — forget terminal job
    ///
    /// The path uses the `/varuna/` prefix to make it unambiguously
    /// non-qBittorrent (clients reaching it have explicitly opted in).
    fn handleVarunaMove(self: *const ApiHandler, allocator: std.mem.Allocator, method: []const u8, path: []const u8, body: []const u8) server.Response {
        const prefix = "/api/v2/varuna/torrents/move";
        const tail = path[prefix.len..];

        // POST /move (no id) → start
        if (tail.len == 0) {
            if (!std.mem.eql(u8, method, "POST")) {
                return .{ .status = 405, .body = "{\"error\":\"method not allowed\"}" };
            }
            return self.handleVarunaMoveStart(allocator, body);
        }

        // tail begins with `/<id>`. Strip the leading slash.
        if (tail[0] != '/') {
            return .{ .status = 404, .body = "{\"error\":\"not found\"}" };
        }
        const after_slash = tail[1..];

        // Split into id and optional sub-action.
        const sub_sep = std.mem.indexOfScalar(u8, after_slash, '/');
        const id_str = if (sub_sep) |s| after_slash[0..s] else after_slash;
        const sub = if (sub_sep) |s| after_slash[s + 1 ..] else "";

        const id = std.fmt.parseInt(@import("../daemon/session_manager.zig").MoveJobId, id_str, 10) catch
            return .{ .status = 400, .body = "{\"error\":\"invalid job id\"}" };

        if (sub.len == 0) {
            if (std.mem.eql(u8, method, "GET")) return self.handleVarunaMoveStatus(allocator, id);
            if (std.mem.eql(u8, method, "DELETE")) return self.handleVarunaMoveForget(allocator, id);
            return .{ .status = 405, .body = "{\"error\":\"method not allowed\"}" };
        }

        if (std.mem.eql(u8, sub, "cancel")) {
            if (!std.mem.eql(u8, method, "POST")) {
                return .{ .status = 405, .body = "{\"error\":\"method not allowed\"}" };
            }
            return self.handleVarunaMoveCancel(allocator, id);
        }
        if (std.mem.eql(u8, sub, "commit")) {
            if (!std.mem.eql(u8, method, "POST")) {
                return .{ .status = 405, .body = "{\"error\":\"method not allowed\"}" };
            }
            return self.handleVarunaMoveCommit(allocator, id);
        }
        return .{ .status = 404, .body = "{\"error\":\"not found\"}" };
    }

    fn handleVarunaMoveStart(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = requireHashes(body) orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const location = extractParamMut(body, "location") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing location\"}" };
        if (location.len == 0) {
            return .{ .status = 400, .body = "{\"error\":\"empty location\"}" };
        }

        const id = self.session_manager.startMoveJob(hash, location) catch |err| {
            // Map domain errors to specific status codes.
            return switch (err) {
                error.TorrentNotFound => .{ .status = 404, .body = "{\"error\":\"torrent not found\"}" },
                error.TorrentBusy => .{ .status = 409, .body = "{\"error\":\"torrent already has a pending move\"}" },
                error.SrcPathNotAbsolute, error.DstPathNotAbsolute => .{
                    .status = 400,
                    .body = "{\"error\":\"paths must be absolute\"}",
                },
                else => errorResponse(allocator, 500, err),
            };
        };

        const body_out = std.fmt.allocPrint(allocator, "{{\"id\":{}}}", .{id}) catch
            return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .status = 202, .body = body_out, .owned_body = body_out };
    }

    fn handleVarunaMoveStatus(self: *const ApiHandler, allocator: std.mem.Allocator, id: @import("../daemon/session_manager.zig").MoveJobId) server.Response {
        const p = self.session_manager.getMoveJobProgress(id) catch |err| {
            return switch (err) {
                error.JobNotFound => .{ .status = 404, .body = "{\"error\":\"job not found\"}" },
            };
        };

        const state_str = switch (p.state) {
            .created => "created",
            .running => "running",
            .succeeded => "succeeded",
            .failed => "failed",
            .canceled => "canceled",
        };
        const err_str: []const u8 = if (p.error_message) |m| m else "";

        const body = std.fmt.allocPrint(
            allocator,
            "{{\"id\":{},\"state\":\"{s}\",\"bytes_copied\":{},\"total_bytes\":{},\"files_done\":{},\"total_files\":{},\"used_rename\":{},\"error\":\"{s}\"}}",
            .{ id, state_str, p.bytes_copied, p.total_bytes, p.files_done, p.total_files, p.used_rename, err_str },
        ) catch return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
        return .{ .body = body, .owned_body = body };
    }

    fn handleVarunaMoveCancel(self: *const ApiHandler, allocator: std.mem.Allocator, id: @import("../daemon/session_manager.zig").MoveJobId) server.Response {
        _ = allocator;
        self.session_manager.cancelMoveJob(id) catch |err| {
            return switch (err) {
                error.JobNotFound => .{ .status = 404, .body = "{\"error\":\"job not found\"}" },
            };
        };
        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleVarunaMoveCommit(self: *const ApiHandler, allocator: std.mem.Allocator, id: @import("../daemon/session_manager.zig").MoveJobId) server.Response {
        self.session_manager.commitMoveJob(id) catch |err| {
            return switch (err) {
                error.JobNotFound => .{ .status = 404, .body = "{\"error\":\"job not found\"}" },
                error.JobNotFinished => .{ .status = 409, .body = "{\"error\":\"job not yet succeeded\"}" },
                error.TorrentNotFound => .{ .status = 410, .body = "{\"error\":\"torrent removed before commit\"}" },
                error.OutOfMemory => errorResponse(allocator, 500, err),
            };
        };
        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleVarunaMoveForget(self: *const ApiHandler, allocator: std.mem.Allocator, id: @import("../daemon/session_manager.zig").MoveJobId) server.Response {
        _ = allocator;
        self.session_manager.forgetMoveJob(id) catch |err| {
            return switch (err) {
                error.JobNotFound => .{ .status = 404, .body = "{\"error\":\"job not found\"}" },
                error.JobStillRunning => .{ .status = 409, .body = "{\"error\":\"cancel first; job is still running\"}" },
            };
        };
        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleTorrentsConnDiagnostics(self: *const ApiHandler, allocator: std.mem.Allocator, params: []const u8) server.Response {
        const hash = extractParamMut(params, "hash") orelse
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
        const hashes_param = requireHashes(body) orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const hashes = resolveHashesOrAll(self, allocator, hashes_param) catch |err| {
            return hashSelectionErrorResponse(allocator, err);
        };
        defer allocator.free(hashes);

        // Parse ratio limit (-2 = use global, -1 = no limit, >=0 = specific)
        const ratio_limit: f64 = if (extractParamMut(body, "ratioLimit")) |v|
            std.fmt.parseFloat(f64, v) catch -2.0
        else
            -2.0;

        // Parse seeding time limit in minutes (-2 = use global, -1 = no limit, >=0 = minutes)
        const seeding_time_limit: i64 = if (extractParamMut(body, "seedingTimeLimit")) |v|
            std.fmt.parseInt(i64, v, 10) catch -2
        else
            -2;

        for (hashes) |hash| {
            self.session_manager.setShareLimits(hash[0..], ratio_limit, seeding_time_limit) catch |err| {
                return errorResponse(allocator, 404, err);
            };
        }
        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleTorrentsWebSeeds(self: *const ApiHandler, allocator: std.mem.Allocator, params: []const u8) server.Response {
        const hash = extractParamMut(params, "hash") orelse
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
        const name = extractParamMut(params, "category") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing category\"}" };
        const save_path = extractParamMut(params, "savePath") orelse "";

        self.session_manager.mutex.lock();
        defer self.session_manager.mutex.unlock();

        self.session_manager.category_store.create(name, save_path) catch |err| {
            return errorResponse(allocator, 409, err);
        };

        // Persist to DB
        if (self.session_manager.resume_db) |*db| db.saveCategory(name, save_path) catch {};

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleRemoveCategories(self: *const ApiHandler, params: []const u8) server.Response {
        const names = extractParamMut(params, "categories") orelse
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
        const name = extractParamMut(params, "category") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing category\"}" };
        const save_path = extractParamMut(params, "savePath") orelse "";

        self.session_manager.mutex.lock();
        defer self.session_manager.mutex.unlock();

        self.session_manager.category_store.edit(name, save_path) catch |err| {
            return errorResponse(allocator, 409, err);
        };

        // Persist to DB (saveCategory upserts)
        if (self.session_manager.resume_db) |*db| db.saveCategory(name, save_path) catch {};

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleSetCategory(self: *const ApiHandler, allocator: std.mem.Allocator, params: []const u8) server.Response {
        const hashes_param = requireHashes(params) orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const hashes = resolveHashesOrAll(self, allocator, hashes_param) catch |err| {
            return hashSelectionErrorResponse(allocator, err);
        };
        defer allocator.free(hashes);
        const category = extractParamMut(params, "category") orelse "";

        for (hashes) |hash| {
            self.session_manager.setTorrentCategory(hash[0..], category) catch |err| {
                return errorResponse(allocator, 404, err);
            };
        }

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
        const tags_str = extractParamMut(params, "tags") orelse
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
        const tags_str = extractParamMut(params, "tags") orelse
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
        const hashes_param = requireHashes(params) orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const hashes = resolveHashesOrAll(self, allocator, hashes_param) catch |err| {
            return hashSelectionErrorResponse(allocator, err);
        };
        defer allocator.free(hashes);
        const tags_str = extractParamMut(params, "tags") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing tags\"}" };

        for (hashes) |hash| {
            self.session_manager.addTorrentTags(hash[0..], tags_str) catch |err| {
                return errorResponse(allocator, 404, err);
            };
        }

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleRemoveTags(self: *const ApiHandler, allocator: std.mem.Allocator, params: []const u8) server.Response {
        const hashes_param = requireHashes(params) orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const hashes = resolveHashesOrAll(self, allocator, hashes_param) catch |err| {
            return hashSelectionErrorResponse(allocator, err);
        };
        defer allocator.free(hashes);
        const tags_str = extractParamMut(params, "tags") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing tags\"}" };

        for (hashes) |hash| {
            self.session_manager.removeTorrentTags(hash[0..], tags_str) catch |err| {
                return errorResponse(allocator, 404, err);
            };
        }

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    fn handleSyncTorrentPeers(self: *ApiHandler, allocator: std.mem.Allocator, path: []const u8) server.Response {
        // Parse hash from query string: /api/v2/sync/torrentPeers?hash=...&rid=...
        var hash: ?[]const u8 = null;
        var request_rid: u64 = 0;
        if (std.mem.indexOf(u8, path, "?")) |q| {
            const query = path[q + 1 ..];
            hash = extractParamMut(query, "hash");
            if (extractParamMut(query, "rid")) |rid_str| {
                request_rid = std.fmt.parseInt(u64, rid_str, 10) catch 0;
            }
        }

        const hash_val = hash orelse
            return .{ .body = "{\"rid\":1,\"full_update\":true,\"peers\":{}}" };

        const body = self.peer_sync_state.computeDelta(self.session_manager, allocator, hash_val, request_rid) catch
            return .{ .body = "{\"rid\":1,\"full_update\":true,\"peers\":{}}" };
        return .{ .body = body, .owned_body = body };
    }

    fn handleSyncMaindata(self: *ApiHandler, allocator: std.mem.Allocator, path: []const u8) server.Response {
        // Parse rid from query string: /api/v2/sync/maindata?rid=N
        var request_rid: u64 = 0;
        if (std.mem.indexOf(u8, path, "?")) |q| {
            const query = path[q + 1 ..];
            if (extractParamMut(query, "rid")) |rid_str| {
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

    // ── Ban management handlers ────────────────────────────

    /// POST /api/v2/transfer/banPeers -- qBittorrent-compatible ban endpoint.
    /// peers=ip:port|ip:port|... (pipe-separated)
    fn handleBanPeers(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        _ = allocator;
        const bl = self.session_manager.ban_list orelse
            return .{ .status = 500, .body = "{\"error\":\"ban list not initialized\"}" };

        const peers_str = extractParamMut(body, "peers") orelse
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

        const ips_str = extractParamMut(body, "ips") orelse
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
        const file_data: []const u8 = extractParamMut(body, "file") orelse body;

        // Determine format from form-encoded format= parameter
        const format_str = extractParamMut(body, "format") orelse "auto";
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
        const hashes_param = requireHashes(body) orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const hashes = resolveHashesOrAll(self, allocator, hashes_param) catch |err| {
            return hashSelectionErrorResponse(allocator, err);
        };
        defer allocator.free(hashes);

        for (hashes) |hash| {
            const result = switch (action) {
                .increase => self.session_manager.queueIncreasePrio(hash[0..]),
                .decrease => self.session_manager.queueDecreasePrio(hash[0..]),
                .top => self.session_manager.queueTopPrio(hash[0..]),
                .bottom => self.session_manager.queueBottomPrio(hash[0..]),
            };
            result catch |err| {
                return errorResponse(allocator, 404, err);
            };
        }

        return .{ .body = "{\"status\":\"ok\"}" };
    }

    // ── New API endpoints ───────────────────────────────────

    /// GET /api/v2/app/defaultSavePath -- return the default save path as plain text.
    fn handleDefaultSavePath(self: *const ApiHandler) server.Response {
        return .{ .body = self.session_manager.default_save_path, .content_type = "text/plain" };
    }

    /// POST /api/v2/app/shutdown -- initiate graceful daemon shutdown.
    ///
    /// Accepts an optional `timeout` parameter (seconds) from either the
    /// request body (form-encoded) or the query string. When omitted, the
    /// daemon's configured `shutdown_timeout` is used. A timeout of 0 means
    /// immediate shutdown with no drain period.
    ///
    /// Sets the event loop into draining mode and requests shutdown so the
    /// main loop exits after in-flight transfers complete (or the deadline
    /// passes). Returns 200 immediately; the actual exit happens
    /// asynchronously.
    fn handleShutdown(self: *const ApiHandler, path: []const u8, body: []const u8) server.Response {
        const signal = @import("../io/signal.zig");
        const el = self.session_manager.shared_event_loop orelse {
            // No event loop -- just request shutdown directly
            signal.requestShutdown();
            return .{ .body = "Ok.", .content_type = "text/plain" };
        };

        // Parse optional timeout from body or query string
        const timeout_str = extractParamMut(body, "timeout") orelse blk: {
            if (std.mem.indexOf(u8, path, "?")) |q| {
                break :blk extractParamMut(path[q + 1 ..], "timeout");
            }
            break :blk null;
        };

        const timeout: u32 = if (timeout_str) |s|
            std.fmt.parseInt(u32, s, 10) catch
                return .{ .status = 400, .body = "{\"error\":\"invalid timeout\"}" }
        else
            el.shutdown_timeout;

        if (timeout == 0) {
            // Immediate shutdown, no drain
            el.running = false;
            signal.requestShutdown();
        } else {
            el.draining = true;
            el.drain_deadline = std.time.timestamp() + @as(i64, @intCast(timeout));
            signal.requestShutdown();
        }

        return .{ .body = "Ok.", .content_type = "text/plain" };
    }

    /// POST /api/v2/transfer/toggleSpeedLimitsMode — 501 Not Implemented.
    ///
    /// qBittorrent has an "alternative speed limits" feature: a second set of
    /// upload/download rate caps that can be toggled manually or on a schedule
    /// (e.g. lower limits during business hours). Implementing this requires:
    ///   - A second pair of rate-limit values stored in config and persisted
    ///   - A toggle flag (normal vs alternative) with persistence
    ///   - Optional time-based scheduling (cron-style)
    /// Varuna does not have an alt-speed subsystem. Use `setDownloadLimit` /
    /// `setUploadLimit` directly, or automate via `cron` + `varuna-ctl`.
    fn handleToggleSpeedLimitsMode(_: *const ApiHandler) server.Response {
        return .{ .status = 501, .body = "{\"error\":\"not implemented: alternative speed limits are not supported. Use setDownloadLimit/setUploadLimit directly.\"}" };
    }

    /// GET /api/v2/transfer/downloadLimit -- return global download limit as plain text number.
    fn handleGlobalDlLimit(self: *const ApiHandler, allocator: std.mem.Allocator) server.Response {
        const limit: u64 = if (self.session_manager.shared_event_loop) |el| el.getGlobalDlLimit() else 0;
        const body = std.fmt.allocPrint(allocator, "{}", .{limit}) catch
            return .{ .status = 500, .body = "0", .content_type = "text/plain" };
        return .{ .body = body, .owned_body = body, .content_type = "text/plain" };
    }

    /// GET /api/v2/transfer/uploadLimit -- return global upload limit as plain text number.
    fn handleGlobalUlLimit(self: *const ApiHandler, allocator: std.mem.Allocator) server.Response {
        const limit: u64 = if (self.session_manager.shared_event_loop) |el| el.getGlobalUlLimit() else 0;
        const body = std.fmt.allocPrint(allocator, "{}", .{limit}) catch
            return .{ .status = 500, .body = "0", .content_type = "text/plain" };
        return .{ .body = body, .owned_body = body, .content_type = "text/plain" };
    }

    /// POST /api/v2/transfer/setDownloadLimit -- set global download speed limit.
    fn handleSetGlobalDlLimit(self: *const ApiHandler, body: []const u8) server.Response {
        const limit_str = extractParamMut(body, "limit") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing limit\"}" };
        const limit = std.fmt.parseInt(u64, limit_str, 10) catch
            return .{ .status = 400, .body = "{\"error\":\"invalid limit\"}" };
        self.session_manager.setGlobalDlLimit(limit);
        return .{ .body = "Ok.", .content_type = "text/plain" };
    }

    /// POST /api/v2/transfer/setUploadLimit -- set global upload speed limit.
    fn handleSetGlobalUlLimit(self: *const ApiHandler, body: []const u8) server.Response {
        const limit_str = extractParamMut(body, "limit") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing limit\"}" };
        const limit = std.fmt.parseInt(u64, limit_str, 10) catch
            return .{ .status = 400, .body = "{\"error\":\"invalid limit\"}" };
        self.session_manager.setGlobalUlLimit(limit);
        return .{ .body = "Ok.", .content_type = "text/plain" };
    }

    /// POST /api/v2/torrents/rename -- rename a torrent.
    fn handleTorrentsRename(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hash = extractParamMut(body, "hash") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" };
        const name = extractParamMut(body, "name") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing name\"}" };
        if (name.len == 0) {
            return .{ .status = 400, .body = "{\"error\":\"name cannot be empty\"}" };
        }

        self.session_manager.renameTorrent(hash, name) catch |err| {
            return errorResponse(allocator, 404, err);
        };

        return .{ .body = "Ok.", .content_type = "text/plain" };
    }

    /// POST /api/v2/torrents/toggleSequentialDownload -- toggle sequential download mode.
    fn handleTorrentsToggleSequentialDownload(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hashes_param = requireHashes(body) orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const hashes = resolveHashesOrAll(self, allocator, hashes_param) catch |err| {
            return hashSelectionErrorResponse(allocator, err);
        };
        defer allocator.free(hashes);

        for (hashes) |hash| {
            self.session_manager.toggleSequentialDownload(hash[0..]) catch |err| {
                return errorResponse(allocator, 404, err);
            };
        }

        return .{ .body = "Ok.", .content_type = "text/plain" };
    }

    /// POST /api/v2/torrents/setAutoManagement — 501 Not Implemented.
    ///
    /// qBittorrent's "automatic torrent management" moves completed downloads
    /// to category-specific directories and applies category-level save paths
    /// automatically. Implementing this requires:
    ///   - Per-category save path configuration with persistence
    ///   - A post-completion hook that renames/moves files (io_uring)
    ///   - Updating PieceStore file mappings after the move
    /// Varuna does not have an auto-management layer. Use `setLocation` to
    /// move torrents manually, or automate via `varuna-ctl` scripts.
    fn handleTorrentsSetAutoManagement(_: *const ApiHandler) server.Response {
        return .{ .status = 501, .body = "{\"error\":\"not implemented: automatic torrent management is not supported. Use setLocation to move torrents manually.\"}" };
    }

    /// POST /api/v2/torrents/setForceStart -- force-start torrents bypassing queue limits.
    fn handleTorrentsSetForceStart(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hashes_param = requireHashes(body) orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const hashes = resolveHashesOrAll(self, allocator, hashes_param) catch |err| {
            return hashSelectionErrorResponse(allocator, err);
        };
        defer allocator.free(hashes);

        for (hashes) |hash| {
            self.session_manager.forceStartTorrent(hash[0..]) catch |err| {
                return errorResponse(allocator, 404, err);
            };
        }

        return .{ .body = "Ok.", .content_type = "text/plain" };
    }

    /// GET /api/v2/torrents/pieceStates -- return piece states as JSON array.
    fn handleTorrentsPieceStates(self: *const ApiHandler, allocator: std.mem.Allocator, params: []const u8) server.Response {
        const hash = extractParamMut(params, "hash") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" };

        const states = self.session_manager.getPieceStates(allocator, hash) catch |err| switch (err) {
            error.TorrentNotFound => return .{ .status = 404, .body = "{\"error\":\"torrent not found\"}" },
            error.TorrentNotReady => return .{ .status = 409, .body = "{\"error\":\"torrent metadata not ready\"}" },
            else => return .{ .status = 500, .body = "{\"error\":\"internal\"}" },
        };
        defer allocator.free(states);

        var json = std.ArrayList(u8).empty;
        defer json.deinit(allocator);

        json.append(allocator, '[') catch return .{ .status = 500, .body = "[]" };
        for (states, 0..) |state, i| {
            if (i > 0) json.append(allocator, ',') catch {};
            json.print(allocator, "{}", .{state}) catch {};
        }
        json.append(allocator, ']') catch {};

        const body = json.toOwnedSlice(allocator) catch return .{ .status = 500, .body = "[]" };
        return .{ .body = body, .owned_body = body };
    }

    /// GET /api/v2/torrents/pieceHashes -- return piece hashes as JSON array of hex strings.
    fn handleTorrentsPieceHashes(self: *const ApiHandler, allocator: std.mem.Allocator, params: []const u8) server.Response {
        const hash = extractParamMut(params, "hash") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" };

        const hashes = self.session_manager.getPieceHashes(allocator, hash) catch |err| switch (err) {
            error.TorrentNotFound => return .{ .status = 404, .body = "{\"error\":\"torrent not found\"}" },
            error.TorrentNotReady => return .{ .status = 409, .body = "{\"error\":\"torrent metadata not ready\"}" },
            else => return .{ .status = 500, .body = "{\"error\":\"internal\"}" },
        };
        defer {
            for (hashes) |h| allocator.free(h);
            allocator.free(hashes);
        }

        var json = std.ArrayList(u8).empty;
        defer json.deinit(allocator);

        json.append(allocator, '[') catch return .{ .status = 500, .body = "[]" };
        for (hashes, 0..) |hex, i| {
            if (i > 0) json.append(allocator, ',') catch {};
            json.append(allocator, '"') catch {};
            json.appendSlice(allocator, hex) catch {};
            json.append(allocator, '"') catch {};
        }
        json.append(allocator, ']') catch {};

        const body = json.toOwnedSlice(allocator) catch return .{ .status = 500, .body = "[]" };
        return .{ .body = body, .owned_body = body };
    }

    /// POST /api/v2/torrents/renameFile — 501 Not Implemented.
    ///
    /// Renaming a file within a torrent's download requires:
    ///   - Filesystem rename via io_uring (daemon I/O policy)
    ///   - Updating PieceStore's file-to-piece mappings so reads/writes
    ///     target the new path
    ///   - Persisting the rename to SQLite so it survives daemon restart
    ///   - Handling active downloads: the file may be open for writing
    ///     by the event loop, requiring coordinated close/rename/reopen
    /// None of this plumbing exists yet.
    fn handleTorrentsRenameFile(_: *const ApiHandler) server.Response {
        return .{ .status = 501, .body = "{\"error\":\"not implemented: file rename requires io_uring filesystem ops, PieceStore mapping updates, and SQLite persistence.\"}" };
    }

    /// POST /api/v2/torrents/renameFolder — 501 Not Implemented.
    ///
    /// Same requirements as renameFile, plus:
    ///   - Recursive directory rename affecting multiple file mappings
    ///   - Must update all PieceStore entries whose paths are children
    ///     of the renamed directory
    fn handleTorrentsRenameFolder(_: *const ApiHandler) server.Response {
        return .{ .status = 501, .body = "{\"error\":\"not implemented: folder rename requires recursive io_uring filesystem ops, PieceStore mapping updates, and SQLite persistence.\"}" };
    }

    /// GET /api/v2/torrents/export -- export .torrent file bytes.
    fn handleTorrentsExport(self: *const ApiHandler, params: []const u8) server.Response {
        const hash = extractParamMut(params, "hash") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hash\"}" };

        self.session_manager.mutex.lock();
        defer self.session_manager.mutex.unlock();

        const session = self.session_manager.sessions.get(hash) orelse
            return .{ .status = 404, .body = "{\"error\":\"torrent not found\"}" };

        if (session.torrent_bytes.len == 0) {
            return .{ .status = 409, .body = "{\"error\":\"no torrent file available (magnet link)\"}" };
        }

        return .{ .body = session.torrent_bytes, .content_type = "application/x-bittorrent" };
    }

    /// POST /api/v2/torrents/addPeers -- manually add peers to a torrent.
    fn handleTorrentsAddPeers(self: *const ApiHandler, allocator: std.mem.Allocator, body: []const u8) server.Response {
        const hashes_param = requireHashes(body) orelse
            return .{ .status = 400, .body = "{\"error\":\"missing hashes\"}" };
        const hashes = resolveHashesOrAll(self, allocator, hashes_param) catch |err| {
            return hashSelectionErrorResponse(allocator, err);
        };
        defer allocator.free(hashes);
        const peers_str = extractParamMut(body, "peers") orelse
            return .{ .status = 400, .body = "{\"error\":\"missing peers\"}" };

        for (hashes) |hash| {
            self.session_manager.addManualPeers(hash[0..], peers_str) catch |err| {
                return errorResponse(allocator, 404, err);
            };
        }

        return .{ .body = "Ok.", .content_type = "text/plain" };
    }
};

fn serializeTorrentInfo(allocator: std.mem.Allocator, json: *std.ArrayList(u8), stat: TorrentSession.Stats) !void {
    return compat.serializeTorrentJson(allocator, json, stat, true);
}

/// Structured JSON body for POST /api/v2/app/setPreferences.
/// All fields are optional; only the fields present in the JSON body are applied.
/// Parsed with `std.json.parseFromSlice` and `ignore_unknown_fields = true`.
const PreferencesUpdate = struct {
    dl_limit: ?u64 = null,
    up_limit: ?u64 = null,
    max_ratio_enabled: ?bool = null,
    max_ratio: ?f64 = null,
    max_ratio_act: ?u8 = null,
    max_seeding_time_enabled: ?bool = null,
    max_seeding_time: ?i64 = null,
    queueing_enabled: ?bool = null,
    max_active_downloads: ?i32 = null,
    max_active_uploads: ?i32 = null,
    max_active_torrents: ?i32 = null,
    dht: ?bool = null,
    pex: ?bool = null,
    enable_utp: ?bool = null,
    outgoing_tcp: ?bool = null,
    outgoing_utp: ?bool = null,
    incoming_tcp: ?bool = null,
    incoming_utp: ?bool = null,
    transport_disposition: ?u8 = null,
    web_seed_max_request_bytes: ?u32 = null,
};

/// Build a `server.Response` carrying a JSON error body.
/// `owned_body` is set so the caller's arena or response-send path can free it.
fn errorResponse(allocator: std.mem.Allocator, status: u16, err: anyerror) server.Response {
    const msg = std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)}) catch
        return .{ .status = 500, .body = "{\"error\":\"internal\"}" };
    return .{ .status = status, .body = msg, .owned_body = msg };
}

/// Extract a torrent hash from the request body.  Tries `hashes` first (the
/// multi-torrent key used by most qBittorrent endpoints), then falls back to
/// the single-torrent `hash` key.
fn requireHashes(body: []const u8) ?[]const u8 {
    return extractParamMut(body, "hashes") orelse extractParamMut(body, "hash");
}

fn resolveHashesOrAll(self: *const ApiHandler, allocator: std.mem.Allocator, hashes_param: []const u8) ![]const [40]u8 {
    const trimmed = std.mem.trim(u8, hashes_param, " \t\r\n");
    if (std.ascii.eqlIgnoreCase(trimmed, "all")) {
        const stats = try self.session_manager.getAllStats(allocator);
        defer allocator.free(stats);

        const hashes = try allocator.alloc([40]u8, stats.len);
        for (stats, 0..) |stat, i| {
            hashes[i] = stat.info_hash_hex;
        }
        return hashes;
    }

    var hashes = std.ArrayList([40]u8).empty;
    errdefer hashes.deinit(allocator);

    var iter = std.mem.splitScalar(u8, trimmed, '|');
    while (iter.next()) |raw_hash| {
        const hash_str = std.mem.trim(u8, raw_hash, " \t\r\n");
        if (hash_str.len == 0) continue;
        if (hash_str.len != 40) return error.InvalidHash;

        var hash: [40]u8 = undefined;
        @memcpy(hash[0..], hash_str[0..40]);
        try hashes.append(allocator, hash);
    }

    return hashes.toOwnedSlice(allocator);
}

fn hashSelectionErrorResponse(allocator: std.mem.Allocator, err: anyerror) server.Response {
    return switch (err) {
        error.InvalidHash => .{ .status = 400, .body = "{\"error\":\"invalid hashes\"}" },
        error.OutOfMemory => .{ .status = 500, .body = "{\"error\":\"internal\"}" },
        else => errorResponse(allocator, 500, err),
    };
}

fn matchesHashSelection(selected_hashes: ?[]const [40]u8, hash: [40]u8) bool {
    const hashes = selected_hashes orelse return true;
    for (hashes) |selected| {
        if (std.mem.eql(u8, selected[0..], hash[0..])) return true;
    }
    return false;
}

fn matchesInfoFilter(stat: TorrentSession.Stats, filter: []const u8) bool {
    if (filter.len == 0 or std.ascii.eqlIgnoreCase(filter, "all")) return true;
    if (std.ascii.eqlIgnoreCase(filter, "downloading")) return stat.state == .downloading or stat.state == .metadata_fetching;
    if (std.ascii.eqlIgnoreCase(filter, "seeding") or std.ascii.eqlIgnoreCase(filter, "uploading")) return stat.state == .seeding;
    if (std.ascii.eqlIgnoreCase(filter, "completed")) return stat.progress >= 1.0;
    if (std.ascii.eqlIgnoreCase(filter, "paused")) return stat.state == .paused or stat.state == .stopped;
    if (std.ascii.eqlIgnoreCase(filter, "resumed")) return stat.state != .paused and stat.state != .stopped;
    if (std.ascii.eqlIgnoreCase(filter, "active")) return stat.download_speed > 0 or stat.upload_speed > 0;
    if (std.ascii.eqlIgnoreCase(filter, "inactive")) return stat.download_speed == 0 and stat.upload_speed == 0;
    if (std.ascii.eqlIgnoreCase(filter, "stalled")) return (stat.state == .downloading or stat.state == .seeding) and stat.download_speed == 0 and stat.upload_speed == 0;
    if (std.ascii.eqlIgnoreCase(filter, "stalled_downloading") or std.ascii.eqlIgnoreCase(filter, "stalledDL")) return stat.state == .downloading and stat.download_speed == 0;
    if (std.ascii.eqlIgnoreCase(filter, "stalled_uploading") or std.ascii.eqlIgnoreCase(filter, "stalledUP")) return stat.state == .seeding and stat.upload_speed == 0;
    if (std.ascii.eqlIgnoreCase(filter, "errored") or std.ascii.eqlIgnoreCase(filter, "error")) return stat.state == .@"error";
    if (std.ascii.eqlIgnoreCase(filter, "checking")) return stat.state == .checking;
    if (std.ascii.eqlIgnoreCase(filter, "queued")) return stat.state == .queued;

    const qbt_state = compat.torrentStateString(stat.state, stat.progress);
    return std.ascii.eqlIgnoreCase(filter, qbt_state);
}

fn matchesCategory(stat: TorrentSession.Stats, category: ?[]const u8) bool {
    const wanted = category orelse return true;
    if (std.ascii.eqlIgnoreCase(wanted, "all")) return true;
    return std.mem.eql(u8, stat.category, wanted);
}

fn matchesTag(stat: TorrentSession.Stats, tag: ?[]const u8) bool {
    const wanted = tag orelse return true;
    if (std.ascii.eqlIgnoreCase(wanted, "all")) return true;
    if (wanted.len == 0 or std.ascii.eqlIgnoreCase(wanted, "untagged")) return stat.tags.len == 0;

    var iter = std.mem.splitScalar(u8, stat.tags, ',');
    while (iter.next()) |raw_tag| {
        const current = std.mem.trim(u8, raw_tag, " ");
        if (std.mem.eql(u8, current, wanted)) return true;
    }
    return false;
}

fn parseOptionalI64(params: []const u8, key: []const u8) ?i64 {
    const value = extractParamMut(params, key) orelse return null;
    return std.fmt.parseInt(i64, value, 10) catch null;
}

fn parseBoolLoose(value: []const u8) bool {
    return parseBoolPreference(value) catch false;
}

const PageWindow = struct {
    start: usize,
    end: usize,
};

fn pagedWindow(len: usize, offset: i64, limit: i64) PageWindow {
    var start: usize = 0;
    if (offset > 0) {
        start = @min(len, @as(usize, @intCast(offset)));
    } else if (offset < 0) {
        const from_end: usize = @intCast(-offset);
        start = if (from_end >= len) 0 else len - from_end;
    }

    var end = len;
    if (limit >= 0) {
        end = @min(len, start + @as(usize, @intCast(limit)));
    }
    if (end < start) end = start;
    return .{ .start = start, .end = end };
}

fn sortTorrentStats(items: []TorrentSession.Stats, key: []const u8, reverse: bool) void {
    if (key.len == 0) return;

    const SortCtx = struct {
        key: []const u8,
        reverse: bool,

        fn lessThan(ctx: @This(), lhs: TorrentSession.Stats, rhs: TorrentSession.Stats) bool {
            var order = compareTorrentStats(ctx.key, lhs, rhs);
            if (order == .eq) order = std.mem.order(u8, lhs.info_hash_hex[0..], rhs.info_hash_hex[0..]);
            return if (ctx.reverse) order == .gt else order == .lt;
        }
    };

    std.mem.sort(TorrentSession.Stats, items, SortCtx{ .key = key, .reverse = reverse }, SortCtx.lessThan);
}

fn compareTorrentStats(key: []const u8, lhs: TorrentSession.Stats, rhs: TorrentSession.Stats) std.math.Order {
    if (std.ascii.eqlIgnoreCase(key, "name")) return std.mem.order(u8, lhs.name, rhs.name);
    if (std.ascii.eqlIgnoreCase(key, "hash")) return std.mem.order(u8, lhs.info_hash_hex[0..], rhs.info_hash_hex[0..]);
    if (std.ascii.eqlIgnoreCase(key, "state")) return std.mem.order(
        u8,
        compat.torrentStateString(lhs.state, lhs.progress),
        compat.torrentStateString(rhs.state, rhs.progress),
    );
    if (std.ascii.eqlIgnoreCase(key, "category")) return std.mem.order(u8, lhs.category, rhs.category);
    if (std.ascii.eqlIgnoreCase(key, "tags")) return std.mem.order(u8, lhs.tags, rhs.tags);
    if (std.ascii.eqlIgnoreCase(key, "save_path")) return std.mem.order(u8, lhs.save_path, rhs.save_path);
    if (std.ascii.eqlIgnoreCase(key, "size") or std.ascii.eqlIgnoreCase(key, "total_size")) return std.math.order(lhs.total_size, rhs.total_size);
    if (std.ascii.eqlIgnoreCase(key, "progress")) return std.math.order(lhs.progress, rhs.progress);
    if (std.ascii.eqlIgnoreCase(key, "dlspeed")) return std.math.order(lhs.download_speed, rhs.download_speed);
    if (std.ascii.eqlIgnoreCase(key, "upspeed")) return std.math.order(lhs.upload_speed, rhs.upload_speed);
    if (std.ascii.eqlIgnoreCase(key, "ratio")) return std.math.order(lhs.ratio, rhs.ratio);
    if (std.ascii.eqlIgnoreCase(key, "added_on")) return std.math.order(lhs.added_on, rhs.added_on);
    if (std.ascii.eqlIgnoreCase(key, "completion_on")) return std.math.order(lhs.completion_on, rhs.completion_on);
    if (std.ascii.eqlIgnoreCase(key, "eta")) return std.math.order(lhs.eta, rhs.eta);
    if (std.ascii.eqlIgnoreCase(key, "num_seeds")) return std.math.order(lhs.scrape_complete, rhs.scrape_complete);
    if (std.ascii.eqlIgnoreCase(key, "num_leechs")) return std.math.order(lhs.scrape_incomplete, rhs.scrape_incomplete);
    if (std.ascii.eqlIgnoreCase(key, "downloaded")) return std.math.order(lhs.bytes_downloaded, rhs.bytes_downloaded);
    if (std.ascii.eqlIgnoreCase(key, "uploaded")) return std.math.order(lhs.bytes_uploaded, rhs.bytes_uploaded);
    return .eq;
}

fn bodyLooksLikeJson(body: []const u8) bool {
    return body.len > 0 and (body[0] == '{' or body[0] == '[');
}

fn parseBoolPreference(value: []const u8) error{InvalidBoolean}!bool {
    if (std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1")) return true;
    if (std.ascii.eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0")) return false;
    return error.InvalidBoolean;
}

/// Warning: mutates body in-place for URL decoding.
fn extractParamMut(body: []const u8, key: []const u8) ?[]const u8 {
    // Simple form-encoded parameter extraction: key=value&key2=value2
    var iter = std.mem.splitScalar(u8, body, '&');
    while (iter.next()) |pair| {
        if (std.mem.indexOfScalar(u8, pair, '=')) |eq| {
            if (std.mem.eql(u8, pair[0..eq], key)) {
                const raw_value = pair[eq + 1 ..];
                const decoded_len = urlDecodeComponentInPlace(@constCast(raw_value));
                return raw_value[0..decoded_len];
            }
        }
    }
    return null;
}

fn urlDecodeComponentInPlace(buf: []u8) usize {
    var read_idx: usize = 0;
    var write_idx: usize = 0;

    while (read_idx < buf.len) {
        const ch = buf[read_idx];
        if (ch == '+') {
            buf[write_idx] = ' ';
            read_idx += 1;
            write_idx += 1;
            continue;
        }
        if (ch == '%' and read_idx + 2 < buf.len) {
            const hi = std.fmt.charToDigit(buf[read_idx + 1], 16) catch {
                buf[write_idx] = ch;
                read_idx += 1;
                write_idx += 1;
                continue;
            };
            const lo = std.fmt.charToDigit(buf[read_idx + 2], 16) catch {
                buf[write_idx] = ch;
                read_idx += 1;
                write_idx += 1;
                continue;
            };
            buf[write_idx] = @intCast((hi << 4) | lo);
            read_idx += 3;
            write_idx += 1;
            continue;
        }

        buf[write_idx] = ch;
        read_idx += 1;
        write_idx += 1;
    }

    return write_idx;
}

test "extract form param" {
    try std.testing.expectEqualStrings("abc123", extractParamMut("hashes=abc123&deleteFiles=false", "hashes").?);
    try std.testing.expectEqualStrings("false", extractParamMut("hashes=abc123&deleteFiles=false", "deleteFiles").?);
    try std.testing.expect(extractParamMut("hashes=abc", "missing") == null);
}

// ── Additional parameter extraction tests ────────────────

test "extractParam returns empty string for key with no value" {
    try std.testing.expectEqualStrings("", extractParamMut("hashes=&deleteFiles=true", "hashes").?);
}

test "extractParam returns first match for duplicate keys" {
    try std.testing.expectEqualStrings("first", extractParamMut("key=first&key=second", "key").?);
}

test "extractParam handles single param without ampersand" {
    try std.testing.expectEqualStrings("val", extractParamMut("key=val", "key").?);
}

test "extractParam percent-decodes values" {
    var body = "hash=abc%20123%2Fxyz+ok".*;
    try std.testing.expectEqualStrings("abc 123/xyz ok", extractParamMut(body[0..], "hash").?);
}

test "extractParam returns null for empty body" {
    try std.testing.expect(extractParamMut("", "key") == null);
}

test "extractParam does not match partial key names" {
    // "hash" should not match "hashes=abc"
    try std.testing.expect(extractParamMut("hashes=abc", "hash") == null);
}

test "extractParam handles value with equals sign" {
    // "url=http://host?a=b" -- value contains '='
    try std.testing.expectEqualStrings("http://host?a=b", extractParamMut("url=http://host?a=b", "url").?);
}

test "extractParam handles url-encoded special chars in value" {
    var body = "name=hello%20world".*;
    try std.testing.expectEqualStrings("hello world", extractParamMut(body[0..], "name").?);
}

test "parseBoolPreference accepts booleans and rejects garbage" {
    try std.testing.expect(try parseBoolPreference("true"));
    try std.testing.expect(!(try parseBoolPreference("0")));
    try std.testing.expectError(error.InvalidBoolean, parseBoolPreference("maybe"));
}

// ── PreferencesUpdate JSON parsing tests ────────────────

test "parsePreferencesJson parses integer fields" {
    const json_body = "{\"dl_limit\":1024,\"up_limit\":512}";
    const parsed = std.json.parseFromSlice(PreferencesUpdate, std.testing.allocator, json_body, .{ .ignore_unknown_fields = true }) catch |err| {
        std.debug.print("JSON parse error: {}\n", .{err});
        return error.TestUnexpectedResult;
    };
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u64, 1024), parsed.value.dl_limit);
    try std.testing.expectEqual(@as(?u64, 512), parsed.value.up_limit);
}

test "parsePreferencesJson parses boolean fields" {
    const json_body = "{\"max_ratio_enabled\":true,\"max_seeding_time_enabled\":false,\"queueing_enabled\":true}";
    const parsed = std.json.parseFromSlice(PreferencesUpdate, std.testing.allocator, json_body, .{ .ignore_unknown_fields = true }) catch
        return error.TestUnexpectedResult;
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?bool, true), parsed.value.max_ratio_enabled);
    try std.testing.expectEqual(@as(?bool, false), parsed.value.max_seeding_time_enabled);
    try std.testing.expectEqual(@as(?bool, true), parsed.value.queueing_enabled);
}

test "parsePreferencesJson parses float fields" {
    const eps = 0.0001;
    const json_body = "{\"max_ratio\":2.5}";
    const parsed = std.json.parseFromSlice(PreferencesUpdate, std.testing.allocator, json_body, .{ .ignore_unknown_fields = true }) catch
        return error.TestUnexpectedResult;
    defer parsed.deinit();
    const v = parsed.value.max_ratio orelse return error.TestUnexpectedResult;
    try std.testing.expect(@abs(v - 2.5) < eps);
}

test "parsePreferencesJson parses queue config fields" {
    const json_body = "{\"queueing_enabled\":true,\"max_active_downloads\":5,\"max_active_uploads\":3,\"max_active_torrents\":10}";
    const parsed = std.json.parseFromSlice(PreferencesUpdate, std.testing.allocator, json_body, .{ .ignore_unknown_fields = true }) catch
        return error.TestUnexpectedResult;
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?bool, true), parsed.value.queueing_enabled);
    try std.testing.expectEqual(@as(?i32, 5), parsed.value.max_active_downloads);
    try std.testing.expectEqual(@as(?i32, 3), parsed.value.max_active_uploads);
    try std.testing.expectEqual(@as(?i32, 10), parsed.value.max_active_torrents);
}

test "parsePreferencesJson parses seeding time as signed int" {
    const json_body = "{\"max_seeding_time\":-1}";
    const parsed = std.json.parseFromSlice(PreferencesUpdate, std.testing.allocator, json_body, .{ .ignore_unknown_fields = true }) catch
        return error.TestUnexpectedResult;
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?i64, -1), parsed.value.max_seeding_time);
}

test "parsePreferencesJson parses multiple fields in one request" {
    const json_body = "{\"dl_limit\":2048,\"up_limit\":1024,\"max_ratio_enabled\":true,\"max_ratio\":3.0,\"dht\":false,\"pex\":true}";
    const parsed = std.json.parseFromSlice(PreferencesUpdate, std.testing.allocator, json_body, .{ .ignore_unknown_fields = true }) catch
        return error.TestUnexpectedResult;
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u64, 2048), parsed.value.dl_limit);
    try std.testing.expectEqual(@as(?u64, 1024), parsed.value.up_limit);
    try std.testing.expectEqual(@as(?bool, true), parsed.value.max_ratio_enabled);
    try std.testing.expectEqual(@as(?bool, false), parsed.value.dht);
    try std.testing.expectEqual(@as(?bool, true), parsed.value.pex);
}

test "parsePreferencesJson missing fields are null" {
    const json_body = "{\"dl_limit\":100}";
    const parsed = std.json.parseFromSlice(PreferencesUpdate, std.testing.allocator, json_body, .{ .ignore_unknown_fields = true }) catch
        return error.TestUnexpectedResult;
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u64, 100), parsed.value.dl_limit);
    try std.testing.expect(parsed.value.up_limit == null);
    try std.testing.expect(parsed.value.max_ratio_enabled == null);
    try std.testing.expect(parsed.value.max_ratio == null);
    try std.testing.expect(parsed.value.queueing_enabled == null);
    try std.testing.expect(parsed.value.dht == null);
    try std.testing.expect(parsed.value.pex == null);
}

test "parsePreferencesJson ignores unknown fields" {
    const json_body = "{\"dl_limit\":100,\"totally_unknown_field\":42,\"another_unknown\":\"value\"}";
    const parsed = std.json.parseFromSlice(PreferencesUpdate, std.testing.allocator, json_body, .{ .ignore_unknown_fields = true }) catch
        return error.TestUnexpectedResult;
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u64, 100), parsed.value.dl_limit);
}

test "parsePreferencesJson handles empty object" {
    const json_body = "{}";
    const parsed = std.json.parseFromSlice(PreferencesUpdate, std.testing.allocator, json_body, .{ .ignore_unknown_fields = true }) catch
        return error.TestUnexpectedResult;
    defer parsed.deinit();
    try std.testing.expect(parsed.value.dl_limit == null);
    try std.testing.expect(parsed.value.up_limit == null);
}

test "parsePreferencesJson parses dht and pex toggles" {
    const json_body = "{\"dht\":true,\"pex\":false}";
    const parsed = std.json.parseFromSlice(PreferencesUpdate, std.testing.allocator, json_body, .{ .ignore_unknown_fields = true }) catch
        return error.TestUnexpectedResult;
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?bool, true), parsed.value.dht);
    try std.testing.expectEqual(@as(?bool, false), parsed.value.pex);
}

test "parsePreferencesJson parses max_ratio_act" {
    const json_body = "{\"max_ratio_act\":1}";
    const parsed = std.json.parseFromSlice(PreferencesUpdate, std.testing.allocator, json_body, .{ .ignore_unknown_fields = true }) catch
        return error.TestUnexpectedResult;
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u8, 1), parsed.value.max_ratio_act);
}

test "parsePreferencesJson handles whitespace" {
    const json_body = "{ \"dl_limit\" : 100 , \"up_limit\" : 200 }";
    const parsed = std.json.parseFromSlice(PreferencesUpdate, std.testing.allocator, json_body, .{ .ignore_unknown_fields = true }) catch
        return error.TestUnexpectedResult;
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u64, 100), parsed.value.dl_limit);
    try std.testing.expectEqual(@as(?u64, 200), parsed.value.up_limit);
}

// ── requireHashes helper tests ──────────────────────────

test "requireHashes returns hashes param" {
    try std.testing.expectEqualStrings("abc123", requireHashes("hashes=abc123&deleteFiles=false").?);
}

test "requireHashes falls back to hash param" {
    try std.testing.expectEqualStrings("def456", requireHashes("hash=def456").?);
}

test "requireHashes prefers hashes over hash" {
    try std.testing.expectEqualStrings("first", requireHashes("hashes=first&hash=second").?);
}

test "requireHashes returns null when neither present" {
    try std.testing.expect(requireHashes("other=value") == null);
}

test "requireHashes returns null for empty body" {
    try std.testing.expect(requireHashes("") == null);
}

// ── errorResponse helper tests ──────────────────────────

test "errorResponse formats error message" {
    const resp = errorResponse(std.testing.allocator, 404, error.TorrentNotFound);
    if (resp.owned_body) |body| {
        defer std.testing.allocator.free(body);
        try std.testing.expectEqualStrings("{\"error\":\"TorrentNotFound\"}", body);
        try std.testing.expectEqual(@as(u16, 404), resp.status);
    }
}

test "errorResponse uses correct status code" {
    const resp = errorResponse(std.testing.allocator, 500, error.OutOfMemory);
    if (resp.owned_body) |body| {
        defer std.testing.allocator.free(body);
        try std.testing.expectEqual(@as(u16, 500), resp.status);
    }
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
    try std.testing.expectEqualStrings("true", extractParamMut("enable_utp=true", "enable_utp").?);
    try std.testing.expectEqualStrings("false", extractParamMut("enable_utp=false", "enable_utp").?);
    try std.testing.expectEqualStrings("true", extractParamMut("pex=true&enable_utp=true&dht=false", "enable_utp").?);
}

test "enable_utp json parsing via PreferencesUpdate" {
    const parsed = try std.json.parseFromSlice(PreferencesUpdate, std.testing.allocator, "{\"enable_utp\":true}", .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?bool, true), parsed.value.enable_utp);

    const parsed2 = try std.json.parseFromSlice(PreferencesUpdate, std.testing.allocator, "{\"dht\":false,\"enable_utp\":false,\"pex\":true}", .{ .ignore_unknown_fields = true });
    defer parsed2.deinit();
    try std.testing.expectEqual(@as(?bool, false), parsed2.value.enable_utp);
}

test "transport disposition json parsing via PreferencesUpdate" {
    const parsed = try std.json.parseFromSlice(
        PreferencesUpdate,
        std.testing.allocator,
        "{\"outgoing_tcp\":true,\"outgoing_utp\":false,\"incoming_tcp\":true,\"incoming_utp\":false}",
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?bool, true), parsed.value.outgoing_tcp);
    try std.testing.expectEqual(@as(?bool, false), parsed.value.outgoing_utp);
    try std.testing.expectEqual(@as(?bool, true), parsed.value.incoming_tcp);
    try std.testing.expectEqual(@as(?bool, false), parsed.value.incoming_utp);
}

test "transport disposition bitfield json parsing via PreferencesUpdate" {
    const parsed = try std.json.parseFromSlice(
        PreferencesUpdate,
        std.testing.allocator,
        "{\"transport_disposition\":5}",
        .{ .ignore_unknown_fields = true },
    );
    defer parsed.deinit();
    try std.testing.expectEqual(@as(?u8, 5), parsed.value.transport_disposition);
}

test "transport disposition form param parsing" {
    try std.testing.expectEqualStrings("true", extractParamMut("outgoing_tcp=true", "outgoing_tcp").?);
    try std.testing.expectEqualStrings("false", extractParamMut("outgoing_utp=false", "outgoing_utp").?);
    try std.testing.expectEqualStrings("5", extractParamMut("transport_disposition=5", "transport_disposition").?);
}
