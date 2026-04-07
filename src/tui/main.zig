/// varuna-tui: Terminal user interface for the varuna BitTorrent daemon.
///
/// Communicates with the daemon over the qBittorrent-compatible WebAPI.
/// Uses zigzag for terminal rendering and libxev as an available
/// event loop backend for future non-blocking I/O.
const std = @import("std");
const zz = @import("zigzag");
const xev = @import("xev");
const api = @import("api.zig");
const views = @import("views.zig");

const Allocator = std.mem.Allocator;

// ── File-scoped configuration set before Program.run() ───
var g_base_url: []const u8 = "http://127.0.0.1:8080";
var g_allocator: Allocator = undefined;

/// Application view mode.
const ViewMode = enum {
    main,
    detail,
    add_dialog,
    remove_dialog,
    preferences,
};

/// The main TUI model following zigzag's Elm architecture.
const Model = struct {
    // ── State ──────────────────────────────────────────
    api_client: api.ApiClient,
    mode: ViewMode,
    connected: bool,
    last_error: ?[]const u8,

    // Torrent list
    torrents: []api.TorrentInfo,
    transfer_info: api.TransferInfo,
    selected_index: usize,

    // Detail view
    detail_tab: views.DetailTab,
    detail_trackers: []api.TrackerEntry,
    detail_files: []api.FileEntry,
    detail_scroll: usize,

    // Add dialog
    input_buffer: [4096]u8,
    input_len: usize,

    // Remove dialog
    delete_files: bool,

    // Preferences
    prefs_json: []const u8,
    prefs_scroll: usize,

    // libxev loop handle (reserved for future async I/O)
    xev_loop: ?xev.Loop,

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
        self.prefs_scroll = 0;
        self.torrents = &.{};
        self.transfer_info = .{};
        self.detail_trackers = &.{};
        self.detail_files = &.{};
        self.prefs_json = "";

        // Initialize libxev loop (reserved for future non-blocking I/O)
        self.xev_loop = xev.Loop.init(.{}) catch null;

        // Start repeating tick every 2 seconds for API polling
        return zz.Cmd(Msg).everyMs(2000);
    }

    pub fn deinit(self: *Model) void {
        self.freeTorrents();
        self.freeTrackers();
        self.freeFiles();
        if (self.prefs_json.len > 0) {
            g_allocator.free(self.prefs_json);
        }
        self.api_client.deinit();
        if (self.xev_loop) |*loop| {
            loop.deinit();
        }
    }

    pub fn update(self: *Model, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| return self.handleKey(k),
            .tick => {
                // Perform synchronous API poll on each tick.
                // The TUI is not performance-critical (per AGENTS.md),
                // so blocking HTTP is acceptable here.
                self.pollDaemon();
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
                // Only accept ASCII characters for file paths and magnet links
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
                else => {},
            },
            .enter => {
                if (self.selected_index < self.torrents.len) {
                    const hash = self.torrents[self.selected_index].hash;
                    self.api_client.removeTorrent(g_allocator, hash, self.delete_files) catch {};
                }
                self.mode = .main;
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
    }

    fn pollDaemon(self: *Model) void {
        // Fetch torrent list
        if (self.api_client.fetchTorrents(g_allocator)) |torrents| {
            self.freeTorrents();
            self.torrents = torrents;
            self.connected = true;
            self.last_error = null;
            // Clamp selection
            if (self.selected_index >= self.torrents.len and self.torrents.len > 0) {
                self.selected_index = self.torrents.len - 1;
            }
        } else |err| {
            if (err == api.ApiError.ConnectionRefused) {
                self.connected = false;
                self.last_error = "Connection refused";
            }
        }

        // Fetch transfer stats
        if (self.api_client.fetchTransferInfo(g_allocator)) |transfer| {
            self.transfer_info = transfer;
        } else |_| {}

        // If in detail view, fetch detail data
        if (self.mode == .detail and self.selected_index < self.torrents.len) {
            const hash = self.torrents[self.selected_index].hash;
            if (self.api_client.fetchTrackers(g_allocator, hash)) |trackers| {
                self.freeTrackers();
                self.detail_trackers = trackers;
            } else |_| {}

            if (self.api_client.fetchFiles(g_allocator, hash)) |files| {
                self.freeFiles();
                self.detail_files = files;
            } else |_| {}
        }

        // If in preferences view, fetch prefs
        if (self.mode == .preferences) {
            if (self.api_client.fetchPreferences(g_allocator)) |prefs| {
                if (self.prefs_json.len > 0) {
                    g_allocator.free(self.prefs_json);
                }
                self.prefs_json = prefs;
            } else |_| {}
        }
    }

    fn freeTorrents(self: *Model) void {
        if (self.torrents.len == 0) return;
        for (self.torrents) |t| {
            g_allocator.free(t.name);
            g_allocator.free(t.hash);
            g_allocator.free(t.save_path);
            g_allocator.free(t.tracker);
            g_allocator.free(t.category);
        }
        g_allocator.free(self.torrents);
        self.torrents = &.{};
    }

    fn freeTrackers(self: *Model) void {
        if (self.detail_trackers.len == 0) return;
        for (self.detail_trackers) |t| {
            g_allocator.free(t.url);
            g_allocator.free(t.status);
            g_allocator.free(t.msg);
        }
        g_allocator.free(self.detail_trackers);
        self.detail_trackers = &.{};
    }

    fn freeFiles(self: *Model) void {
        if (self.detail_files.len == 0) return;
        for (self.detail_files) |f| {
            g_allocator.free(f.name);
        }
        g_allocator.free(self.detail_files);
        self.detail_files = &.{};
    }

    pub fn view(self: *const Model, ctx: *const zz.Context) []const u8 {
        const alloc = ctx.allocator;
        const w = ctx.width;
        const h = ctx.height;

        return switch (self.mode) {
            .main => self.renderMainView(alloc, w, h),
            .detail => self.renderDetailViewWrapper(alloc, w, h),
            .add_dialog => self.renderAddDialog(alloc, w, h),
            .remove_dialog => self.renderRemoveDialog(alloc, w, h),
            .preferences => views.renderPreferencesView(alloc, self.prefs_json, self.prefs_scroll, w, h),
        };
    }

    fn renderMainView(self: *const Model, alloc: Allocator, w: usize, h: usize) []const u8 {
        var parts = std.ArrayList(u8).empty;
        const writer = parts.writer(alloc);

        // Title bar
        const title_bar = views.renderTitleBar(alloc, w);
        writer.print("{s}\n", .{title_bar}) catch {};

        // Connection error banner
        if (!self.connected) {
            const err_bar = views.renderConnectionError(alloc, self.api_client.base_url, w);
            writer.print("{s}\n", .{err_bar}) catch {};
        }

        // Column headers
        const headers = views.renderColumnHeaders(alloc, w);
        writer.print("{s}\n", .{headers}) catch {};

        // Torrent rows
        if (self.torrents.len == 0) {
            // Calculate available space for empty state
            const used_lines: usize = if (self.connected) 5 else 6;
            const avail = if (h > used_lines) h - used_lines else 1;
            const empty = views.renderEmptyState(alloc, w, avail);
            writer.print("{s}", .{empty}) catch {};
        } else {
            // Calculate how many rows we can show
            const used_lines: usize = if (self.connected) 5 else 6;
            const avail_rows = if (h > used_lines) h - used_lines else 1;

            // Compute scroll window
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

            // Fill remaining space
            const rendered_rows = end_idx - start_idx;
            if (rendered_rows < avail_rows) {
                for (0..avail_rows - rendered_rows) |_| {
                    writer.print("\n", .{}) catch {};
                }
            }
        }

        // Status bar
        const status_bar = views.renderStatusBar(alloc, self.transfer_info, self.torrents.len, w);
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

    fn renderAddDialog(self: *const Model, alloc: Allocator, w: usize, h: usize) []const u8 {
        const input = self.input_buffer[0..self.input_len];
        return views.renderInputDialog(alloc, "Add Torrent (file path or magnet link):", input, w, h);
    }

    fn renderRemoveDialog(self: *const Model, alloc: Allocator, w: usize, h: usize) []const u8 {
        if (self.selected_index >= self.torrents.len) {
            return views.renderEmptyState(alloc, w, h);
        }
        const torrent = self.torrents[self.selected_index];
        return views.renderConfirmDialog(
            alloc,
            "Remove Torrent?",
            torrent.name,
            self.delete_files,
            w,
            h,
        );
    }
};

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

    // Initialize and run the zigzag program
    var program = try zz.Program(Model).init(allocator);
    defer program.deinit();

    try program.run();
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
