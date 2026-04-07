/// TUI view components for varuna-tui.
/// Uses zigzag for terminal rendering with an rtorrent-inspired layout.
const std = @import("std");
const zz = @import("zigzag");
const api = @import("api.zig");

const Allocator = std.mem.Allocator;

// ── Style constants ──────────────────────────────────────

const header_style = blk: {
    var s = zz.Style{};
    s = s.bold(true);
    s = s.fg(zz.Color.white());
    s = s.bg(zz.Color.fromRgb(30, 30, 60));
    s = s.inline_style(true);
    break :blk s;
};

const selected_style = blk: {
    var s = zz.Style{};
    s = s.bold(true);
    s = s.fg(zz.Color.white());
    s = s.bg(zz.Color.fromRgb(40, 60, 100));
    s = s.inline_style(true);
    break :blk s;
};

const normal_style = blk: {
    var s = zz.Style{};
    s = s.fg(zz.Color.gray(18));
    s = s.inline_style(true);
    break :blk s;
};

const dim_style = blk: {
    var s = zz.Style{};
    s = s.fg(zz.Color.gray(10));
    s = s.inline_style(true);
    break :blk s;
};

const speed_dl_style = blk: {
    var s = zz.Style{};
    s = s.fg(zz.Color.green());
    s = s.inline_style(true);
    break :blk s;
};

const speed_ul_style = blk: {
    var s = zz.Style{};
    s = s.fg(zz.Color.cyan());
    s = s.inline_style(true);
    break :blk s;
};

const error_style = blk: {
    var s = zz.Style{};
    s = s.fg(zz.Color.red());
    s = s.bold(true);
    s = s.inline_style(true);
    break :blk s;
};

const title_style = blk: {
    var s = zz.Style{};
    s = s.bold(true);
    s = s.fg(zz.Color.cyan());
    s = s.inline_style(true);
    break :blk s;
};

const status_bar_style = blk: {
    var s = zz.Style{};
    s = s.fg(zz.Color.white());
    s = s.bg(zz.Color.fromRgb(25, 25, 50));
    s = s.inline_style(true);
    break :blk s;
};

const help_bar_style = blk: {
    var s = zz.Style{};
    s = s.fg(zz.Color.gray(14));
    s = s.bg(zz.Color.fromRgb(20, 20, 40));
    s = s.inline_style(true);
    break :blk s;
};

const progress_done_style = blk: {
    var s = zz.Style{};
    s = s.fg(zz.Color.green());
    s = s.inline_style(true);
    break :blk s;
};

const progress_remaining_style = blk: {
    var s = zz.Style{};
    s = s.fg(zz.Color.gray(6));
    s = s.inline_style(true);
    break :blk s;
};

/// Render the title bar at the top of the screen.
pub fn renderTitleBar(alloc: Allocator, width: usize) []const u8 {
    const version = "varuna-tui v0.1.0";
    const padding = if (width > version.len) width - version.len else 0;

    var title_s = zz.Style{};
    title_s = title_s.bold(true);
    title_s = title_s.fg(zz.Color.cyan());
    title_s = title_s.bg(zz.Color.fromRgb(20, 20, 50));
    title_s = title_s.inline_style(true);

    const styled_title = title_s.render(alloc, version) catch version;
    const pad_str = repeatChar(alloc, ' ', padding);

    var bg_s = zz.Style{};
    bg_s = bg_s.bg(zz.Color.fromRgb(20, 20, 50));
    bg_s = bg_s.inline_style(true);
    const styled_pad = bg_s.render(alloc, pad_str) catch pad_str;

    return std.fmt.allocPrint(alloc, "{s}{s}", .{ styled_title, styled_pad }) catch version;
}

/// Render the column header row for the torrent list.
pub fn renderColumnHeaders(alloc: Allocator, width: usize) []const u8 {
    const cols = formatTorrentColumns(alloc, "Name", "Size", "Progress", "Down", "Up", "Seeds", "Peers", "ETA", "Status", width);
    return header_style.render(alloc, cols) catch cols;
}

/// Render a single torrent row.
pub fn renderTorrentRow(alloc: Allocator, t: api.TorrentInfo, selected: bool, width: usize) []const u8 {
    var size_buf: [32]u8 = undefined;
    var dl_buf: [32]u8 = undefined;
    var ul_buf: [32]u8 = undefined;
    var eta_buf: [32]u8 = undefined;
    var prog_buf: [16]u8 = undefined;
    var seeds_buf: [16]u8 = undefined;
    var peers_buf: [16]u8 = undefined;

    const size_str = api.formatSize(&size_buf, t.size);
    const dl_str = api.formatSpeed(&dl_buf, t.dlspeed);
    const ul_str = api.formatSpeed(&ul_buf, t.upspeed);
    const eta_str = api.formatEta(&eta_buf, t.eta);
    const prog_str = api.formatProgress(&prog_buf, t.progress);
    const seeds_str = std.fmt.bufPrint(&seeds_buf, "{d}", .{t.num_seeds}) catch "?";
    const peers_str = std.fmt.bufPrint(&peers_buf, "{d}", .{t.num_leechs}) catch "?";
    const state_str = t.state.displayString();

    const cols = formatTorrentColumns(
        alloc,
        truncateName(alloc, t.name, computeNameWidth(width)),
        size_str,
        prog_str,
        dl_str,
        ul_str,
        seeds_str,
        peers_str,
        eta_str,
        state_str,
        width,
    );

    const style = if (selected) selected_style else normal_style;
    return style.render(alloc, cols) catch cols;
}

/// Render a visual progress bar.
pub fn renderProgressBar(alloc: Allocator, progress: f64, bar_width: usize) []const u8 {
    const filled: usize = @intFromFloat(@as(f64, @floatFromInt(bar_width)) * @min(progress, 1.0));
    const empty = bar_width - filled;

    const filled_chars = repeatChar(alloc, '#', filled); // Use block chars
    const empty_chars = repeatChar(alloc, '-', empty);

    const styled_filled = progress_done_style.render(alloc, filled_chars) catch filled_chars;
    const styled_empty = progress_remaining_style.render(alloc, empty_chars) catch empty_chars;

    return std.fmt.allocPrint(alloc, "[{s}{s}]", .{ styled_filled, styled_empty }) catch "[?]";
}

/// Render the bottom status bar with global stats.
pub fn renderStatusBar(alloc: Allocator, transfer: api.TransferInfo, torrent_count: usize, width: usize) []const u8 {
    var dl_buf: [32]u8 = undefined;
    var ul_buf: [32]u8 = undefined;

    const dl_str = api.formatSpeed(&dl_buf, transfer.dl_info_speed);
    const ul_str = api.formatSpeed(&ul_buf, transfer.up_info_speed);

    const content = std.fmt.allocPrint(
        alloc,
        " DL: {s}  UL: {s}  |  Torrents: {d}  DHT: {d}",
        .{ dl_str, ul_str, torrent_count, transfer.dht_nodes },
    ) catch " Status unavailable";

    const padded = padRight(alloc, content, width);
    return status_bar_style.render(alloc, padded) catch padded;
}

/// Render the help/keybindings bar.
pub fn renderHelpBar(alloc: Allocator, mode: HelpMode, width: usize) []const u8 {
    const text = switch (mode) {
        .main => " q:Quit  a:Add  d:Delete  p:Pause/Resume  Enter:Details  j/k:Navigate  P:Preferences",
        .detail => " q:Back  Tab:Switch tab  j/k:Scroll",
        .dialog => " Enter:Confirm  Esc:Cancel",
        .preferences => " q:Back  j/k:Navigate",
    };
    const padded = padRight(alloc, text, width);
    return help_bar_style.render(alloc, padded) catch padded;
}

pub const HelpMode = enum {
    main,
    detail,
    dialog,
    preferences,
};

/// Render the "no torrents" empty state.
pub fn renderEmptyState(alloc: Allocator, width: usize, height: usize) []const u8 {
    const msg_style = blk: {
        var s = zz.Style{};
        s = s.fg(zz.Color.gray(12));
        s = s.alignH(.center);
        s = s.inline_style(true);
        break :blk s;
    };

    const msg = msg_style.render(alloc, "No torrents. Press 'a' to add one.") catch "No torrents.";
    return zz.place.place(alloc, width, height, .center, .middle, msg) catch msg;
}

/// Render a connection error banner.
pub fn renderConnectionError(alloc: Allocator, url: []const u8, width: usize) []const u8 {
    const msg = std.fmt.allocPrint(
        alloc,
        " Cannot connect to daemon at {s}",
        .{url},
    ) catch " Cannot connect to daemon";
    const padded = padRight(alloc, msg, width);
    return error_style.render(alloc, padded) catch padded;
}

/// Render a text input dialog box.
pub fn renderInputDialog(alloc: Allocator, prompt_text: []const u8, input: []const u8, width: usize, height: usize) []const u8 {
    const box_width = @min(width - 4, @as(usize, 60));

    var border_s = zz.Style{};
    border_s = border_s.borderAll(zz.Border.rounded);
    border_s = border_s.borderForeground(zz.Color.cyan());
    border_s = border_s.paddingAll(1);
    border_s = border_s.width(box_width);
    border_s = border_s.alignH(.center);

    var prompt_s = zz.Style{};
    prompt_s = prompt_s.bold(true);
    prompt_s = prompt_s.fg(zz.Color.cyan());
    prompt_s = prompt_s.inline_style(true);

    var input_s = zz.Style{};
    input_s = input_s.fg(zz.Color.white());
    input_s = input_s.underline(true);
    input_s = input_s.inline_style(true);

    const styled_prompt = prompt_s.render(alloc, prompt_text) catch prompt_text;
    const display_input = if (input.len > 0) input else " ";
    const styled_input = input_s.render(alloc, display_input) catch display_input;

    const content = std.fmt.allocPrint(
        alloc,
        "{s}\n\n{s}\n\n[Enter] Confirm  [Esc] Cancel",
        .{ styled_prompt, styled_input },
    ) catch "Dialog";

    const boxed = border_s.render(alloc, content) catch content;
    return zz.place.place(alloc, width, height, .center, .middle, boxed) catch boxed;
}

/// Render a confirmation dialog.
pub fn renderConfirmDialog(alloc: Allocator, prompt_text: []const u8, detail: []const u8, delete_files: bool, width: usize, height: usize) []const u8 {
    const box_width = @min(width - 4, @as(usize, 60));

    var border_s = zz.Style{};
    border_s = border_s.borderAll(zz.Border.rounded);
    border_s = border_s.borderForeground(zz.Color.red());
    border_s = border_s.paddingAll(1);
    border_s = border_s.width(box_width);
    border_s = border_s.alignH(.center);

    var prompt_s = zz.Style{};
    prompt_s = prompt_s.bold(true);
    prompt_s = prompt_s.fg(zz.Color.red());
    prompt_s = prompt_s.inline_style(true);

    const styled_prompt = prompt_s.render(alloc, prompt_text) catch prompt_text;

    const files_opt = if (delete_files) "[x] Delete files" else "[ ] Delete files (press 'f' to toggle)";

    const content = std.fmt.allocPrint(
        alloc,
        "{s}\n\n{s}\n\n{s}\n\n[Enter] Confirm  [Esc] Cancel",
        .{ styled_prompt, detail, files_opt },
    ) catch "Confirm?";

    const boxed = border_s.render(alloc, content) catch content;
    return zz.place.place(alloc, width, height, .center, .middle, boxed) catch boxed;
}

/// Render the torrent detail view with tabs.
pub fn renderDetailView(
    alloc: Allocator,
    torrent: api.TorrentInfo,
    tab: DetailTab,
    trackers: []const api.TrackerEntry,
    files: []const api.FileEntry,
    scroll_offset: usize,
    width: usize,
    height: usize,
) []const u8 {
    _ = height;
    var lines = std.ArrayList(u8).empty;
    const w = lines.writer(alloc);

    // Header with torrent name
    var name_s = zz.Style{};
    name_s = name_s.bold(true);
    name_s = name_s.fg(zz.Color.cyan());
    name_s = name_s.inline_style(true);
    const styled_name = name_s.render(alloc, torrent.name) catch torrent.name;
    w.print("{s}\n", .{styled_name}) catch {};

    // Progress bar
    const bar_w = @min(width - 2, @as(usize, 50));
    const bar = renderProgressBar(alloc, torrent.progress, bar_w);
    var prog_buf: [16]u8 = undefined;
    const prog_str = api.formatProgress(&prog_buf, torrent.progress);
    w.print("{s} {s}\n\n", .{ bar, prog_str }) catch {};

    // Tab bar
    const tabs = [_][]const u8{ "General", "Trackers", "Files" };
    for (tabs, 0..) |tab_name, i| {
        const is_active = @as(usize, @intFromEnum(tab)) == i;
        if (is_active) {
            var active_s = zz.Style{};
            active_s = active_s.bold(true);
            active_s = active_s.fg(zz.Color.cyan());
            active_s = active_s.underline(true);
            active_s = active_s.inline_style(true);
            const styled_tab = active_s.render(alloc, tab_name) catch tab_name;
            w.print(" {s} ", .{styled_tab}) catch {};
        } else {
            var inactive_s = zz.Style{};
            inactive_s = inactive_s.fg(zz.Color.gray(10));
            inactive_s = inactive_s.inline_style(true);
            const styled_tab = inactive_s.render(alloc, tab_name) catch tab_name;
            w.print(" {s} ", .{styled_tab}) catch {};
        }
    }
    w.print("\n{s}\n\n", .{repeatChar(alloc, '-', @min(width, @as(usize, 60)))}) catch {};

    // Tab content
    switch (tab) {
        .general => renderGeneralTab(alloc, &lines, torrent, width),
        .trackers => renderTrackersTab(alloc, &lines, trackers, scroll_offset),
        .files => renderFilesTab(alloc, &lines, files, scroll_offset, width),
    }

    return lines.toOwnedSlice(alloc) catch "Error rendering detail view";
}

pub const DetailTab = enum(usize) {
    general = 0,
    trackers = 1,
    files = 2,

    pub fn next(self: DetailTab) DetailTab {
        return switch (self) {
            .general => .trackers,
            .trackers => .files,
            .files => .general,
        };
    }
};

/// Render the preferences view.
pub fn renderPreferencesView(alloc: Allocator, prefs_json: []const u8, scroll_offset: usize, width: usize, height: usize) []const u8 {
    _ = height;
    _ = scroll_offset;

    var lines = std.ArrayList(u8).empty;
    const w = lines.writer(alloc);

    var hdr_s = zz.Style{};
    hdr_s = hdr_s.bold(true);
    hdr_s = hdr_s.fg(zz.Color.cyan());
    hdr_s = hdr_s.inline_style(true);
    const styled_hdr = hdr_s.render(alloc, "Daemon Preferences") catch "Daemon Preferences";
    w.print("{s}\n", .{styled_hdr}) catch {};
    w.print("{s}\n\n", .{repeatChar(alloc, '-', @min(width, @as(usize, 40)))}) catch {};

    // Display raw JSON formatted
    if (prefs_json.len > 2) {
        // Simple pretty-print: insert newlines after commas at top level
        var depth: usize = 0;
        for (prefs_json) |ch| {
            switch (ch) {
                '{' => {
                    depth += 1;
                    w.writeByte(ch) catch {};
                    w.writeByte('\n') catch {};
                    writeIndent(w, depth);
                },
                '}' => {
                    depth -|= 1;
                    w.writeByte('\n') catch {};
                    writeIndent(w, depth);
                    w.writeByte(ch) catch {};
                },
                ',' => {
                    w.writeByte(ch) catch {};
                    w.writeByte('\n') catch {};
                    writeIndent(w, depth);
                },
                else => w.writeByte(ch) catch {},
            }
        }
    } else {
        w.print("No preferences available.", .{}) catch {};
    }

    return lines.toOwnedSlice(alloc) catch "Error rendering preferences";
}

// ── Internal helpers ─────────────────────────────────────

fn renderGeneralTab(alloc: Allocator, lines: *std.ArrayList(u8), t: api.TorrentInfo, width: usize) void {
    _ = width;
    const w = lines.writer(alloc);

    var label_s = zz.Style{};
    label_s = label_s.bold(true);
    label_s = label_s.fg(zz.Color.gray(16));
    label_s = label_s.inline_style(true);

    var val_s = zz.Style{};
    val_s = val_s.fg(zz.Color.white());
    val_s = val_s.inline_style(true);

    var size_buf: [32]u8 = undefined;
    var dl_buf: [32]u8 = undefined;
    var ul_buf: [32]u8 = undefined;

    const fields = [_][2][]const u8{
        .{ "Hash:      ", t.hash },
        .{ "Size:      ", api.formatSize(&size_buf, t.size) },
        .{ "State:     ", t.state.displayString() },
        .{ "DL Speed:  ", api.formatSpeed(&dl_buf, t.dlspeed) },
        .{ "UL Speed:  ", api.formatSpeed(&ul_buf, t.upspeed) },
        .{ "Save Path: ", t.save_path },
        .{ "Tracker:   ", t.tracker },
        .{ "Category:  ", if (t.category.len > 0) t.category else "(none)" },
    };

    for (fields) |field| {
        const styled_label = label_s.render(alloc, field[0]) catch field[0];
        const styled_val = val_s.render(alloc, field[1]) catch field[1];
        w.print("{s}{s}\n", .{ styled_label, styled_val }) catch {};
    }
}

fn renderTrackersTab(alloc: Allocator, lines: *std.ArrayList(u8), trackers: []const api.TrackerEntry, scroll_offset: usize) void {
    const w = lines.writer(alloc);

    if (trackers.len == 0) {
        const styled = dim_style.render(alloc, "No tracker data available.") catch "No tracker data.";
        w.print("{s}\n", .{styled}) catch {};
        return;
    }

    var start = scroll_offset;
    if (start >= trackers.len) start = 0;

    for (trackers[start..]) |tracker| {
        var url_s = zz.Style{};
        url_s = url_s.fg(zz.Color.cyan());
        url_s = url_s.inline_style(true);
        const styled_url = url_s.render(alloc, tracker.url) catch tracker.url;

        w.print("{s}  [{s}]", .{ styled_url, tracker.status }) catch {};
        if (tracker.msg.len > 0) {
            w.print("  {s}", .{tracker.msg}) catch {};
        }
        w.print("\n", .{}) catch {};
    }
}

fn renderFilesTab(alloc: Allocator, lines: *std.ArrayList(u8), files: []const api.FileEntry, scroll_offset: usize, width: usize) void {
    _ = width;
    const w = lines.writer(alloc);

    if (files.len == 0) {
        const styled = dim_style.render(alloc, "No file data available.") catch "No file data.";
        w.print("{s}\n", .{styled}) catch {};
        return;
    }

    var start = scroll_offset;
    if (start >= files.len) start = 0;

    for (files[start..]) |file| {
        var size_buf: [32]u8 = undefined;
        var prog_buf: [16]u8 = undefined;
        const size_str = api.formatSize(&size_buf, file.size);
        const prog_str = api.formatProgress(&prog_buf, file.progress);
        w.print("  {s}  {s}  {s}\n", .{ file.name, size_str, prog_str }) catch {};
    }
}

fn writeIndent(w: anytype, depth: usize) void {
    for (0..depth * 2) |_| w.writeByte(' ') catch {};
}

fn formatTorrentColumns(
    alloc: Allocator,
    name: []const u8,
    size: []const u8,
    progress: []const u8,
    dl: []const u8,
    ul: []const u8,
    seeds: []const u8,
    peers: []const u8,
    eta: []const u8,
    state: []const u8,
    width: usize,
) []const u8 {
    // Fixed column widths for the torrent table
    const name_w = computeNameWidth(width);

    // Pad/truncate each field to its column width
    const name_col = padOrTruncate(alloc, name, name_w, .left);
    const size_col = padOrTruncate(alloc, size, 9, .right);
    const prog_col = padOrTruncate(alloc, progress, 7, .right);
    const dl_col = padOrTruncate(alloc, dl, 10, .right);
    const ul_col = padOrTruncate(alloc, ul, 10, .right);
    const seeds_col = padOrTruncate(alloc, seeds, 5, .right);
    const peers_col = padOrTruncate(alloc, peers, 5, .right);
    const eta_col = padOrTruncate(alloc, eta, 8, .right);
    const state_col = padOrTruncate(alloc, state, 12, .left);

    return std.fmt.allocPrint(
        alloc,
        " {s} {s} {s} {s} {s} {s} {s} {s} {s}",
        .{ name_col, size_col, prog_col, dl_col, ul_col, seeds_col, peers_col, eta_col, state_col },
    ) catch "  ...";
}

fn computeNameWidth(terminal_width: usize) usize {
    // name + size(9) + progress(7) + dl(10) + ul(10) + seeds(5) + peers(5) + eta(8) + state(12) + spacing
    const fixed_cols: usize = 9 + 7 + 10 + 10 + 5 + 5 + 8 + 12 + 12;
    if (terminal_width > fixed_cols + 10) {
        return terminal_width - fixed_cols;
    }
    return 20; // minimum name width
}

fn truncateName(alloc: Allocator, name: []const u8, max_width: usize) []const u8 {
    if (name.len <= max_width) return name;
    if (max_width < 4) return name[0..max_width];
    const truncated = std.fmt.allocPrint(alloc, "{s}...", .{name[0 .. max_width - 3]}) catch return name[0..max_width];
    return truncated;
}

fn padRight(alloc: Allocator, text: []const u8, width: usize) []const u8 {
    if (text.len >= width) return text;
    const padding = width - text.len;
    const pad_str = repeatChar(alloc, ' ', padding);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ text, pad_str }) catch text;
}

const Alignment = enum { left, right };

fn padOrTruncate(alloc: Allocator, text: []const u8, width: usize, alignment: Alignment) []const u8 {
    if (text.len == width) return text;
    if (text.len > width) {
        return text[0..width];
    }
    // Pad
    const padding = width - text.len;
    const pad_str = repeatChar(alloc, ' ', padding);
    return switch (alignment) {
        .left => std.fmt.allocPrint(alloc, "{s}{s}", .{ text, pad_str }) catch text,
        .right => std.fmt.allocPrint(alloc, "{s}{s}", .{ pad_str, text }) catch text,
    };
}

fn repeatChar(alloc: Allocator, ch: u8, count: usize) []const u8 {
    if (count == 0) return "";
    const buf = alloc.alloc(u8, count) catch return "";
    @memset(buf, ch);
    return buf;
}
