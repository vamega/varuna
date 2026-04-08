//! TUI view components for the varuna terminal interface.
//!
//! Provides rendering functions for the torrent list, status bar,
//! detail panels, modal dialogs, and key binding help bar.

const std = @import("std");
const zz = @import("zigzag");
const api = @import("api.zig");

const Allocator = std.mem.Allocator;

// ── Color palette ────────────────────────────────────────────────────

const colors = struct {
    const title = zz.Color.fromRgb(110, 180, 255);
    const accent = zz.Color.cyan();
    const muted = zz.Color.gray(12);
    const speed_dl = zz.Color.fromRgb(80, 200, 120);
    const speed_up = zz.Color.fromRgb(255, 140, 60);
    const error_c = zz.Color.red();
    const border = zz.Color.gray(8);
    const selected_bg = zz.Color.gray(4);
    const status_fg = zz.Color.gray(14);
    const key_hint = zz.Color.gray(10);
    const paused = zz.Color.gray(8);
};

// ── Format helpers ───────────────────────────────────────────────────

pub fn formatSize(alloc: Allocator, bytes: i64) []const u8 {
    const b: f64 = @floatFromInt(bytes);
    if (bytes < 1024) {
        return std.fmt.allocPrint(alloc, "{d} B", .{bytes}) catch "? B";
    } else if (bytes < 1024 * 1024) {
        return std.fmt.allocPrint(alloc, "{d:.1} KB", .{b / 1024.0}) catch "? KB";
    } else if (bytes < 1024 * 1024 * 1024) {
        return std.fmt.allocPrint(alloc, "{d:.1} MB", .{b / (1024.0 * 1024.0)}) catch "? MB";
    } else {
        return std.fmt.allocPrint(alloc, "{d:.2} GB", .{b / (1024.0 * 1024.0 * 1024.0)}) catch "? GB";
    }
}

pub fn formatSpeed(alloc: Allocator, bytes_per_sec: i64) []const u8 {
    if (bytes_per_sec <= 0) return "0 B/s";
    const b: f64 = @floatFromInt(bytes_per_sec);
    if (bytes_per_sec < 1024) {
        return std.fmt.allocPrint(alloc, "{d} B/s", .{bytes_per_sec}) catch "? B/s";
    } else if (bytes_per_sec < 1024 * 1024) {
        return std.fmt.allocPrint(alloc, "{d:.1} KB/s", .{b / 1024.0}) catch "? KB/s";
    } else {
        return std.fmt.allocPrint(alloc, "{d:.1} MB/s", .{b / (1024.0 * 1024.0)}) catch "? MB/s";
    }
}

pub fn formatEta(alloc: Allocator, eta_secs: i64) []const u8 {
    if (eta_secs <= 0 or eta_secs >= 8640000) return "inf";
    const h = @divFloor(eta_secs, 3600);
    const m = @divFloor(@mod(eta_secs, 3600), 60);
    const s = @mod(eta_secs, 60);
    if (h > 0) {
        return std.fmt.allocPrint(alloc, "{d}h{d:0>2}m", .{ h, m }) catch "?";
    }
    return std.fmt.allocPrint(alloc, "{d}m{d:0>2}s", .{ m, s }) catch "?";
}

// Status symbol and color are now methods on api.TorrentState in api.zig.
// Views call t.state.statusSymbol() and t.state.statusColor() directly.

fn toU16(val: usize) u16 {
    return @intCast(@min(val, std.math.maxInt(u16)));
}

// ── Progress bar ─────────────────────────────────────────────────────

fn renderProgressBar(alloc: Allocator, progress: f64, width: usize) []const u8 {
    if (width < 4) return "";
    const bar_width = width - 2; // [ and ]
    const filled: usize = @intFromFloat(@round(progress * @as(f64, @floatFromInt(bar_width))));
    const empty = bar_width -| filled;

    const fill_str = makeRepeated(alloc, '#', filled);
    const empty_str = makeRepeated(alloc, '.', empty);
    return std.fmt.allocPrint(alloc, "[{s}{s}]", .{ fill_str, empty_str }) catch "[]";
}

fn makeRepeated(alloc: Allocator, ch: u8, count: usize) []const u8 {
    if (count == 0) return "";
    const buf = alloc.alloc(u8, count) catch return "";
    @memset(buf, ch);
    return buf;
}

fn makeSeparator(alloc: Allocator, width: usize) []const u8 {
    return makeRepeated(alloc, '-', width);
}

fn truncate(s: []const u8, max_len: usize) []const u8 {
    if (s.len <= max_len) return s;
    return s[0..max_len];
}

fn padRight(alloc: Allocator, s: []const u8, width: usize) []const u8 {
    if (s.len >= width) return s[0..width];
    const padding = makeRepeated(alloc, ' ', width - s.len);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ s, padding }) catch s;
}

fn padLeft(alloc: Allocator, s: []const u8, width: usize) []const u8 {
    if (s.len >= width) return s[0..width];
    const padding = makeRepeated(alloc, ' ', width - s.len);
    return std.fmt.allocPrint(alloc, "{s}{s}", .{ padding, s }) catch s;
}

// ── Torrent list view ────────────────────────────────────────────────

pub fn renderTorrentList(
    alloc: Allocator,
    torrents: []const api.TorrentInfo,
    selected: usize,
    width: usize,
    max_rows: usize,
) []const u8 {
    if (width < 40) return "Terminal too narrow";

    // Column widths
    const fixed_cols: usize = 4 + 10 + 12 + 10 + 10 + 6 + 6 + 7;
    const name_width = if (width > fixed_cols + 10) width - fixed_cols else 10;

    // Header
    var header_style = zz.Style{};
    header_style = header_style.bold(true);
    header_style = header_style.fg(colors.title);
    header_style = header_style.inline_style(true);

    const hdr = std.fmt.allocPrint(alloc, " {s}  {s}  {s}  {s}  {s}  {s}  {s}  {s}", .{
        padRight(alloc, "St", 3),
        padRight(alloc, "Name", name_width),
        padLeft(alloc, "Size", 9),
        padLeft(alloc, "Progress", 11),
        padLeft(alloc, "Down", 9),
        padLeft(alloc, "Up", 9),
        padLeft(alloc, "Seed", 5),
        padLeft(alloc, "Peer", 5),
    }) catch " Header";

    const styled_hdr = header_style.render(alloc, hdr) catch hdr;

    // Separator
    var sep_style = zz.Style{};
    sep_style = sep_style.fg(colors.border);
    sep_style = sep_style.inline_style(true);
    const sep = sep_style.render(alloc, makeSeparator(alloc, width)) catch "";

    var result = std.fmt.allocPrint(alloc, "{s}\n{s}", .{ styled_hdr, sep }) catch "";

    if (torrents.len == 0) {
        var empty_style = zz.Style{};
        empty_style = empty_style.fg(colors.muted);
        empty_style = empty_style.inline_style(true);
        const msg = empty_style.render(alloc, "  No torrents. Press 'a' to add one.") catch "  No torrents.";
        return std.fmt.allocPrint(alloc, "{s}\n{s}", .{ result, msg }) catch result;
    }

    // Calculate visible window
    const visible_count = @min(torrents.len, max_rows);
    const scroll_offset = if (selected >= visible_count) selected - visible_count + 1 else 0;

    for (0..visible_count) |i| {
        const idx = scroll_offset + i;
        if (idx >= torrents.len) break;
        const t = &torrents[idx];
        const is_selected = idx == selected;

        // Status symbol
        const sym = t.state.statusSymbol();
        const sym_color = t.state.statusColor();

        var sym_style = zz.Style{};
        sym_style = sym_style.fg(sym_color);
        sym_style = sym_style.bold(true);
        sym_style = sym_style.inline_style(true);
        const styled_sym = sym_style.render(alloc, padRight(alloc, sym, 3)) catch sym;

        // Format fields
        const name_display = truncate(t.name, name_width);
        const size_str = padLeft(alloc, formatSize(alloc, t.size), 9);
        const pct = std.fmt.allocPrint(alloc, "{d:.1}%", .{t.progress * 100.0}) catch "?%";
        const bar = renderProgressBar(alloc, t.progress, 6);
        const progress_str = padLeft(alloc, std.fmt.allocPrint(alloc, "{s}{s}", .{ bar, pct }) catch pct, 11);
        const dl_str = padLeft(alloc, formatSpeed(alloc, t.dlspeed), 9);
        const up_str = padLeft(alloc, formatSpeed(alloc, t.upspeed), 9);
        const seeds_str = padLeft(alloc, std.fmt.allocPrint(alloc, "{d}", .{t.num_seeds}) catch "?", 5);
        const peers_str = padLeft(alloc, std.fmt.allocPrint(alloc, "{d}", .{t.num_leechs}) catch "?", 5);

        const row = std.fmt.allocPrint(alloc, " {s}  {s}  {s}  {s}  {s}  {s}  {s}  {s}", .{
            styled_sym,
            padRight(alloc, name_display, name_width),
            size_str,
            progress_str,
            dl_str,
            up_str,
            seeds_str,
            peers_str,
        }) catch "";

        if (is_selected) {
            var sel_style = zz.Style{};
            sel_style = sel_style.bg(colors.selected_bg);
            sel_style = sel_style.bold(true);
            sel_style = sel_style.width(toU16(width));
            const styled_row = sel_style.render(alloc, row) catch row;
            result = std.fmt.allocPrint(alloc, "{s}\n{s}", .{ result, styled_row }) catch result;
        } else {
            result = std.fmt.allocPrint(alloc, "{s}\n{s}", .{ result, row }) catch result;
        }
    }

    return result;
}

// ── Status bar (bottom) ──────────────────────────────────────────────

pub fn renderStatusBar(
    alloc: Allocator,
    transfer: api.TransferInfo,
    torrent_count: usize,
    width: usize,
    connected: bool,
) []const u8 {
    var bar_style = zz.Style{};
    bar_style = bar_style.bg(zz.Color.gray(2));
    bar_style = bar_style.fg(colors.status_fg);
    bar_style = bar_style.width(toU16(width));

    const dl_str = formatSpeed(alloc, transfer.dl_info_speed);
    const up_str = formatSpeed(alloc, transfer.up_info_speed);
    const conn_prefix: []const u8 = if (connected) "" else "[!] ";
    const conn_str: []const u8 = if (connected) "Connected" else "Disconnected";

    const content = std.fmt.allocPrint(
        alloc,
        " {s}{s} | DL: {s} | UP: {s} | Torrents: {d} | DHT: {d}",
        .{ conn_prefix, conn_str, dl_str, up_str, torrent_count, transfer.dht_nodes },
    ) catch " Status unavailable";

    return bar_style.render(alloc, content) catch content;
}

// ── Key hints bar ────────────────────────────────────────────────────

pub fn renderKeyBar(alloc: Allocator, width: usize, mode: ViewMode) []const u8 {
    var bar_style = zz.Style{};
    bar_style = bar_style.bg(zz.Color.gray(1));
    bar_style = bar_style.fg(colors.key_hint);
    bar_style = bar_style.width(toU16(width));

    const hints = switch (mode) {
        .main => " q:Quit  a:Add  d:Delete  p:Pause/Resume  Enter:Details  P:Preferences  /:Filter",
        .details => " q/Esc:Back  Tab:Switch tab  p:Pause/Resume  d:Delete",
        .add_torrent => " Enter:Confirm  Esc:Cancel  Tab:Toggle file/magnet",
        .confirm_delete => " y:Yes  n/Esc:No  f:Toggle delete files",
        .preferences => " q/Esc:Back  j/k:Navigate  Enter:Edit  Esc:Cancel edit",
        .filter => " Enter:Apply  Esc:Cancel",
        .login => " Tab:Switch field  Enter:Submit  Esc:Cancel",
    };

    return bar_style.render(alloc, hints) catch hints;
}

// ── Title bar ────────────────────────────────────────────────────────

pub fn renderTitleBar(alloc: Allocator, width: usize) []const u8 {
    var bar_style = zz.Style{};
    bar_style = bar_style.bg(zz.Color.gray(2));
    bar_style = bar_style.fg(colors.title);
    bar_style = bar_style.bold(true);
    bar_style = bar_style.width(toU16(width));

    return bar_style.render(alloc, " varuna") catch " varuna";
}

// ── Torrent detail view ──────────────────────────────────────────────

pub fn renderDetailView(
    alloc: Allocator,
    torrent: api.TorrentInfo,
    files: []const api.TorrentFile,
    trackers: []const api.TrackerEntry,
    props: api.TorrentProperties,
    active_tab: DetailTab,
    width: usize,
    max_rows: usize,
) []const u8 {
    // Header: torrent name and basic stats
    var name_style = zz.Style{};
    name_style = name_style.bold(true);
    name_style = name_style.fg(colors.title);
    name_style = name_style.inline_style(true);
    const name = name_style.render(alloc, torrent.name) catch torrent.name;

    const status_line = std.fmt.allocPrint(
        alloc,
        " Status: {s}  Progress: {d:.1}%  DL: {s}  UP: {s}  Seeds: {d}/{d}  Peers: {d}/{d}",
        .{
            torrent.state.displayString(),
            torrent.progress * 100.0,
            formatSpeed(alloc, torrent.dlspeed),
            formatSpeed(alloc, torrent.upspeed),
            torrent.num_seeds,
            props.seeds_total,
            torrent.num_leechs,
            props.peers_total,
        },
    ) catch "";

    const size_line = std.fmt.allocPrint(
        alloc,
        " Size: {s}  Downloaded: {s}  Uploaded: {s}  Ratio: {d:.2}",
        .{
            formatSize(alloc, torrent.size),
            formatSize(alloc, torrent.downloaded),
            formatSize(alloc, torrent.uploaded),
            torrent.ratio,
        },
    ) catch "";

    const path_line = if (props.save_path.len > 0)
        std.fmt.allocPrint(alloc, " Path: {s}", .{props.save_path}) catch ""
    else
        "";

    // Tab bar
    const tab_names = [_]struct { label: []const u8, tab: DetailTab }{
        .{ .label = " Files ", .tab = .files },
        .{ .label = " Trackers ", .tab = .trackers },
        .{ .label = " Info ", .tab = .info },
    };

    var tab_bar: []const u8 = "";
    for (tab_names) |tab| {
        if (tab.tab == active_tab) {
            var tab_style = zz.Style{};
            tab_style = tab_style.bold(true);
            tab_style = tab_style.fg(colors.accent);
            tab_style = tab_style.inline_style(true);
            const styled = tab_style.render(alloc, tab.label) catch tab.label;
            tab_bar = std.fmt.allocPrint(alloc, "{s} [{s}]", .{ tab_bar, styled }) catch tab_bar;
        } else {
            var tab_style = zz.Style{};
            tab_style = tab_style.fg(colors.muted);
            tab_style = tab_style.inline_style(true);
            const styled = tab_style.render(alloc, tab.label) catch tab.label;
            tab_bar = std.fmt.allocPrint(alloc, "{s}  {s} ", .{ tab_bar, styled }) catch tab_bar;
        }
    }

    var tab_sep_style = zz.Style{};
    tab_sep_style = tab_sep_style.fg(colors.border);
    tab_sep_style = tab_sep_style.inline_style(true);
    const tab_sep = tab_sep_style.render(alloc, makeSeparator(alloc, width)) catch "";

    // Tab content
    const remaining_rows = if (max_rows > 8) max_rows - 8 else 2;
    const tab_content = switch (active_tab) {
        .files => renderFileTab(alloc, files, width, remaining_rows),
        .trackers => renderTrackerTab(alloc, trackers, remaining_rows),
        .info => renderInfoTab(alloc, torrent, props),
    };

    return std.fmt.allocPrint(alloc, " {s}\n{s}\n{s}\n{s}\n\n{s}\n{s}\n{s}", .{
        name,
        status_line,
        size_line,
        path_line,
        tab_bar,
        tab_sep,
        tab_content,
    }) catch "";
}

fn renderFileTab(alloc: Allocator, files: []const api.TorrentFile, width: usize, max: usize) []const u8 {
    if (files.len == 0) return "  No files";

    var result: []const u8 = "";
    const show_count = @min(files.len, max);
    for (files[0..show_count]) |f| {
        const name_w = if (width > 40) width - 30 else 10;
        const display_name = truncate(f.name, name_w);
        const line = std.fmt.allocPrint(alloc, "  {d:<5} {s}  {s}  {d:.1}%  pri={d}", .{
            f.index,
            padRight(alloc, display_name, name_w),
            padLeft(alloc, formatSize(alloc, f.size), 9),
            f.progress * 100.0,
            f.priority,
        }) catch "";
        result = if (result.len == 0) line else std.fmt.allocPrint(alloc, "{s}\n{s}", .{ result, line }) catch result;
    }

    if (files.len > show_count) {
        const more = std.fmt.allocPrint(alloc, "  ... and {d} more files", .{files.len - show_count}) catch "";
        result = std.fmt.allocPrint(alloc, "{s}\n{s}", .{ result, more }) catch result;
    }

    return result;
}

fn renderTrackerTab(alloc: Allocator, trackers: []const api.TrackerEntry, max: usize) []const u8 {
    if (trackers.len == 0) return "  No trackers";

    var result: []const u8 = "";
    for (trackers[0..@min(trackers.len, max)]) |tr| {
        const status_str: []const u8 = switch (tr.status) {
            0 => "Disabled",
            1 => "Not contacted",
            2 => "Working",
            3 => "Updating",
            4 => "Not working",
            else => "Unknown",
        };
        var line = std.fmt.allocPrint(alloc, "  [{s}] {s}", .{ status_str, tr.url }) catch "";
        if (tr.msg.len > 0) {
            line = std.fmt.allocPrint(alloc, "{s}\n        Msg: {s}", .{ line, tr.msg }) catch line;
        }
        result = if (result.len == 0) line else std.fmt.allocPrint(alloc, "{s}\n{s}", .{ result, line }) catch result;
    }

    return result;
}

fn renderInfoTab(alloc: Allocator, torrent: api.TorrentInfo, props: api.TorrentProperties) []const u8 {
    return std.fmt.allocPrint(alloc,
        \\  Hash:         {s}
        \\  Save path:    {s}
        \\  Total size:   {s}
        \\  Pieces:       {d} x {s}
        \\  Connections:  {d}
        \\  Added on:     {d}
        \\  Tracker:      {s}
        \\  Category:     {s}
        \\  Tags:         {s}
        \\  Comment:      {s}
    , .{
        torrent.hash,
        props.save_path,
        formatSize(alloc, props.total_size),
        props.pieces_num,
        formatSize(alloc, props.piece_size),
        props.nb_connections,
        props.addition_date,
        torrent.tracker,
        if (torrent.category.len > 0) torrent.category else "(none)",
        if (torrent.tags.len > 0) torrent.tags else "(none)",
        if (props.comment.len > 0) props.comment else "(none)",
    }) catch "";
}

// ── Modal: Add torrent ───────────────────────────────────────────────

pub fn renderAddTorrentDialog(
    alloc: Allocator,
    input_buf: []const u8,
    input_len: usize,
    is_magnet: bool,
    error_msg: ?[]const u8,
    width: usize,
    height: usize,
) []const u8 {
    const dialog_w = toU16(@min(width -| 4, 70));
    const label: []const u8 = if (is_magnet) "Magnet URI:" else "Torrent file path:";

    var box_style = zz.Style{};
    box_style = box_style.borderAll(zz.Border.rounded);
    box_style = box_style.borderForeground(colors.accent);
    box_style = box_style.paddingAll(1);
    box_style = box_style.width(dialog_w);
    box_style = box_style.alignH(.center);

    var title_style = zz.Style{};
    title_style = title_style.bold(true);
    title_style = title_style.fg(colors.title);
    title_style = title_style.inline_style(true);

    var hint_style = zz.Style{};
    hint_style = hint_style.fg(colors.muted);
    hint_style = hint_style.inline_style(true);

    const title = title_style.render(alloc, "Add Torrent") catch "Add Torrent";
    const input_display = if (input_len > 0) input_buf[0..input_len] else "(type path or magnet URI)";
    const input_line = std.fmt.allocPrint(alloc, "{s}\n> {s}", .{ label, input_display }) catch "";
    const tab_hint = hint_style.render(alloc, "Tab: toggle file/magnet mode") catch "";

    var inner = std.fmt.allocPrint(alloc, "{s}\n\n{s}\n\n{s}", .{ title, input_line, tab_hint }) catch "";

    if (error_msg) |err| {
        var err_style = zz.Style{};
        err_style = err_style.fg(colors.error_c);
        err_style = err_style.inline_style(true);
        const styled_err = err_style.render(alloc, err) catch err;
        inner = std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ inner, styled_err }) catch inner;
    }

    const boxed = box_style.render(alloc, inner) catch inner;
    return zz.place.place(alloc, width, height, .center, .middle, boxed) catch boxed;
}

// ── Modal: Confirm delete ────────────────────────────────────────────

pub fn renderConfirmDeleteDialog(
    alloc: Allocator,
    torrent_name: []const u8,
    delete_files: bool,
    width: usize,
    height: usize,
) []const u8 {
    const dialog_w = toU16(@min(width -| 4, 60));

    var box_style = zz.Style{};
    box_style = box_style.borderAll(zz.Border.rounded);
    box_style = box_style.borderForeground(colors.error_c);
    box_style = box_style.paddingAll(1);
    box_style = box_style.width(dialog_w);
    box_style = box_style.alignH(.center);

    var title_style = zz.Style{};
    title_style = title_style.bold(true);
    title_style = title_style.fg(colors.error_c);
    title_style = title_style.inline_style(true);

    const title = title_style.render(alloc, "Delete Torrent") catch "Delete Torrent";
    const truncated_name = truncate(torrent_name, 40);
    const df_indicator: []const u8 = if (delete_files) "[x] Delete files from disk" else "[ ] Delete files from disk";

    const inner = std.fmt.allocPrint(
        alloc,
        "{s}\n\nRemove \"{s}\"?\n\n{s}\n\n  y: Confirm   n/Esc: Cancel   f: Toggle files",
        .{ title, truncated_name, df_indicator },
    ) catch "";

    const boxed = box_style.render(alloc, inner) catch inner;
    return zz.place.place(alloc, width, height, .center, .middle, boxed) catch boxed;
}

// ── Modal: Preferences ───────────────────────────────────────────────

pub fn renderPreferencesView(
    alloc: Allocator,
    prefs: api.Preferences,
    width: usize,
    _: usize,
    selected: usize,
    editing: bool,
    edit_value: []const u8,
) []const u8 {
    var title_style = zz.Style{};
    title_style = title_style.bold(true);
    title_style = title_style.fg(colors.title);
    title_style = title_style.inline_style(true);

    const title = title_style.render(alloc, " Daemon Preferences") catch " Daemon Preferences";

    var sep_style = zz.Style{};
    sep_style = sep_style.fg(colors.border);
    sep_style = sep_style.inline_style(true);
    const sep = sep_style.render(alloc, makeSeparator(alloc, width)) catch "";

    const dl_limit_str = if (prefs.dl_limit == 0) "Unlimited" else formatSpeed(alloc, prefs.dl_limit);
    const up_limit_str = if (prefs.up_limit == 0) "Unlimited" else formatSpeed(alloc, prefs.up_limit);

    const labels = [_][]const u8{
        "Listen port",
        "Download limit",
        "Upload limit",
        "Max connections",
        "Max conn/torrent",
        "Max uploads",
        "Max uploads/torrent",
        "DHT",
        "PEX",
        "Save path",
        "uTP",
        "WebUI port",
    };

    const values = [_][]const u8{
        std.fmt.allocPrint(alloc, "{d}", .{prefs.listen_port}) catch "?",
        dl_limit_str,
        up_limit_str,
        std.fmt.allocPrint(alloc, "{d}", .{prefs.max_connec}) catch "?",
        std.fmt.allocPrint(alloc, "{d}", .{prefs.max_connec_per_torrent}) catch "?",
        std.fmt.allocPrint(alloc, "{d}", .{prefs.max_uploads}) catch "?",
        std.fmt.allocPrint(alloc, "{d}", .{prefs.max_uploads_per_torrent}) catch "?",
        @as([]const u8, if (prefs.dht) "Enabled" else "Disabled"),
        @as([]const u8, if (prefs.pex) "Enabled" else "Disabled"),
        prefs.save_path,
        @as([]const u8, if (prefs.enable_utp) "Enabled" else "Disabled"),
        std.fmt.allocPrint(alloc, "{d}", .{prefs.web_ui_port}) catch "?",
    };

    var body: []const u8 = "";
    for (labels, 0..) |label, i| {
        const is_sel = i == selected;
        const prefix: []const u8 = if (is_sel) " > " else "   ";
        const value = if (is_sel and editing)
            std.fmt.allocPrint(alloc, "[{s}_]", .{edit_value}) catch values[i]
        else
            values[i];

        const padded_label = padRight(alloc, label, 24);
        var line = std.fmt.allocPrint(alloc, "{s}{s}{s}", .{ prefix, padded_label, value }) catch "";

        if (is_sel) {
            var sel_style = zz.Style{};
            sel_style = sel_style.bold(true);
            sel_style = sel_style.fg(colors.accent);
            sel_style = sel_style.inline_style(true);
            line = sel_style.render(alloc, line) catch line;
        }

        body = if (body.len == 0) line else std.fmt.allocPrint(alloc, "{s}\n{s}", .{ body, line }) catch body;
    }

    return std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}", .{ title, sep, body }) catch "";
}

// ── Disconnected overlay ─────────────────────────────────────────────

pub fn renderDisconnected(alloc: Allocator, host: []const u8, port: u16, width: usize, height: usize) []const u8 {
    var box_style = zz.Style{};
    box_style = box_style.borderAll(zz.Border.rounded);
    box_style = box_style.borderForeground(colors.error_c);
    box_style = box_style.paddingAll(1);
    box_style = box_style.width(toU16(@min(width -| 4, 50)));
    box_style = box_style.alignH(.center);

    var title_style = zz.Style{};
    title_style = title_style.bold(true);
    title_style = title_style.fg(colors.error_c);
    title_style = title_style.inline_style(true);

    const title = title_style.render(alloc, "Connection Error") catch "Connection Error";
    const msg = std.fmt.allocPrint(
        alloc,
        "{s}\n\nCannot connect to varuna daemon at\n{s}:{d}\n\nMake sure the daemon is running.\nRetrying automatically...",
        .{ title, host, port },
    ) catch "Cannot connect";

    const boxed = box_style.render(alloc, msg) catch msg;
    return zz.place.place(alloc, width, height, .center, .middle, boxed) catch boxed;
}

// ── Login dialog ─────────────────────────────────────────────────────

pub fn renderLoginDialog(
    alloc: Allocator,
    user_buf: []const u8,
    user_len: usize,
    _: []const u8,
    pass_len: usize,
    username_active: bool,
    error_msg: ?[]const u8,
    width: usize,
    height: usize,
) []const u8 {
    const dialog_w = toU16(@min(width -| 4, 50));

    var box_style = zz.Style{};
    box_style = box_style.borderAll(zz.Border.rounded);
    box_style = box_style.borderForeground(colors.accent);
    box_style = box_style.paddingAll(1);
    box_style = box_style.width(dialog_w);
    box_style = box_style.alignH(.center);

    var title_style = zz.Style{};
    title_style = title_style.bold(true);
    title_style = title_style.fg(colors.title);
    title_style = title_style.inline_style(true);

    const title = title_style.render(alloc, "Login Required") catch "Login Required";

    const user_prefix: []const u8 = if (username_active) "> " else "  ";
    const pass_prefix: []const u8 = if (!username_active) "> " else "  ";

    const user_display = if (user_len > 0) user_buf[0..user_len] else "";
    const pass_display = makeRepeated(alloc, '*', pass_len);

    const user_line = std.fmt.allocPrint(alloc, "{s}Username: {s}", .{ user_prefix, user_display }) catch "";
    const pass_line = std.fmt.allocPrint(alloc, "{s}Password: {s}", .{ pass_prefix, pass_display }) catch "";

    var inner = std.fmt.allocPrint(alloc, "{s}\n\n{s}\n{s}", .{ title, user_line, pass_line }) catch "";

    if (error_msg) |err| {
        var err_style = zz.Style{};
        err_style = err_style.fg(colors.error_c);
        err_style = err_style.inline_style(true);
        const styled_err = err_style.render(alloc, err) catch err;
        inner = std.fmt.allocPrint(alloc, "{s}\n\n{s}", .{ inner, styled_err }) catch inner;
    }

    const boxed = box_style.render(alloc, inner) catch inner;
    return zz.place.place(alloc, width, height, .center, .middle, boxed) catch boxed;
}

// ── View mode enum ───────────────────────────────────────────────────

pub const ViewMode = enum {
    main,
    details,
    add_torrent,
    confirm_delete,
    preferences,
    filter,
    login,
};

pub const DetailTab = enum {
    files,
    trackers,
    info,
};
