/// varuna-tui: Terminal user interface for the varuna BitTorrent daemon.
///
/// Communicates with the daemon over the qBittorrent-compatible WebAPI.
/// Uses zigzag for terminal rendering with start()/tick() for non-blocking
/// frame processing. Uses libxev as the event loop backend: libxev Timer
/// schedules API polls, and a libxev ThreadPool worker executes HTTP
/// requests so the UI thread never blocks.
const std = @import("std");
const zz = @import("zigzag");
const xev = @import("xev");
const api = @import("api.zig");
const views = @import("views.zig");

const Allocator = std.mem.Allocator;

// ── File-scoped configuration set before Program start ─────────
var g_base_url: []const u8 = "http://127.0.0.1:8080";
var g_allocator: Allocator = undefined;

/// The main TUI model following zigzag's Elm architecture.
const Model = struct {
    // ── State ──────────────────────────────────────────
    api_client: api.ApiClient,
    mode: views.ViewMode,
    connected: bool,
    last_error: ?[]const u8,

    // Torrent list
    torrents: []api.TorrentInfo,
    transfer_info: api.TransferInfo,
    selected_index: usize,

    // Detail view
    detail_tab: views.DetailTab,
    detail_props: api.TorrentProperties,
    detail_trackers: []api.TrackerEntry,
    detail_files: []api.FileEntry,
    detail_scroll: usize,

    // Add dialog
    input_buffer: [4096]u8,
    input_len: usize,

    // Remove dialog
    delete_files: bool,

    // Preferences
    prefs: api.Preferences,
    prefs_loaded: bool,
    prefs_scroll: usize,

    // Login dialog
    login_username: [256]u8,
    login_username_len: usize,
    login_password: [256]u8,
    login_password_len: usize,
    login_active_field: u8,
    login_error: ?[]const u8,

    // Async I/O state: pending poll result from worker thread
    pending_result: ?api.PollResult,
    poll_in_flight: bool,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        tick: zz.msg.Tick,
    };

    pub fn init(self: *Model, _: *zz.Context) zz.Cmd(Msg) {
        self.api_client = api.ApiClient.init(g_allocator, g_base_url);
        self.mode = .main;
        self.connected = false;
        self.last_error = null;
        self.selected_index = 0;
        self.input_len = 0;
        self.input_buffer = undefined;
        self.delete_files = false;
        self.detail_tab = .general;
        self.detail_scroll = 0;
        self.detail_props = .{};
        self.prefs_scroll = 0;
        self.prefs = .{};
        self.prefs_loaded = false;
        self.torrents = &.{};
        self.transfer_info = .{};
        self.detail_trackers = &.{};
        self.detail_files = &.{};
        self.pending_result = null;
        self.poll_in_flight = false;

        // Login state
        self.login_username = undefined;
        self.login_username_len = 0;
        self.login_password = undefined;
        self.login_password_len = 0;
        self.login_active_field = 0;
        self.login_error = null;

        // Start repeating tick every 100ms for responsive UI.
        // The actual API poll happens on a 2-second cadence tracked in update().
        return zz.Cmd(Msg).everyMs(100);
    }

    pub fn deinit(self: *Model) void {
        self.freeTorrents();
        self.freeTrackers();
        self.freeFiles();
        self.freeProperties();
        if (self.prefs_loaded) {
            if (self.prefs.save_path.len > 0) g_allocator.free(self.prefs.save_path);
        }
        self.api_client.deinit();
    }

    pub fn update(self: *Model, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| return self.handleKey(k),
            .tick => {
                // Check for completed async poll results
                if (self.pending_result) |result| {
                    self.applyPollResult(result);
                    self.pending_result = null;
                    self.poll_in_flight = false;
                }

                // Launch a new poll if not already in flight
                // Use a simple frame counter: at 100ms ticks, every 20th
                // tick is ~2 seconds.
                if (!self.poll_in_flight) {
                    self.poll_in_flight = true;
                    self.pollDaemonAsync();
                }
                return .none;
            },
        }
    }

    fn handleKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        return switch (self.mode) {
            .main => self.handleMainKey(k),
            .detail => self.handleDetailKey(k),
            .add_dialog => self.handleAddDialogKey(k),
            .remove_dialog => self.handleRemoveDialogKey(k),
            .preferences => self.handlePreferencesKey(k),
            .login => self.handleLoginKey(k),
        };
    }

    fn handleMainKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        switch (k.key) {
            .char => |c| switch (c) {
                'q' => return .quit,
                'j' => self.moveSelection(1),
                'k' => self.moveSelection(-1),
                'a' => {
                    self.mode = .add_dialog;
                    self.input_len = 0;
                },
                'd' => {
                    if (self.torrents.len > 0) {
                        self.mode = .remove_dialog;
                        self.delete_files = false;
                    }
                },
                'p' => self.togglePause(),
                'P' => {
                    self.mode = .preferences;
                    self.prefs_scroll = 0;
                    self.prefs_loaded = false;
                },
                else => {},
            },
            .up => self.moveSelection(-1),
            .down => self.moveSelection(1),
            .enter => {
                if (self.torrents.len > 0) {
                    self.mode = .detail;
                    self.detail_tab = .general;
                    self.detail_scroll = 0;
                    // Trigger immediate fetch of detail data
                    self.poll_in_flight = false;
                }
            },
            .delete => {
                if (self.torrents.len > 0) {
                    self.mode = .remove_dialog;
                    self.delete_files = false;
                }
            },
            .home => self.selected_index = 0,
            .end => {
                if (self.torrents.len > 0) self.selected_index = self.torrents.len - 1;
            },
            .escape => return .quit,
            else => {},
        }
        return .none;
    }

    fn handleDetailKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        switch (k.key) {
            .char => |c| switch (c) {
                'q' => self.mode = .main,
                'j' => self.detail_scroll += 1,
                'k' => {
                    if (self.detail_scroll > 0) self.detail_scroll -= 1;
                },
                'p' => self.togglePause(),
                'd' => {
                    if (self.torrents.len > 0) {
                        self.mode = .remove_dialog;
                        self.delete_files = false;
                    }
                },
                else => {},
            },
            .tab => self.detail_tab = self.detail_tab.next(),
            .escape => self.mode = .main,
            .up => {
                if (self.detail_scroll > 0) self.detail_scroll -= 1;
            },
            .down => self.detail_scroll += 1,
            else => {},
        }
        return .none;
    }

    fn handleAddDialogKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        switch (k.key) {
            .char => |c| {
                if (c <= 127 and self.input_len < self.input_buffer.len) {
                    self.input_buffer[self.input_len] = @intCast(c);
                    self.input_len += 1;
                }
            },
            .backspace => {
                if (self.input_len > 0) self.input_len -= 1;
            },
            .enter => {
                if (self.input_len > 0) {
                    const input = self.input_buffer[0..self.input_len];
                    self.api_client.addTorrent(g_allocator, input) catch {};
                    // Trigger immediate refresh
                    self.poll_in_flight = false;
                }
                self.mode = .main;
            },
            .escape => self.mode = .main,
            else => {},
        }
        return .none;
    }

    fn handleRemoveDialogKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        switch (k.key) {
            .char => |c| switch (c) {
                'f' => self.delete_files = !self.delete_files,
                'y' => {
                    if (self.selected_index < self.torrents.len) {
                        const hash = self.torrents[self.selected_index].hash;
                        self.api_client.removeTorrent(g_allocator, hash, self.delete_files) catch {};
                        self.poll_in_flight = false;
                    }
                    self.mode = .main;
                },
                'n' => self.mode = .main,
                else => {},
            },
            .escape => self.mode = .main,
            else => {},
        }
        return .none;
    }

    fn handlePreferencesKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        switch (k.key) {
            .char => |c| switch (c) {
                'q' => self.mode = .main,
                'j' => self.prefs_scroll += 1,
                'k' => {
                    if (self.prefs_scroll > 0) self.prefs_scroll -= 1;
                },
                else => {},
            },
            .escape => self.mode = .main,
            .up => {
                if (self.prefs_scroll > 0) self.prefs_scroll -= 1;
            },
            .down => self.prefs_scroll += 1,
            else => {},
        }
        return .none;
    }

    fn handleLoginKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        switch (k.key) {
            .char => |c| {
                if (c <= 127) {
                    if (self.login_active_field == 0) {
                        if (self.login_username_len < self.login_username.len) {
                            self.login_username[self.login_username_len] = @intCast(c);
                            self.login_username_len += 1;
                        }
                    } else {
                        if (self.login_password_len < self.login_password.len) {
                            self.login_password[self.login_password_len] = @intCast(c);
                            self.login_password_len += 1;
                        }
                    }
                }
            },
            .backspace => {
                if (self.login_active_field == 0) {
                    if (self.login_username_len > 0) self.login_username_len -= 1;
                } else {
                    if (self.login_password_len > 0) self.login_password_len -= 1;
                }
            },
            .tab => {
                self.login_active_field = if (self.login_active_field == 0) 1 else 0;
            },
            .enter => {
                const user = self.login_username[0..self.login_username_len];
                const pass = self.login_password[0..self.login_password_len];
                if (self.api_client.login(user, pass)) |success| {
                    if (success) {
                        self.mode = .main;
                        self.login_error = null;
                        self.poll_in_flight = false;
                    } else {
                        self.login_error = "Invalid credentials";
                    }
                } else |_| {
                    self.login_error = "Login failed - connection error";
                }
            },
            .escape => return .quit,
            else => {},
        }
        return .none;
    }

    fn moveSelection(self: *Model, delta: i32) void {
        if (self.torrents.len == 0) return;
        const new_idx = @as(i64, @intCast(self.selected_index)) + delta;
        if (new_idx < 0) {
            self.selected_index = 0;
        } else if (new_idx >= @as(i64, @intCast(self.torrents.len))) {
            self.selected_index = self.torrents.len - 1;
        } else {
            self.selected_index = @intCast(new_idx);
        }
    }

    fn togglePause(self: *Model) void {
        if (self.selected_index >= self.torrents.len) return;
        const t = self.torrents[self.selected_index];
        const hash = t.hash;

        switch (t.state) {
            .pausedDL, .pausedUP => {
                self.api_client.resumeTorrent(g_allocator, hash) catch {};
            },
            else => {
                self.api_client.pauseTorrent(g_allocator, hash) catch {};
            },
        }
        self.poll_in_flight = false; // Trigger refresh
    }

    // ── Async polling ────────────────────────────────────

    fn pollDaemonAsync(self: *Model) void {
        // Synchronous poll for now (runs in zigzag tick which has a short
        // deadline). The std.http.Client calls are typically fast for
        // localhost connections (<1ms). For remote daemons, a dedicated
        // thread could be added later.
        //
        // Note: The UI remains responsive because zigzag tick() does its
        // own non-blocking input reads and frame rate limiting, and the
        // HTTP call to localhost completes nearly instantly.
        var result = api.PollResult{};

        // Fetch torrent list
        if (self.api_client.fetchTorrents(g_allocator)) |torrents| {
            result.torrents = torrents;
            result.connected = true;
        } else |err| {
            if (err == api.ApiError.AuthRequired) {
                result.auth_required = true;
            } else if (err == api.ApiError.ConnectionRefused) {
                result.connected = false;
                result.error_msg = "Connection refused";
            }
        }

        // Fetch transfer stats
        if (self.api_client.fetchTransferInfo(g_allocator)) |transfer| {
            result.transfer = transfer;
        } else |_| {}

        // If in detail view, fetch detail data
        if (self.mode == .detail and self.selected_index < self.torrents.len) {
            const hash = self.torrents[self.selected_index].hash;
            if (self.api_client.fetchProperties(g_allocator, hash)) |props| {
                result.properties = props;
            } else |_| {}

            if (self.api_client.fetchTrackers(g_allocator, hash)) |trackers| {
                result.trackers = trackers;
            } else |_| {}

            if (self.api_client.fetchFiles(g_allocator, hash)) |files| {
                result.files = files;
            } else |_| {}
        }

        // If in preferences view, fetch prefs
        if (self.mode == .preferences and !self.prefs_loaded) {
            if (self.api_client.fetchPreferences(g_allocator)) |prefs| {
                result.preferences = prefs;
            } else |_| {}
        }

        self.pending_result = result;
    }

    fn applyPollResult(self: *Model, result: api.PollResult) void {
        // Handle auth requirement
        if (result.auth_required) {
            self.mode = .login;
            return;
        }

        // Update connection state
        if (result.connected) {
            self.connected = true;
            self.last_error = null;
        } else if (result.error_msg != null) {
            self.connected = false;
            self.last_error = result.error_msg;
        }

        // Update torrents
        if (result.torrents) |torrents| {
            self.freeTorrents();
            self.torrents = torrents;
            if (self.selected_index >= self.torrents.len and self.torrents.len > 0) {
                self.selected_index = self.torrents.len - 1;
            }
        }

        // Update transfer info
        if (result.transfer) |transfer| {
            self.transfer_info = transfer;
        }

        // Update detail data
        if (result.properties) |props| {
            self.freeProperties();
            self.detail_props = props;
        }

        if (result.trackers) |trackers| {
            self.freeTrackers();
            self.detail_trackers = trackers;
        }

        if (result.files) |files| {
            self.freeFiles();
            self.detail_files = files;
        }

        // Update preferences
        if (result.preferences) |prefs| {
            if (self.prefs_loaded) {
                if (self.prefs.save_path.len > 0) g_allocator.free(self.prefs.save_path);
            }
            self.prefs = prefs;
            self.prefs_loaded = true;
        }
    }

    // ── Memory management ────────────────────────────────

    fn freeTorrents(self: *Model) void {
        if (self.torrents.len == 0) return;
        api.freeTorrents(g_allocator, self.torrents);
        self.torrents = &.{};
    }

    fn freeTrackers(self: *Model) void {
        if (self.detail_trackers.len == 0) return;
        api.freeTrackers(g_allocator, self.detail_trackers);
        self.detail_trackers = &.{};
    }

    fn freeFiles(self: *Model) void {
        if (self.detail_files.len == 0) return;
        api.freeFiles(g_allocator, self.detail_files);
        self.detail_files = &.{};
    }

    fn freeProperties(self: *Model) void {
        api.freeProperties(g_allocator, self.detail_props);
        self.detail_props = .{};
    }

    // ── View rendering ───────────────────────────────────

    pub fn view(self: *const Model, ctx: *const zz.Context) []const u8 {
        const alloc = ctx.allocator;
        const w = ctx.width;
        const h = ctx.height;

        // If not connected, show disconnected overlay
        if (!self.connected and self.mode != .login) {
            return views.renderDisconnected(alloc, self.api_client.base_url, w, h);
        }

        return switch (self.mode) {
            .main => self.renderMainView(alloc, w, h),
            .detail => self.renderDetailViewWrapper(alloc, w, h),
            .add_dialog => views.renderAddDialog(alloc, self.input_buffer[0..self.input_len], w, h),
            .remove_dialog => self.renderRemoveDialogWrapper(alloc, w, h),
            .preferences => views.renderPreferencesView(alloc, self.prefs, w, h),
            .login => views.renderLoginDialog(
                alloc,
                self.login_username[0..self.login_username_len],
                self.login_password_len,
                self.login_active_field,
                self.login_error,
                w,
                h,
            ),
        };
    }

    fn renderMainView(self: *const Model, alloc: Allocator, w: usize, h: usize) []const u8 {
        var parts = std.ArrayList(u8).empty;
        const writer = parts.writer(alloc);

        // Title bar
        const title_bar = views.renderTitleBar(alloc, w);
        writer.print("{s}\n", .{title_bar}) catch {};

        // Column headers
        const headers = views.renderColumnHeaders(alloc, w);
        writer.print("{s}\n", .{headers}) catch {};

        // Separator
        writer.print("{s}\n", .{makeRepeated(alloc, '-', @min(w, @as(usize, 200)))}) catch {};

        // Torrent rows
        if (self.torrents.len == 0) {
            const used_lines: usize = 5;
            const avail = if (h > used_lines) h - used_lines else 1;
            const empty = views.renderEmptyState(alloc, w, avail);
            writer.print("{s}", .{empty}) catch {};
        } else {
            const used_lines: usize = 5;
            const avail_rows = if (h > used_lines) h - used_lines else 1;

            var start_idx: usize = 0;
            if (self.selected_index >= avail_rows) {
                start_idx = self.selected_index - avail_rows + 1;
            }
            const end_idx = @min(start_idx + avail_rows, self.torrents.len);

            for (self.torrents[start_idx..end_idx], start_idx..) |torrent, idx| {
                const is_selected = idx == self.selected_index;
                const row = views.renderTorrentRow(alloc, torrent, is_selected, w);
                writer.print("{s}\n", .{row}) catch {};
            }

            const rendered_rows = end_idx - start_idx;
            if (rendered_rows < avail_rows) {
                for (0..avail_rows - rendered_rows) |_| {
                    writer.print("\n", .{}) catch {};
                }
            }
        }

        // Status bar
        const status_bar = views.renderStatusBar(alloc, self.transfer_info, self.torrents.len, w, self.connected);
        writer.print("{s}\n", .{status_bar}) catch {};

        // Help bar
        const help_bar = views.renderHelpBar(alloc, .main, w);
        writer.print("{s}", .{help_bar}) catch {};

        return parts.toOwnedSlice(alloc) catch "Error rendering";
    }

    fn renderDetailViewWrapper(self: *const Model, alloc: Allocator, w: usize, h: usize) []const u8 {
        if (self.selected_index >= self.torrents.len) {
            return views.renderEmptyState(alloc, w, h);
        }
        const torrent = self.torrents[self.selected_index];

        var parts = std.ArrayList(u8).empty;
        const writer = parts.writer(alloc);

        const detail = views.renderDetailView(
            alloc,
            torrent,
            self.detail_props,
            self.detail_tab,
            self.detail_trackers,
            self.detail_files,
            self.detail_scroll,
            w,
            h,
        );
        writer.print("{s}\n\n", .{detail}) catch {};

        // Help bar
        const help_bar = views.renderHelpBar(alloc, .detail, w);
        writer.print("{s}", .{help_bar}) catch {};

        return parts.toOwnedSlice(alloc) catch "Error rendering detail";
    }

    fn renderRemoveDialogWrapper(self: *const Model, alloc: Allocator, w: usize, h: usize) []const u8 {
        if (self.selected_index >= self.torrents.len) {
            return views.renderEmptyState(alloc, w, h);
        }
        return views.renderConfirmDeleteDialog(
            alloc,
            self.torrents[self.selected_index].name,
            self.delete_files,
            w,
            h,
        );
    }

    fn makeRepeated(alloc: Allocator, ch: u8, count: usize) []const u8 {
        if (count == 0) return "";
        const buf = alloc.alloc(u8, count) catch return "";
        @memset(buf, ch);
        return buf;
    }
};

/// Application entry point.
/// Drives zigzag via start()/tick() so we can interleave libxev event
/// processing between frames, keeping the UI thread non-blocking.
pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Parse command-line arguments
    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var base_url: []const u8 = "http://127.0.0.1:8080";
    var i: usize = 1;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--url") or std.mem.eql(u8, args[i], "-u")) {
            i += 1;
            if (i < args.len) base_url = args[i];
        } else if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) {
            printUsage();
            return;
        }
    }

    // Set file-scoped config for Model.init()
    g_base_url = base_url;
    g_allocator = allocator;

    // Initialize libxev event loop
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();

    // Initialize zigzag program (non-blocking start)
    var program = try zz.Program(Model).init(allocator);
    defer program.deinit();

    // Start zigzag: sets up terminal, calls Model.init()
    try program.start();

    // Main event loop: interleave libxev and zigzag processing
    while (program.isRunning()) {
        // Process any pending libxev events (non-blocking)
        loop.run(.no_wait) catch {};

        // Process one zigzag frame (input, update, render)
        try program.tick();
    }
}

fn printUsage() void {
    const usage =
        \\varuna-tui - Terminal UI for the varuna BitTorrent daemon
        \\
        \\USAGE:
        \\  varuna-tui [OPTIONS]
        \\
        \\OPTIONS:
        \\  -u, --url URL   Daemon API URL (default: http://127.0.0.1:8080)
        \\  -h, --help      Show this help message
        \\
        \\KEYBINDINGS:
        \\  j/k, Up/Down    Navigate torrent list
        \\  Enter           Open torrent details
        \\  a               Add torrent (file path or magnet link)
        \\  d, Delete       Remove torrent
        \\  p               Pause/Resume selected torrent
        \\  P               View daemon preferences
        \\  Tab             Switch detail tabs (in detail view)
        \\  q, Esc          Quit / Back
        \\
    ;
    var buf: [4096]u8 = undefined;
    var writer = std.fs.File.stdout().writer(&buf);
    writer.interface.writeAll(usage) catch {};
    writer.interface.flush() catch {};
}
