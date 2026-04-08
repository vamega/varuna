/// varuna-tui: Terminal user interface for the varuna BitTorrent daemon.
///
/// Communicates with the daemon over the qBittorrent-compatible WebAPI.
/// Uses zigzag for terminal rendering with start()/tick() for non-blocking
/// frame processing. A dedicated I/O thread executes HTTP requests via
/// std.http.Client, communicating results back through a thread-safe queue.
/// libxev provides the event notification layer: an Async handle wakes the
/// main loop when results arrive, and a Timer drives the 2-second poll
/// cadence. The UI thread never blocks on network I/O.
const std = @import("std");
const zz = @import("zigzag");
const xev = @import("xev");
const api = @import("api.zig");
const views = @import("views.zig");
const io_thread = @import("io_thread.zig");

const Allocator = std.mem.Allocator;

// ── File-scoped configuration set before Program start ─────────
var g_base_url: []const u8 = "http://127.0.0.1:8080";
var g_allocator: Allocator = undefined;

// ── Shared state between libxev callbacks and the Model ────────
// These file-scoped pointers let libxev completion callbacks (which
// receive only typed userdata) reach the queues and loop objects.
var g_request_queue: *io_thread.ThreadSafeQueue(io_thread.Request) = undefined;
var g_result_queue: *io_thread.ThreadSafeQueue(api.PollResult) = undefined;
var g_xev_loop: *xev.Loop = undefined;

/// The main TUI model following zigzag's Elm architecture.
const Model = struct {
    // ── State ──────────────────────────────────────────
    base_url: []const u8,
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

    // Async I/O state: poll results arrive from the I/O thread via
    // g_result_queue, signaled by the libxev Async handle.
    poll_in_flight: bool,

    pub const Msg = union(enum) {
        key: zz.KeyEvent,
        tick: zz.msg.Tick,
    };

    pub fn init(self: *Model, _: *zz.Context) zz.Cmd(Msg) {
        self.base_url = g_base_url;
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
        self.poll_in_flight = false;

        // Login state
        self.login_username = undefined;
        self.login_username_len = 0;
        self.login_password = undefined;
        self.login_password_len = 0;
        self.login_active_field = 0;
        self.login_error = null;

        // Start repeating tick every 100ms for responsive UI rendering.
        // Actual API polling is driven by a libxev Timer (2-second cadence)
        // and results arrive via the libxev Async handle -- neither blocks
        // the UI thread.
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
        // No API client to deinit -- the I/O thread owns it.
    }

    pub fn update(self: *Model, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |k| return self.handleKey(k),
            .tick => {
                // Drain any results the I/O thread has delivered.
                // The libxev Async callback also drains, but checking here
                // as well avoids a one-frame delay between async wakeup and
                // the next zigzag tick.
                self.drainResults();
                return .none;
            },
        }
    }

    /// Drain all pending results from the I/O thread's result queue.
    fn drainResults(self: *Model) void {
        while (g_result_queue.pop()) |result| {
            self.applyPollResult(result);
            self.poll_in_flight = false;
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
                    // Trigger immediate fetch of detail data.
                    self.poll_in_flight = false;
                    self.submitPollRequest();
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
                    var req = io_thread.ActionRequest{
                        .kind = .add_torrent,
                    };
                    const len = @min(self.input_len, req.data.len);
                    @memcpy(req.data[0..len], self.input_buffer[0..len]);
                    req.data_len = len;
                    g_request_queue.push(.{ .action = req }) catch {};
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
                        var req = io_thread.ActionRequest{
                            .kind = .remove_torrent,
                            .delete_files = self.delete_files,
                        };
                        const hlen = @min(hash.len, req.hash.len);
                        @memcpy(req.hash[0..hlen], hash[0..hlen]);
                        req.hash_len = hlen;
                        g_request_queue.push(.{ .action = req }) catch {};
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
                // Pack "username\x00password" into the action data buffer.
                var req = io_thread.ActionRequest{
                    .kind = .login,
                };
                const ulen = self.login_username_len;
                const plen = self.login_password_len;
                if (ulen + 1 + plen <= req.data.len) {
                    @memcpy(req.data[0..ulen], self.login_username[0..ulen]);
                    req.data[ulen] = 0; // separator
                    @memcpy(req.data[ulen + 1 .. ulen + 1 + plen], self.login_password[0..plen]);
                    req.data_len = ulen + 1 + plen;
                    g_request_queue.push(.{ .action = req }) catch {};
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

        const kind: io_thread.ActionKind = switch (t.state) {
            .pausedDL, .pausedUP => .resume_torrent,
            else => .pause_torrent,
        };

        var req = io_thread.ActionRequest{
            .kind = kind,
        };
        const hlen = @min(hash.len, req.hash.len);
        @memcpy(req.hash[0..hlen], hash[0..hlen]);
        req.hash_len = hlen;
        g_request_queue.push(.{ .action = req }) catch {};
    }

    // ── Async polling ────────────────────────────────────
    // Polling is driven by a libxev Timer (see pollTimerCallback in main()).
    // The timer fires every 2 seconds and posts a PollRequest to the I/O
    // thread. The I/O thread does the synchronous HTTP, posts the result
    // to the result queue, and signals the libxev Async handle to wake
    // the main loop.

    /// Build and enqueue a poll request for the I/O thread.
    fn submitPollRequest(self: *Model) void {
        if (self.poll_in_flight) return;
        self.poll_in_flight = true;

        var req = io_thread.PollRequest{
            .mode = switch (self.mode) {
                .detail => .detail,
                .preferences => .preferences,
                .main => .main,
                else => .other,
            },
            .prefs_loaded = self.prefs_loaded,
        };

        // Copy selected torrent hash for detail fetches.
        if (self.mode == .detail and self.selected_index < self.torrents.len) {
            const hash = self.torrents[self.selected_index].hash;
            const hlen = @min(hash.len, req.selected_hash.len);
            @memcpy(req.selected_hash[0..hlen], hash[0..hlen]);
            req.selected_hash_len = hlen;
        }

        g_request_queue.push(.{ .poll = req }) catch {
            self.poll_in_flight = false;
        };
    }

    fn applyPollResult(self: *Model, result: api.PollResult) void {
        // Handle auth requirement
        if (result.auth_required) {
            // If we are already on the login screen, show the error.
            if (self.mode == .login) {
                self.login_error = result.error_msg orelse "Invalid credentials";
            } else {
                self.mode = .login;
            }
            return;
        }

        // Update connection state
        if (result.connected) {
            self.connected = true;
            self.last_error = null;
            // If we were on the login screen and got a successful
            // result (no auth_required), the login succeeded.
            if (self.mode == .login) {
                self.mode = .main;
                self.login_error = null;
            }
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
            return views.renderDisconnected(alloc, self.base_url, w, h);
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

// ── libxev completion callbacks (file-scope for comptime fn ptrs) ──

/// Called when the libxev Async handle fires -- the I/O thread has posted
/// one or more results. We drain the queue here for minimal latency, then
/// rearm so we get notified again next time.
fn asyncResultCallback(
    _: ?*Model,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Async.WaitError!void,
) xev.CallbackAction {
    _ = r catch {};
    // Results are drained in Model.update() on the next tick.
    // Rearm so we keep getting notifications.
    return .rearm;
}

/// Called every 2 seconds by the libxev Timer. Posts a poll request to the
/// I/O thread.  Returns .rearm so the timer repeats indefinitely.
fn pollTimerCallback(
    model: ?*Model,
    _: *xev.Loop,
    _: *xev.Completion,
    r: xev.Timer.RunError!void,
) xev.CallbackAction {
    _ = r catch return .rearm;
    if (model) |m| {
        m.submitPollRequest();
    }
    return .rearm;
}

/// Application entry point.
///
/// Architecture:
///   main thread:  libxev loop.run(.no_wait) + zigzag program.tick()
///   I/O thread:   blocks on request queue, does synchronous HTTP, posts
///                 results to result queue, signals libxev Async handle
///
/// libxev is used for:
///   - Async handle: cross-thread wakeup when I/O results are ready
///   - Timer: 2-second poll cadence without blocking or manual counters
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

    // ── libxev event loop ───────────────────────────────────
    var loop = try xev.Loop.init(.{});
    defer loop.deinit();
    g_xev_loop = &loop;

    // ── Thread-safe queues ──────────────────────────────────
    var request_queue = io_thread.ThreadSafeQueue(io_thread.Request).init(allocator);
    defer request_queue.deinit();
    var result_queue = io_thread.ThreadSafeQueue(api.PollResult).init(allocator);
    defer result_queue.deinit();
    g_request_queue = &request_queue;
    g_result_queue = &result_queue;

    // ── libxev Async handle (I/O thread -> main thread wakeup) ──
    var async_handle = try xev.Async.init();
    defer async_handle.deinit();

    // ── I/O thread ──────────────────────────────────────────
    var io = io_thread.IoThread.init(
        allocator,
        base_url,
        &request_queue,
        &result_queue,
        async_handle,
    );
    defer io.deinit();
    try io.start();
    defer io.stop();

    // ── zigzag program (non-blocking start) ─────────────────
    var program = try zz.Program(Model).init(allocator);
    defer program.deinit();
    try program.start();

    // Get a pointer to the Model so we can pass it as userdata to
    // libxev callbacks. zigzag's Program stores the model inline.
    const model_ptr: *Model = &program.model;

    // ── Register libxev Async wait (rearms in the callback) ─
    var async_completion: xev.Completion = .{};
    async_handle.wait(&loop, &async_completion, Model, model_ptr, asyncResultCallback);

    // ── Register libxev Timer for 2-second poll cadence ─────
    var timer = try xev.Timer.init();
    defer timer.deinit();
    var timer_completion: xev.Completion = .{};
    timer.run(&loop, &timer_completion, 2000, Model, model_ptr, pollTimerCallback);

    // Fire an immediate first poll so the UI doesn't start empty.
    model_ptr.submitPollRequest();

    // ── Main event loop ─────────────────────────────────────
    // 1. Process libxev events (async wakeups, timer fires) -- non-blocking
    // 2. Process one zigzag frame (terminal input, Model.update, render)
    while (program.isRunning()) {
        loop.run(.no_wait) catch {};
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
