//! varuna-tui: Terminal UI for the varuna BitTorrent daemon.
//!
//! An rtorrent-style TUI that communicates with the varuna daemon over
//! its qBittorrent-compatible WebAPI.  Uses zigzag for terminal rendering
//! (Elm Architecture) and zio for non-blocking HTTP API polling via dusty.
//!
//! Architecture:
//!   - The main thread runs the zigzag TUI event loop (start + tick).
//!   - A zio Runtime runs in the background for async HTTP I/O.
//!   - Polling tasks use dusty (zio-native HTTP client) inside zio fibers.
//!   - A thread-safe ResultQueue passes API results from zio tasks to
//!     the zigzag main thread, checked every tick.
//!
//! Usage:
//!   varuna-tui [--host HOST] [--port PORT]

const std = @import("std");
const zz = @import("zigzag");
const zio = @import("zio");
const api_mod = @import("api.zig");
const views = @import("views.zig");

const Allocator = std.mem.Allocator;

// ── Thread-safe result queue ────────────────────────────────────────
// Communication bridge between zio tasks and the zigzag main thread.
// Uses std.Thread.Mutex (not zio.Mutex) so the zigzag thread can drain
// results without being inside a zio coroutine.

const ApiResult = struct {
    torrents: ?[]const api_mod.TorrentInfo = null,
    transfer: ?api_mod.TransferInfo = null,
    connected: bool = true,
    detail_files: ?[]const api_mod.TorrentFile = null,
    detail_trackers: ?[]const api_mod.TrackerEntry = null,
    detail_props: ?api_mod.TorrentProperties = null,
    preferences: ?api_mod.Preferences = null,
    action_ok: bool = true,
    action_error: ?[]const u8 = null,
    auth_required: bool = false,
};

const ResultQueue = struct {
    mu: std.Thread.Mutex = .{},
    items: [CAPACITY]ApiResult = undefined,
    head: usize = 0,
    count: usize = 0,

    const CAPACITY = 16;

    fn push(self: *ResultQueue, result: ApiResult) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.count >= CAPACITY) return; // drop if full
        const idx = (self.head + self.count) % CAPACITY;
        self.items[idx] = result;
        self.count += 1;
    }

    fn pop(self: *ResultQueue) ?ApiResult {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.count == 0) return null;
        const result = self.items[self.head];
        self.head = (self.head + 1) % CAPACITY;
        self.count -= 1;
        return result;
    }
};

// ── Action command queue (main thread -> zio task) ──────────────────
// Single-slot command buffer for user-initiated actions.

const ActionKind = enum {
    none,
    add_magnet,
    add_file,
    delete,
    pause,
    @"resume",
    fetch_detail,
    fetch_preferences,
    set_preferences,
    login,
};

const ActionCmd = struct {
    kind: ActionKind = .none,
    hash: [64]u8 = undefined,
    hash_len: usize = 0,
    buf: [4096]u8 = undefined,
    buf_len: usize = 0,
    delete_files: bool = false,
};

const ActionQueue = struct {
    mu: std.Thread.Mutex = .{},
    items: [CAPACITY]ActionCmd = [_]ActionCmd{.{}} ** CAPACITY,
    head: usize = 0,
    count: usize = 0,

    const CAPACITY = 16;

    fn push(self: *ActionQueue, cmd: ActionCmd) void {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.count >= CAPACITY) return;
        const idx = (self.head + self.count) % CAPACITY;
        self.items[idx] = cmd;
        self.count += 1;
    }

    fn pop(self: *ActionQueue) ?ActionCmd {
        self.mu.lock();
        defer self.mu.unlock();
        if (self.count == 0) return null;
        const result = self.items[self.head];
        self.head = (self.head + 1) % CAPACITY;
        self.count -= 1;
        return result;
    }
};

// ── Shared context between main thread and zio tasks ────────────────

const SharedState = struct {
    results: ResultQueue = .{},
    actions: ActionQueue = .{},
    host: []const u8,
    port: u16,
    running: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
};

const AuthField = enum { username, password };

// ── Application model (zigzag Elm Architecture) ──────────────────────

const Model = struct {
    // Connection settings
    host: []const u8,
    port: u16,
    allocator: Allocator,

    // Shared state with zio tasks
    shared: *SharedState,

    // Data arena -- holds current API data; reset on each update
    data_arena: std.heap.ArenaAllocator,

    // Torrent list state
    torrents: []const api_mod.TorrentInfo,
    selected: usize,
    transfer_info: api_mod.TransferInfo,
    connected: bool,

    // View state
    mode: views.ViewMode,
    detail_tab: views.DetailTab,

    // Detail data (populated when viewing a torrent)
    detail_files: []const api_mod.TorrentFile,
    detail_trackers: []const api_mod.TrackerEntry,
    detail_props: api_mod.TorrentProperties,

    // Preferences
    preferences: api_mod.Preferences,

    // Add torrent dialog
    input_buf: [4096]u8,
    input_len: usize,
    input_is_magnet: bool,
    input_error: ?[]const u8,

    // Delete confirmation
    delete_files: bool,

    // Filter
    filter_buf: [256]u8,
    filter_len: usize,

    // Auth dialog
    auth_mode: bool,
    auth_user_buf: [256]u8,
    auth_user_len: usize,
    auth_pass_buf: [256]u8,
    auth_pass_len: usize,
    auth_field: AuthField = .username,
    auth_error: ?[]const u8,

    // Error message display
    last_error: ?[]const u8,

    // Preferences editing
    pref_selected: usize,
    pref_editing: bool,
    pref_edit_buf: [256]u8,
    pref_edit_len: usize,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        tick: zz.msg.Tick,
        window_size: zz.msg.WindowSize,
    };

    pub fn init(self: *Model, _: *zz.Context) zz.Cmd(Msg) {
        self.torrents = &[_]api_mod.TorrentInfo{};
        self.selected = 0;
        self.transfer_info = .{};
        self.connected = false;
        self.mode = .main;
        self.detail_tab = .files;
        self.detail_files = &[_]api_mod.TorrentFile{};
        self.detail_trackers = &[_]api_mod.TrackerEntry{};
        self.detail_props = .{};
        self.preferences = .{};
        self.input_buf = undefined;
        self.input_len = 0;
        self.input_is_magnet = false;
        self.input_error = null;
        self.delete_files = false;
        self.filter_buf = undefined;
        self.filter_len = 0;
        self.auth_mode = false;
        self.auth_user_buf = undefined;
        self.auth_user_len = 0;
        self.auth_pass_buf = undefined;
        self.auth_pass_len = 0;
        self.auth_field = .username;
        self.auth_error = null;
        self.last_error = null;
        self.pref_selected = 0;
        self.pref_editing = false;
        self.pref_edit_buf = undefined;
        self.pref_edit_len = 0;

        // Start periodic tick at 200ms (5 fps) -- drains results + re-renders
        return zz.Cmd(Msg).everyMs(200);
    }

    pub fn update(self: *Model, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| return self.handleKey(k),
            .tick => {
                self.drainResults();
                return .none;
            },
            .window_size => return .none,
        }
    }

    // ── Result draining ─────────────────────────────────────────────

    fn drainResults(self: *Model) void {
        while (self.shared.results.pop()) |result| {
            self.applyApiResult(result);
        }
    }

    fn applyApiResult(self: *Model, result: ApiResult) void {
        self.connected = result.connected;

        if (result.auth_required) {
            self.auth_mode = true;
            self.mode = .login;
            return;
        }

        if (result.torrents) |t| {
            // Reset data arena to free old data, then copy new data in
            _ = self.data_arena.reset(.retain_capacity);
            const arena = self.data_arena.allocator();

            // Deep copy torrent data into the data arena
            var list = arena.alloc(api_mod.TorrentInfo, t.len) catch {
                self.torrents = &[_]api_mod.TorrentInfo{};
                return;
            };
            for (t, 0..) |src, i| {
                list[i] = src;
                list[i].hash = arena.dupe(u8, src.hash) catch "";
                list[i].name = arena.dupe(u8, src.name) catch "";
                // state is an enum value, no deep copy needed
                list[i].save_path = arena.dupe(u8, src.save_path) catch "";
                list[i].category = arena.dupe(u8, src.category) catch "";
                list[i].tags = arena.dupe(u8, src.tags) catch "";
                list[i].tracker = arena.dupe(u8, src.tracker) catch "";
            }
            self.torrents = list;
            if (self.selected >= t.len and t.len > 0) {
                self.selected = t.len - 1;
            }
        }
        if (result.transfer) |t| self.transfer_info = t;
        if (result.detail_files) |_| {
            // detail data is transient, pointer only valid for this result
        }
        if (result.detail_trackers) |_| {}
        if (result.detail_props) |p| self.detail_props = p;
        if (result.preferences) |p| self.preferences = p;
        if (result.action_error) |err| self.last_error = err;
    }

    // ── Key handling ────────────────────────────────────────────────

    fn handleKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        switch (self.mode) {
            .main => return self.handleMainKey(k),
            .details => return self.handleDetailsKey(k),
            .add_torrent => return self.handleAddTorrentKey(k),
            .confirm_delete => return self.handleDeleteConfirmKey(k),
            .preferences => return self.handlePreferencesKey(k),
            .filter => return self.handleFilterKey(k),
            .login => return self.handleLoginKey(k),
        }
    }

    fn handleMainKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        switch (k.key) {
            .char => |c| switch (c) {
                'q' => return .quit,
                'j' => {
                    if (self.filteredCount() > 0 and self.selected < self.filteredCount() - 1)
                        self.selected += 1;
                },
                'k' => {
                    if (self.selected > 0)
                        self.selected -= 1;
                },
                'a' => {
                    self.mode = .add_torrent;
                    self.input_len = 0;
                    self.input_is_magnet = true;
                    self.input_error = null;
                },
                'd' => {
                    if (self.filteredCount() > 0) {
                        self.mode = .confirm_delete;
                        self.delete_files = false;
                    }
                },
                'p' => self.doPauseResume(),
                'P' => {
                    self.mode = .preferences;
                    self.pref_selected = 0;
                    self.pref_editing = false;
                    self.enqueueAction(.{ .kind = .fetch_preferences });
                },
                '/' => {
                    self.mode = .filter;
                    self.filter_len = 0;
                },
                else => {},
            },
            .up => {
                if (self.selected > 0)
                    self.selected -= 1;
            },
            .down => {
                if (self.filteredCount() > 0 and self.selected < self.filteredCount() - 1)
                    self.selected += 1;
            },
            .enter => {
                if (self.filteredCount() > 0 and self.selected < self.filteredCount()) {
                    self.mode = .details;
                    self.detail_tab = .files;
                    self.enqueueDetailFetch();
                }
            },
            .home => self.selected = 0,
            .end => {
                const cnt = self.filteredCount();
                if (cnt > 0) self.selected = cnt - 1;
            },
            .escape => return .quit,
            .delete => {
                if (self.filteredCount() > 0) {
                    self.mode = .confirm_delete;
                    self.delete_files = false;
                }
            },
            else => {},
        }
        return .none;
    }

    fn handleDetailsKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        switch (k.key) {
            .char => |c| switch (c) {
                'q' => self.mode = .main,
                'd' => {
                    self.mode = .confirm_delete;
                    self.delete_files = false;
                },
                'p' => self.doPauseResume(),
                else => {},
            },
            .escape => self.mode = .main,
            .tab => {
                self.detail_tab = switch (self.detail_tab) {
                    .files => .trackers,
                    .trackers => .info,
                    .info => .files,
                };
                self.enqueueDetailFetch();
            },
            else => {},
        }
        return .none;
    }

    fn handleAddTorrentKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        switch (k.key) {
            .escape => {
                self.mode = .main;
                self.input_error = null;
            },
            .enter => {
                if (self.input_len > 0) {
                    self.submitAddTorrent();
                    self.mode = .main;
                }
            },
            .tab => {
                self.input_is_magnet = !self.input_is_magnet;
            },
            .backspace => {
                if (self.input_len > 0) self.input_len -= 1;
            },
            .char => |c| {
                if (c < 128 and self.input_len < self.input_buf.len - 1) {
                    self.input_buf[self.input_len] = @intCast(c);
                    self.input_len += 1;
                }
            },
            else => {},
        }
        return .none;
    }

    fn handleDeleteConfirmKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        switch (k.key) {
            .char => |c| switch (c) {
                'y', 'Y' => {
                    self.submitDeleteTorrent();
                    self.mode = .main;
                },
                'n', 'N' => self.mode = .main,
                'f', 'F' => self.delete_files = !self.delete_files,
                else => {},
            },
            .escape => self.mode = .main,
            else => {},
        }
        return .none;
    }

    fn handlePreferencesKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        switch (k.key) {
            .escape => {
                if (self.pref_editing) {
                    self.pref_editing = false;
                } else {
                    self.mode = .main;
                }
            },
            .char => |c| {
                if (self.pref_editing) {
                    if (c < 128 and self.pref_edit_len < self.pref_edit_buf.len - 1) {
                        self.pref_edit_buf[self.pref_edit_len] = @intCast(c);
                        self.pref_edit_len += 1;
                    }
                } else {
                    switch (c) {
                        'q' => self.mode = .main,
                        'j' => {
                            if (self.pref_selected < 11) self.pref_selected += 1;
                        },
                        'k' => {
                            if (self.pref_selected > 0) self.pref_selected -= 1;
                        },
                        else => {},
                    }
                }
            },
            .enter => {
                if (self.pref_editing) {
                    self.submitPreferenceEdit();
                    self.pref_editing = false;
                } else {
                    self.pref_editing = true;
                    self.pref_edit_len = 0;
                }
            },
            .backspace => {
                if (self.pref_editing and self.pref_edit_len > 0) {
                    self.pref_edit_len -= 1;
                }
            },
            .up => {
                if (!self.pref_editing and self.pref_selected > 0)
                    self.pref_selected -= 1;
            },
            .down => {
                if (!self.pref_editing and self.pref_selected < 11)
                    self.pref_selected += 1;
            },
            else => {},
        }
        return .none;
    }

    fn handleFilterKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        switch (k.key) {
            .escape => {
                self.mode = .main;
                self.filter_len = 0;
            },
            .enter => {
                self.mode = .main;
                self.selected = 0;
            },
            .backspace => {
                if (self.filter_len > 0) self.filter_len -= 1;
            },
            .char => |c| {
                if (c < 128 and self.filter_len < self.filter_buf.len - 1) {
                    self.filter_buf[self.filter_len] = @intCast(c);
                    self.filter_len += 1;
                }
            },
            else => {},
        }
        return .none;
    }

    fn handleLoginKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        switch (k.key) {
            .escape => {
                self.mode = .main;
                self.auth_mode = false;
            },
            .tab => {
                self.auth_field = if (self.auth_field == .username) .password else .username;
            },
            .enter => {
                self.submitLogin();
            },
            .backspace => {
                switch (self.auth_field) {
                    .username => {
                        if (self.auth_user_len > 0) self.auth_user_len -= 1;
                    },
                    .password => {
                        if (self.auth_pass_len > 0) self.auth_pass_len -= 1;
                    },
                }
            },
            .char => |c| {
                if (c < 128) {
                    switch (self.auth_field) {
                        .username => {
                            if (self.auth_user_len < self.auth_user_buf.len - 1) {
                                self.auth_user_buf[self.auth_user_len] = @intCast(c);
                                self.auth_user_len += 1;
                            }
                        },
                        .password => {
                            if (self.auth_pass_len < self.auth_pass_buf.len - 1) {
                                self.auth_pass_buf[self.auth_pass_len] = @intCast(c);
                                self.auth_pass_len += 1;
                            }
                        },
                    }
                }
            },
            else => {},
        }
        return .none;
    }

    // ── Action dispatch ─────────────────────────────────────────────

    fn enqueueAction(self: *Model, cmd: ActionCmd) void {
        self.shared.actions.push(cmd);
    }

    fn doPauseResume(self: *Model) void {
        const t = self.getSelectedTorrent() orelse return;
        var cmd = ActionCmd{};
        const is_paused = t.state == .pausedDL or t.state == .pausedUP;
        cmd.kind = if (is_paused) .@"resume" else .pause;
        const len = @min(t.hash.len, cmd.hash.len);
        @memcpy(cmd.hash[0..len], t.hash[0..len]);
        cmd.hash_len = len;
        self.enqueueAction(cmd);
    }

    fn submitAddTorrent(self: *Model) void {
        var cmd = ActionCmd{};
        cmd.kind = if (self.input_is_magnet) .add_magnet else .add_file;
        const len = @min(self.input_len, cmd.buf.len);
        @memcpy(cmd.buf[0..len], self.input_buf[0..len]);
        cmd.buf_len = len;
        self.enqueueAction(cmd);
    }

    fn submitDeleteTorrent(self: *Model) void {
        const t = self.getSelectedTorrent() orelse return;
        var cmd = ActionCmd{};
        cmd.kind = .delete;
        const len = @min(t.hash.len, cmd.hash.len);
        @memcpy(cmd.hash[0..len], t.hash[0..len]);
        cmd.hash_len = len;
        cmd.delete_files = self.delete_files;
        self.enqueueAction(cmd);
    }

    fn submitLogin(self: *Model) void {
        var cmd = ActionCmd{};
        cmd.kind = .login;
        // Pack username\0password into buf
        const ulen = self.auth_user_len;
        const plen = self.auth_pass_len;
        if (ulen + 1 + plen <= cmd.buf.len) {
            @memcpy(cmd.buf[0..ulen], self.auth_user_buf[0..ulen]);
            cmd.buf[ulen] = 0;
            @memcpy(cmd.buf[ulen + 1 ..][0..plen], self.auth_pass_buf[0..plen]);
            cmd.buf_len = ulen + 1 + plen;
        }
        self.enqueueAction(cmd);
    }

    fn enqueueDetailFetch(self: *Model) void {
        const t = self.getSelectedTorrent() orelse return;
        var cmd = ActionCmd{};
        cmd.kind = .fetch_detail;
        const len = @min(t.hash.len, cmd.hash.len);
        @memcpy(cmd.hash[0..len], t.hash[0..len]);
        cmd.hash_len = len;
        self.enqueueAction(cmd);
    }

    fn submitPreferenceEdit(self: *Model) void {
        // Build a JSON object with the single edited field
        const fields = [_][]const u8{
            "listen_port",             "dl_limit",               "up_limit",
            "max_connec",              "max_connec_per_torrent", "max_uploads",
            "max_uploads_per_torrent", "dht",                    "pex",
            "save_path",               "enable_utp",             "web_ui_port",
        };
        if (self.pref_selected >= fields.len) return;
        const field = fields[self.pref_selected];
        const val = self.pref_edit_buf[0..self.pref_edit_len];

        // Boolean fields
        const is_bool = std.mem.eql(u8, field, "dht") or
            std.mem.eql(u8, field, "pex") or
            std.mem.eql(u8, field, "enable_utp");
        // String fields
        const is_string = std.mem.eql(u8, field, "save_path");

        var cmd = ActionCmd{};
        cmd.kind = .set_preferences;
        if (is_bool) {
            const b_val: []const u8 = if (std.mem.eql(u8, val, "1") or
                std.ascii.eqlIgnoreCase(val, "true") or
                std.ascii.eqlIgnoreCase(val, "yes") or
                std.ascii.eqlIgnoreCase(val, "on")) "true" else "false";
            const json = std.fmt.bufPrint(&cmd.buf, "{{\"{s}\":{s}}}", .{ field, b_val }) catch return;
            cmd.buf_len = json.len;
        } else if (is_string) {
            const json = std.fmt.bufPrint(&cmd.buf, "{{\"{s}\":\"{s}\"}}", .{ field, val }) catch return;
            cmd.buf_len = json.len;
        } else {
            // Numeric
            const json = std.fmt.bufPrint(&cmd.buf, "{{\"{s}\":{s}}}", .{ field, val }) catch return;
            cmd.buf_len = json.len;
        }
        self.enqueueAction(cmd);
    }

    // ── Filtered torrent access ─────────────────────────────────────

    fn filteredTorrents(self: *const Model, alloc: Allocator) []const api_mod.TorrentInfo {
        if (self.filter_len == 0) return self.torrents;
        const filter = self.filter_buf[0..self.filter_len];
        var count: usize = 0;
        for (self.torrents) |t| {
            if (containsIgnoreCase(t.name, filter)) count += 1;
        }
        if (count == 0) return &[_]api_mod.TorrentInfo{};
        var list = alloc.alloc(api_mod.TorrentInfo, count) catch return self.torrents;
        var idx: usize = 0;
        for (self.torrents) |t| {
            if (containsIgnoreCase(t.name, filter)) {
                list[idx] = t;
                idx += 1;
            }
        }
        return list;
    }

    fn filteredCount(self: *const Model) usize {
        if (self.filter_len == 0) return self.torrents.len;
        const filter = self.filter_buf[0..self.filter_len];
        var count: usize = 0;
        for (self.torrents) |t| {
            if (containsIgnoreCase(t.name, filter)) count += 1;
        }
        return count;
    }

    fn getSelectedTorrent(self: *const Model) ?*const api_mod.TorrentInfo {
        if (self.filter_len > 0) {
            const filter = self.filter_buf[0..self.filter_len];
            var idx: usize = 0;
            for (self.torrents) |*t| {
                if (containsIgnoreCase(t.name, filter)) {
                    if (idx == self.selected) return t;
                    idx += 1;
                }
            }
            return null;
        }
        if (self.selected < self.torrents.len) return &self.torrents[self.selected];
        return null;
    }

    // ── View rendering ───────────────────────────────────────────────

    pub fn view(self: *const Model, ctx: *const zz.Context) []const u8 {
        const alloc = ctx.allocator;
        const w = ctx.width;
        const h = ctx.height;

        // Login dialog
        if (self.mode == .login) {
            return views.renderLoginDialog(
                alloc,
                &self.auth_user_buf,
                self.auth_user_len,
                &self.auth_pass_buf,
                self.auth_pass_len,
                self.auth_field == .username,
                self.auth_error,
                w,
                h,
            );
        }

        // Not connected - show error overlay
        if (!self.connected and self.mode == .main) {
            const title = views.renderTitleBar(alloc, w);
            const disconnected = views.renderDisconnected(alloc, self.host, self.port, w, h -| 2);
            const key_bar = views.renderKeyBar(alloc, w, self.mode);
            return std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}", .{ title, disconnected, key_bar }) catch "Disconnected";
        }

        switch (self.mode) {
            .main, .filter => {
                const title = views.renderTitleBar(alloc, w);
                const list_height = if (h > 4) h - 4 else 1;
                const display_torrents = self.filteredTorrents(alloc);
                const list = views.renderTorrentList(alloc, display_torrents, self.selected, w, list_height);
                const status = views.renderStatusBar(alloc, self.transfer_info, self.torrents.len, w, self.connected);
                const key_bar = views.renderKeyBar(alloc, w, self.mode);

                if (self.mode == .filter) {
                    const filter_line = std.fmt.allocPrint(alloc, " Filter: {s}", .{self.filter_buf[0..self.filter_len]}) catch "";
                    return std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}\n{s}\n{s}", .{ title, filter_line, list, status, key_bar }) catch "";
                }

                // Show last error if present
                if (self.last_error) |err| {
                    var err_style = zz.Style{};
                    err_style = err_style.fg(zz.Color.red());
                    err_style = err_style.inline_style(true);
                    const err_line = err_style.render(alloc, err) catch err;
                    return std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}\n {s}\n{s}", .{ title, list, status, err_line, key_bar }) catch "";
                }

                return std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}\n{s}", .{ title, list, status, key_bar }) catch "";
            },
            .details => {
                if (self.getSelectedTorrent()) |t| {
                    const title = views.renderTitleBar(alloc, w);
                    const detail = views.renderDetailView(
                        alloc,
                        t.*,
                        self.detail_files,
                        self.detail_trackers,
                        self.detail_props,
                        self.detail_tab,
                        w,
                        if (h > 4) h - 4 else 2,
                    );
                    const key_bar = views.renderKeyBar(alloc, w, self.mode);
                    return std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}", .{ title, detail, key_bar }) catch "";
                }
                const title = views.renderTitleBar(alloc, w);
                const key_bar = views.renderKeyBar(alloc, w, .main);
                return std.fmt.allocPrint(alloc, "{s}\n  No torrent selected\n{s}", .{ title, key_bar }) catch "";
            },
            .add_torrent => {
                return views.renderAddTorrentDialog(
                    alloc,
                    &self.input_buf,
                    self.input_len,
                    self.input_is_magnet,
                    self.input_error,
                    w,
                    h,
                );
            },
            .confirm_delete => {
                const name = if (self.getSelectedTorrent()) |t| t.name else "Unknown";
                return views.renderConfirmDeleteDialog(alloc, name, self.delete_files, w, h);
            },
            .preferences => {
                const title = views.renderTitleBar(alloc, w);
                const prefs = views.renderPreferencesView(
                    alloc,
                    self.preferences,
                    w,
                    if (h > 4) h - 4 else 2,
                    self.pref_selected,
                    self.pref_editing,
                    self.pref_edit_buf[0..self.pref_edit_len],
                );
                const key_bar = views.renderKeyBar(alloc, w, self.mode);
                return std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}", .{ title, prefs, key_bar }) catch "";
            },
            .login => unreachable, // handled above
        }
    }
};

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var match = true;
        for (0..needle.len) |j| {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) {
                match = false;
                break;
            }
        }
        if (match) return true;
    }
    return false;
}

// ── zio background poller ───────────────────────────────────────────
// Runs as a zio fiber: periodic polling + action dispatch.

fn zioPollerTask(shared: *SharedState) void {
    var arena_impl = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_impl.deinit();

    var client = api_mod.ApiClient.init(std.heap.page_allocator, shared.host, shared.port) catch {
        shared.results.push(.{ .connected = false });
        return;
    };
    defer client.deinit();

    while (shared.running.load(.acquire)) {
        // Process any pending actions first
        while (shared.actions.pop()) |cmd| {
            processAction(&client, shared, cmd, &arena_impl);
        }

        // Reset arena for this poll cycle
        _ = arena_impl.reset(.retain_capacity);
        const arena = arena_impl.allocator();

        // Poll torrent list + transfer info
        const torrents = client.getTorrents(arena) catch |err| {
            if (err == error.AuthRequired) {
                shared.results.push(.{ .connected = true, .auth_required = true });
                zio.sleep(zio.Duration.fromSeconds(2)) catch return;
                continue;
            }
            shared.results.push(.{ .connected = false });
            zio.sleep(zio.Duration.fromSeconds(3)) catch return;
            continue;
        };

        const transfer = client.getTransferInfo(arena) catch api_mod.TransferInfo{};

        shared.results.push(.{
            .torrents = torrents,
            .transfer = transfer,
            .connected = true,
        });

        // Sleep 2 seconds between polls
        zio.sleep(zio.Duration.fromSeconds(2)) catch return;
    }
}

fn processAction(client: *api_mod.ApiClient, shared: *SharedState, cmd: ActionCmd, arena_impl: *std.heap.ArenaAllocator) void {
    switch (cmd.kind) {
        .add_magnet => {
            const uri = cmd.buf[0..cmd.buf_len];
            const ok = client.addTorrentMagnet(uri) catch false;
            if (!ok) {
                shared.results.push(.{ .action_ok = false, .action_error = "Failed to add magnet" });
            }
        },
        .add_file => {
            const path = cmd.buf[0..cmd.buf_len];
            const ok = client.addTorrentFile(path) catch false;
            if (!ok) {
                shared.results.push(.{ .action_ok = false, .action_error = "Failed to add torrent file" });
            }
        },
        .delete => {
            const hash = cmd.hash[0..cmd.hash_len];
            const ok = client.deleteTorrent(hash, cmd.delete_files) catch false;
            if (!ok) {
                shared.results.push(.{ .action_ok = false, .action_error = "Failed to delete torrent" });
            }
        },
        .pause => {
            const hash = cmd.hash[0..cmd.hash_len];
            _ = client.pauseTorrent(hash) catch {};
        },
        .@"resume" => {
            const hash = cmd.hash[0..cmd.hash_len];
            _ = client.resumeTorrent(hash) catch {};
        },
        .fetch_detail => {
            _ = arena_impl.reset(.retain_capacity);
            const arena = arena_impl.allocator();
            const hash = cmd.hash[0..cmd.hash_len];
            const files = client.getTorrentFiles(arena, hash) catch &[_]api_mod.TorrentFile{};
            const trackers = client.getTorrentTrackers(arena, hash) catch &[_]api_mod.TrackerEntry{};
            const props = client.getTorrentProperties(arena, hash) catch api_mod.TorrentProperties{};
            shared.results.push(.{
                .detail_files = files,
                .detail_trackers = trackers,
                .detail_props = props,
            });
        },
        .fetch_preferences => {
            _ = arena_impl.reset(.retain_capacity);
            const arena = arena_impl.allocator();
            const prefs = client.getPreferences(arena) catch api_mod.Preferences{};
            shared.results.push(.{ .preferences = prefs });
        },
        .set_preferences => {
            const json = cmd.buf[0..cmd.buf_len];
            const ok = client.setPreferences(json) catch false;
            if (!ok) {
                shared.results.push(.{ .action_ok = false, .action_error = "Failed to set preferences" });
            } else {
                // Re-fetch preferences after change
                _ = arena_impl.reset(.retain_capacity);
                const arena = arena_impl.allocator();
                const prefs = client.getPreferences(arena) catch api_mod.Preferences{};
                shared.results.push(.{ .preferences = prefs });
            }
        },
        .login => {
            // Unpack username\0password
            const data = cmd.buf[0..cmd.buf_len];
            if (std.mem.indexOfScalar(u8, data, 0)) |sep| {
                const user = data[0..sep];
                const pass = data[sep + 1 ..];
                const ok = client.login(user, pass) catch false;
                if (!ok) {
                    shared.results.push(.{ .action_error = "Login failed" });
                } else {
                    shared.results.push(.{ .connected = true });
                }
            }
        },
        .none => {},
    }
}

// ── CLI argument parsing ─────────────────────────────────────────────

const CliConfig = struct {
    host: []const u8 = "127.0.0.1",
    port: u16 = 8080,
};

fn parseArgs(allocator: Allocator) CliConfig {
    var config = CliConfig{};
    var args = std.process.argsWithAllocator(allocator) catch return config;
    defer args.deinit();

    // Skip program name
    _ = args.next();

    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--host")) {
            if (args.next()) |host| {
                config.host = host;
            }
        } else if (std.mem.eql(u8, arg, "--port")) {
            if (args.next()) |port_str| {
                config.port = std.fmt.parseInt(u16, port_str, 10) catch 8080;
            }
        } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            const help_text =
                \\varuna-tui - Terminal UI for the varuna BitTorrent daemon
                \\
                \\Usage:
                \\  varuna-tui [OPTIONS]
                \\
                \\Options:
                \\  --host HOST    Daemon API host (default: 127.0.0.1)
                \\  --port PORT    Daemon API port (default: 8080)
                \\  --help, -h     Show this help message
                \\
                \\Key bindings:
                \\  q              Quit
                \\  j/k, Up/Down   Navigate torrent list
                \\  Enter          View torrent details
                \\  a              Add torrent (file path or magnet URI)
                \\  d, Delete      Delete selected torrent
                \\  p              Pause/Resume selected torrent
                \\  P              View/edit daemon preferences
                \\  /              Filter torrents by name
                \\  Tab            Switch detail tabs / toggle input fields
                \\  Esc            Go back / Cancel
                \\
            ;
            var stdout_buf: [4096]u8 = undefined;
            var writer = std.fs.File.stdout().writer(&stdout_buf);
            writer.interface.writeAll(help_text) catch {};
            writer.interface.flush() catch {};
            std.process.exit(0);
        }
    }

    return config;
}

// ── Entry point ──────────────────────────────────────────────────────

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const config = parseArgs(allocator);

    // Shared state between TUI main thread and zio poller
    var shared = SharedState{
        .host = config.host,
        .port = config.port,
    };

    // Initialize the zio runtime for async HTTP I/O.
    // Use 2 executors: executor 0 is the main thread (which we won't use
    // for zio), executor 1 is a worker thread running the event loop.
    // Force the round-robin counter to start at 1 so spawned tasks go
    // to the worker executor, not the main executor (which never runs).
    const rt = try zio.Runtime.init(std.heap.smp_allocator, .{
        .executors = .exact(2),
    });
    rt.next_executor_index.store(1, .monotonic);

    // Spawn the background poller as a zio fiber on the worker executor
    var poller_handle = try rt.spawn(zioPollerTask, .{&shared});

    // Initialize the zigzag TUI program
    var program = try zz.Program(Model).init(allocator);
    defer program.deinit();

    // Set the connection parameters on the model
    program.model.host = config.host;
    program.model.port = config.port;
    program.model.allocator = allocator;
    program.model.shared = &shared;
    program.model.data_arena = std.heap.ArenaAllocator.init(allocator);

    // Run the TUI event loop using start() + tick() for custom control
    try program.start();
    while (program.isRunning()) {
        try program.tick();
    }

    // Signal the poller to stop
    shared.running.store(false, .release);

    // Clean up the data arena
    program.model.data_arena.deinit();

    // Cancel the poller task
    poller_handle.cancel();

    // Shut down zio runtime
    rt.deinit();
}
