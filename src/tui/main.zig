//! varuna-tui: Terminal UI for the varuna BitTorrent daemon.
//!
//! An rtorrent-style TUI that communicates with the varuna daemon over
//! its qBittorrent-compatible WebAPI.  Uses zigzag for terminal rendering
//! (Elm Architecture) and zio for non-blocking HTTP API polling.
//!
//! Usage:
//!   varuna-tui [--host HOST] [--port PORT]

const std = @import("std");
const zz = @import("zigzag");
const zio = @import("zio");
const api_mod = @import("api.zig");
const views = @import("views.zig");

const Allocator = std.mem.Allocator;

// ── Application model (zigzag Elm Architecture) ──────────────────────

const Model = struct {
    // Connection settings
    host: []const u8,
    port: u16,
    allocator: Allocator,

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

    // Async runner for background HTTP polling
    async_runner: zz.AsyncRunner(Msg),

    // Error message display
    last_error: ?[]const u8,

    // Polling state
    poll_active: bool,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        tick: zz.msg.Tick,
        api_result: ApiResult,
        window_size: zz.msg.WindowSize,
    };

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
        self.last_error = null;
        self.poll_active = true;

        // Start periodic polling at 1500ms intervals
        return zz.Cmd(Msg).everyMs(1500);
    }

    pub fn update(self: *Model, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| return self.handleKey(k),
            .tick => return self.handleTick(),
            .api_result => |result| {
                self.applyApiResult(result);
                return .none;
            },
            .window_size => return .none,
        }
    }

    fn handleKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        switch (self.mode) {
            .main => return self.handleMainKey(k),
            .details => return self.handleDetailsKey(k),
            .add_torrent => return self.handleAddTorrentKey(k),
            .confirm_delete => return self.handleDeleteConfirmKey(k),
            .preferences => return self.handlePreferencesKey(k),
            .filter => return self.handleFilterKey(k),
        }
    }

    fn handleMainKey(self: *Model, k: zz.KeyEvent) zz.Cmd(Msg) {
        switch (k.key) {
            .char => |c| switch (c) {
                'q' => return .quit,
                'j' => {
                    if (self.torrents.len > 0 and self.selected < self.torrents.len - 1)
                        self.selected += 1;
                },
                'k' => {
                    if (self.selected > 0)
                        self.selected -= 1;
                },
                'a' => {
                    self.mode = .add_torrent;
                    self.input_len = 0;
                    self.input_is_magnet = false;
                    self.input_error = null;
                },
                'd' => {
                    if (self.torrents.len > 0) {
                        self.mode = .confirm_delete;
                        self.delete_files = false;
                    }
                },
                'p' => {
                    if (self.torrents.len > 0 and self.selected < self.torrents.len) {
                        const t = &self.torrents[self.selected];
                        self.togglePauseResume(t.hash, t.state);
                    }
                },
                'P' => {
                    self.mode = .preferences;
                    self.fetchPreferences();
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
                if (self.torrents.len > 0 and self.selected < self.torrents.len - 1)
                    self.selected += 1;
            },
            .enter => {
                if (self.torrents.len > 0 and self.selected < self.torrents.len) {
                    self.mode = .details;
                    self.detail_tab = .files;
                    self.fetchDetailData();
                }
            },
            .home => self.selected = 0,
            .end => {
                if (self.torrents.len > 0)
                    self.selected = self.torrents.len - 1;
            },
            .escape => return .quit,
            .delete => {
                if (self.torrents.len > 0) {
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
                'q' => {
                    self.mode = .main;
                },
                'd' => {
                    self.mode = .confirm_delete;
                    self.delete_files = false;
                },
                'p' => {
                    if (self.selected < self.torrents.len) {
                        const t = &self.torrents[self.selected];
                        self.togglePauseResume(t.hash, t.state);
                    }
                },
                else => {},
            },
            .escape => {
                self.mode = .main;
            },
            .tab => {
                self.detail_tab = switch (self.detail_tab) {
                    .files => .trackers,
                    .trackers => .info,
                    .info => .files,
                };
                self.fetchDetailData();
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
                // Only accept ASCII characters for file paths / magnet URIs
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
                    if (self.selected < self.torrents.len) {
                        self.submitDeleteTorrent(self.torrents[self.selected].hash, self.delete_files);
                    }
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
            .escape => self.mode = .main,
            .char => |c| {
                if (c == 'q') self.mode = .main;
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
            .enter => self.mode = .main,
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

    fn handleTick(self: *Model) zz.Cmd(Msg) {
        // Poll the API results from the async runner
        const results = self.async_runner.poll();
        for (results) |result| {
            switch (result) {
                .api_result => |r| self.applyApiResult(r),
                else => {},
            }
        }

        // Schedule the next background poll
        if (self.poll_active) {
            _ = self.async_runner.spawn(&pollDaemon);
        }

        return .none;
    }

    fn applyApiResult(self: *Model, result: ApiResult) void {
        self.connected = result.connected;

        if (result.torrents) |t| {
            self.torrents = t;
            if (self.selected >= t.len and t.len > 0) {
                self.selected = t.len - 1;
            }
        }
        if (result.transfer) |t| self.transfer_info = t;
        if (result.detail_files) |f| self.detail_files = f;
        if (result.detail_trackers) |t| self.detail_trackers = t;
        if (result.detail_props) |p| self.detail_props = p;
        if (result.preferences) |p| self.preferences = p;
        if (result.action_error) |err| self.last_error = err;
    }

    // ── Background API operations (run via AsyncRunner) ──────────

    fn togglePauseResume(self: *Model, hash: []const u8, state: []const u8) void {
        _ = self;
        _ = hash;
        _ = state;
        // In a full implementation, this would spawn an async task
        // to call pauseTorrent or resumeTorrent via the API client.
    }

    fn submitAddTorrent(self: *Model) void {
        _ = self;
        // In a full implementation, this would spawn an async task
        // to call addTorrentFile or addTorrentMagnet via the API client.
    }

    fn submitDeleteTorrent(self: *Model, hash: []const u8, delete_files: bool) void {
        _ = self;
        _ = hash;
        _ = delete_files;
        // In a full implementation, this would spawn an async task
        // to call deleteTorrent via the API client.
    }

    fn fetchDetailData(self: *Model) void {
        _ = self;
        // In a full implementation, this would trigger fetching
        // files, trackers, and properties for the selected torrent.
    }

    fn fetchPreferences(self: *Model) void {
        _ = self;
        // In a full implementation, this would trigger fetching
        // preferences from the daemon.
    }

    // ── Background polling task ──────────────────────────────────

    fn pollDaemon() ?Msg {
        // This function runs on a background thread (via AsyncRunner).
        // It creates a short-lived API client to poll the daemon.
        var client = api_mod.ApiClient.init(
            std.heap.page_allocator,
            "127.0.0.1",
            8080,
        ) catch return .{
            .api_result = .{ .connected = false },
        };
        defer client.deinit();

        // Try to fetch torrent list
        const torrents = client.getTorrents() catch {
            return .{ .api_result = .{ .connected = false } };
        };

        // Try to fetch transfer info
        const transfer = client.getTransferInfo() catch api_mod.TransferInfo{};

        return .{
            .api_result = .{
                .torrents = torrents,
                .transfer = transfer,
                .connected = true,
            },
        };
    }

    // ── View rendering ───────────────────────────────────────────

    pub fn view(self: *const Model, ctx: *const zz.Context) []const u8 {
        const alloc = ctx.allocator;
        const w = ctx.width;
        const h = ctx.height;

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
                const list = views.renderTorrentList(alloc, self.torrents, self.selected, w, list_height);
                const status = views.renderStatusBar(alloc, self.transfer_info, self.torrents.len, w, self.connected);
                const key_bar = views.renderKeyBar(alloc, w, self.mode);

                if (self.mode == .filter and self.filter_len > 0) {
                    const filter_line = std.fmt.allocPrint(alloc, " Filter: {s}", .{self.filter_buf[0..self.filter_len]}) catch "";
                    return std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}\n{s}\n{s}", .{ title, filter_line, list, status, key_bar }) catch "";
                }

                return std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}\n{s}", .{ title, list, status, key_bar }) catch "";
            },
            .details => {
                if (self.selected < self.torrents.len) {
                    const t = &self.torrents[self.selected];
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
                // Fallback to main view if no torrent selected
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
                const name = if (self.selected < self.torrents.len) self.torrents[self.selected].name else "Unknown";
                return views.renderConfirmDeleteDialog(alloc, name, self.delete_files, w, h);
            },
            .preferences => {
                const title = views.renderTitleBar(alloc, w);
                const prefs = views.renderPreferencesView(alloc, self.preferences, w, if (h > 4) h - 4 else 2);
                const key_bar = views.renderKeyBar(alloc, w, self.mode);
                return std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}", .{ title, prefs, key_bar }) catch "";
            },
        }
    }
};

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
            var stdout_buf: [4096]u8 = undefined;
            var writer = std.fs.File.stdout().writer(&stdout_buf);
            writer.interface.writeAll(
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
                \\  P              View daemon preferences
                \\  /              Filter torrents
                \\  Tab            Switch detail tabs (in detail view)
                \\  Esc            Go back / Cancel
                \\
            ) catch {};
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

    // Initialize the zio runtime (used by API client for async HTTP)
    const rt = try zio.Runtime.init(std.heap.smp_allocator, .{});
    defer rt.deinit();

    // Initialize the zigzag TUI program
    var program = try zz.Program(Model).init(allocator);
    defer program.deinit();

    // Set the connection parameters on the model before running
    // (Program.init calls Model.init, so we set these after)
    program.model.host = config.host;
    program.model.port = config.port;
    program.model.allocator = allocator;
    program.model.async_runner = zz.AsyncRunner(Model.Msg).init(std.heap.page_allocator);

    // Run the TUI event loop (blocks until quit)
    try program.run();
}
