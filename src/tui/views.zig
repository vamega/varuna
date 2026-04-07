/// TUI view components for varuna-tui.
///
/// Provides rendering functions for the torrent list, status bar,
/// detail panels, modal dialogs, and key binding help bar.
/// Styled with color-coded status indicators and inline progress bars.
const std = @import("std");
const zz = @import("zigzag");
const api = @import("api.zig");

const Allocator = std.mem.Allocator;

// ── Color palette ───────────────────────────────────────────────

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
    const progress_done = zz.Color.green();
    const progress_remain = zz.Color.gray(6);
};

// ── View mode enums ─────────────────────────────────────────────

pub const ViewMode = enum {
    main,
    detail,
    add_dialog,
    remove_dialog,
    preferences,
    login,
};

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

// ── String helpers ──────────────────────────────────────────────

fn makeRepeated(alloc: Allocator, ch: u8, count: usize) []const u8 {
    if (count == 0) return "";
    const buf = alloc.alloc(u8, count) catch return "";
    @memset(buf, ch);
    return buf;
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

fn toU16(val: usize) u16 {
    return @intCast(@min(val, std.math.maxInt(u16)));
}

fn statusColor(state: api.TorrentState) zz.Color {
    return switch (state) {
        .downloading, .metaDL => colors.speed_dl,
        .uploading, .stalledUP => colors.speed_up,
        .pausedDL, .pausedUP => colors.paused,
        .error_state, .missingFiles => colors.error_c,
        .stalledDL => zz.Color.fromRgb(200, 200, 80),
        .checking => colors.accent,
        .queuedDL, .queuedUP => colors.muted,
        .moving => colors.accent,
        .unknown => colors.muted,
    };
}

// ── Progress bar ────────────────────────────────────────────────

pub fn renderProgressBar(alloc: Allocator, progress: f64, width: usize) []const u8 {
    if (width < 4) return "";
    const bar_width = width - 2;
    const filled: usize = @intFromFloat(@round(@as(f64, @floatFromInt(bar_width)) * @min(progress, 1.0)));
    const empty = bar_width -| filled;

    const fill_str = makeRepeated(alloc, '#', filled);
    const empty_str = makeRepeated(alloc, '.', empty);

    var done_s = zz.Style{};
    done_s = done_s.fg(colors.progress_done);
    done_s = done_s.inline_style(true);
    const styled_fill = done_s.render(alloc, fill_str) catch fill_str;

    var rem_s = zz.Style{};
    rem_s = rem_s.fg(colors.progress_remain);
    rem_s = rem_s.inline_style(true);
    const styled_empty = rem_s.render(alloc, empty_str) catch empty_str;

    return std.fmt.allocPrint(alloc, "[{s}{s}]", .{ styled_fill, styled_empty }) catch "[]";
}

// ── Title bar ───────────────────────────────────────────────────

pub fn renderTitleBar(alloc: Allocator, width: usize) []const u8 {
    var bar_style = zz.Style{};
    bar_style = bar_style.bg(zz.Color.gray(2));
    bar_style = bar_style.fg(colors.title);
    bar_style = bar_style.bold(true);
    bar_style = bar_style.width(toU16(width));

    return bar_style.render(alloc, " varuna-tui v0.1.0") catch " varuna";
}

// ── Column headers ──────────────────────────────────────────────

pub fn renderColumnHeaders(alloc: Allocator, width: usize) []const u8 {
    const fixed_cols: usize = 4 + 10 + 12 + 10 + 10 + 6 + 6 + 7;
    const name_width = if (width > fixed_cols + 10) width - fixed_cols else 10;

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

    return header_style.render(alloc, hdr) catch hdr;
}

// ── Torrent row ─────────────────────────────────────────────────

pub fn renderTorrentRow(alloc: Allocator, t: api.TorrentInfo, selected: bool, width: usize) []const u8 {
    const fixed_cols: usize = 4 + 10 + 12 + 10 + 10 + 6 + 6 + 7;
    const name_width = if (width > fixed_cols + 10) width - fixed_cols else 10;

    // Status symbol with color
    const sym = t.state.symbol();
    const sym_clr = statusColor(t.state);
    var sym_style = zz.Style{};
    sym_style = sym_style.fg(sym_clr);
    sym_style = sym_style.bold(true);
    sym_style = sym_style.inline_style(true);
    const styled_sym = sym_style.render(alloc, padRight(alloc, sym, 3)) catch sym;

    // Format fields
    var size_buf: [32]u8 = undefined;
    var dl_buf: [32]u8 = undefined;
    var ul_buf: [32]u8 = undefined;

    const name_display = truncate(t.name, name_width);
    const size_str = padLeft(alloc, api.formatSize(&size_buf, t.size), 9);
    var pct_buf: [16]u8 = undefined;
    const pct = api.formatProgress(&pct_buf, t.progress);
    const bar = renderProgressBar(alloc, t.progress, 6);
    const progress_str = padLeft(alloc, std.fmt.allocPrint(alloc, "{s}{s}", .{ bar, pct }) catch pct, 11);
    const dl_str = padLeft(alloc, api.formatSpeed(&dl_buf, t.dlspeed), 9);
    const up_str = padLeft(alloc, api.formatSpeed(&ul_buf, t.upspeed), 9);
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

    if (selected) {
        var sel_style = zz.Style{};
        sel_style = sel_style.bg(colors.selected_bg);
        sel_style = sel_style.bold(true);
        sel_style = sel_style.width(toU16(width));
        return sel_style.render(alloc, row) catch row;
    }

    return row;
}

// ── Empty state ─────────────────────────────────────────────────

pub fn renderEmptyState(alloc: Allocator, width: usize, height: usize) []const u8 {
    var msg_style = zz.Style{};
    msg_style = msg_style.fg(colors.muted);
    msg_style = msg_style.alignH(.center);
    msg_style = msg_style.inline_style(true);

    const msg = msg_style.render(alloc, "No torrents. Press 'a' to add one.") catch "No torrents.";
    return zz.place.place(alloc, width, height, .center, .middle, msg) catch msg;
}

// ── Status bar ──────────────────────────────────────────────────

pub fn renderStatusBar(alloc: Allocator, transfer: api.TransferInfo, torrent_count: usize, width: usize, connected: bool) []const u8 {
    var bar_style = zz.Style{};
    bar_style = bar_style.bg(zz.Color.gray(2));
    bar_style = bar_style.fg(colors.status_fg);
    bar_style = bar_style.width(toU16(width));

    var dl_buf: [32]u8 = undefined;
    var ul_buf: [32]u8 = undefined;
    const dl_str = api.formatSpeed(&dl_buf, transfer.dl_info_speed);
    const up_str = api.formatSpeed(&ul_buf, transfer.up_info_speed);
    const conn_prefix: []const u8 = if (connected) "" else "[!] ";
    const conn_str: []const u8 = if (connected) "Connected" else "Disconnected";

    const content = std.fmt.allocPrint(
        alloc,
        " {s}{s} | DL: {s} | UP: {s} | Torrents: {d} | DHT: {d}",
        .{ conn_prefix, conn_str, dl_str, up_str, torrent_count, transfer.dht_nodes },
    ) catch " Status unavailable";

    return bar_style.render(alloc, content) catch content;
}

// ── Help/keybinding bar ─────────────────────────────────────────

pub fn renderHelpBar(alloc: Allocator, mode: ViewMode, width: usize) []const u8 {
    var bar_style = zz.Style{};
    bar_style = bar_style.bg(zz.Color.gray(1));
    bar_style = bar_style.fg(colors.key_hint);
    bar_style = bar_style.width(toU16(width));

    const hints: []const u8 = switch (mode) {
        .main => " q:Quit  a:Add  d:Delete  p:Pause/Resume  Enter:Details  P:Preferences",
        .detail => " q/Esc:Back  Tab:Switch tab  j/k:Scroll",
        .add_dialog => " Enter:Confirm  Esc:Cancel",
        .remove_dialog => " y:Confirm  n/Esc:Cancel  f:Toggle delete files",
        .preferences => " q/Esc:Back  j/k:Scroll",
        .login => " Enter:Submit  Tab:Switch field  Esc:Quit",
    };

    return bar_style.render(alloc, hints) catch hints;
}

// ── Connection error banner ─────────────────────────────────────

pub fn renderConnectionError(alloc: Allocator, url: []const u8, width: usize) []const u8 {
    var err_style = zz.Style{};
    err_style = err_style.fg(colors.error_c);
    err_style = err_style.bold(true);
    err_style = err_style.width(toU16(width));

    const msg = std.fmt.allocPrint(
        alloc,
        " Cannot connect to daemon at {s} - retrying...",
        .{url},
    ) catch " Cannot connect to daemon";

    return err_style.render(alloc, msg) catch msg;
}

// ── Disconnected overlay dialog ─────────────────────────────────

pub fn renderDisconnected(alloc: Allocator, url: []const u8, width: usize, height: usize) []const u8 {
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
        "{s}\n\nCannot connect to varuna daemon at\n{s}\n\nMake sure the daemon is running.\nRetrying automatically...",
        .{ title, url },
    ) catch "Cannot connect";

    const boxed = box_style.render(alloc, msg) catch msg;
    return zz.place.place(alloc, width, height, .center, .middle, boxed) catch boxed;
}

// ── Add torrent dialog ──────────────────────────────────────────

pub fn renderAddDialog(alloc: Allocator, input: []const u8, width: usize, height: usize) []const u8 {
    const dialog_w = toU16(@min(width -| 4, 70));

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
    const display_input = if (input.len > 0) input else "(type file path or magnet URI)";
    const hint = hint_style.render(alloc, "Magnet links start with magnet:") catch "";

    const inner = std.fmt.allocPrint(
        alloc,
        "{s}\n\n> {s}\n\n{s}\n\n[Enter] Confirm  [Esc] Cancel",
        .{ title, display_input, hint },
    ) catch "Dialog";

    const boxed = box_style.render(alloc, inner) catch inner;
    return zz.place.place(alloc, width, height, .center, .middle, boxed) catch boxed;
}

// ── Confirm delete dialog ───────────────────────────────────────

pub fn renderConfirmDeleteDialog(alloc: Allocator, torrent_name: []const u8, delete_files: bool, width: usize, height: usize) []const u8 {
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

// ── Login dialog ────────────────────────────────────────────────

pub fn renderLoginDialog(alloc: Allocator, username: []const u8, password_len: usize, active_field: u8, error_msg: ?[]const u8, width: usize, height: usize) []const u8 {
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

    const user_prefix: []const u8 = if (active_field == 0) "> " else "  ";
    const pass_prefix: []const u8 = if (active_field == 1) "> " else "  ";
    const user_display = if (username.len > 0) username else "(username)";
    const pass_display = makeRepeated(alloc, '*', password_len);
    const pass_show = if (password_len > 0) pass_display else "(password)";

    var inner = std.fmt.allocPrint(
        alloc,
        "{s}\n\n{s}Username: {s}\n{s}Password: {s}\n\n[Enter] Login  [Tab] Switch field  [Esc] Quit",
        .{ title, user_prefix, user_display, pass_prefix, pass_show },
    ) catch "";

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

// ── Detail view ─────────────────────────────────────────────────

pub fn renderDetailView(
    alloc: Allocator,
    torrent: api.TorrentInfo,
    props: api.TorrentProperties,
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
    var name_style = zz.Style{};
    name_style = name_style.bold(true);
    name_style = name_style.fg(colors.title);
    name_style = name_style.inline_style(true);
    const styled_name = name_style.render(alloc, torrent.name) catch torrent.name;
    w.print(" {s}\n", .{styled_name}) catch {};

    // Status line
    var size_buf: [32]u8 = undefined;
    var dl_buf: [32]u8 = undefined;
    var ul_buf: [32]u8 = undefined;
    w.print(" Status: {s}  Progress: {d:.1}%  DL: {s}  UP: {s}  Seeds: {d}/{d}  Peers: {d}/{d}\n", .{
        torrent.state.displayString(),
        torrent.progress * 100.0,
        api.formatSpeed(&dl_buf, torrent.dlspeed),
        api.formatSpeed(&ul_buf, torrent.upspeed),
        torrent.num_seeds,
        props.seeds_total,
        torrent.num_leechs,
        props.peers_total,
    }) catch {};

    // Size line
    var dl_data_buf: [32]u8 = undefined;
    var ul_data_buf: [32]u8 = undefined;
    w.print(" Size: {s}  Downloaded: {s}  Uploaded: {s}  Ratio: {d:.2}\n", .{
        api.formatSize(&size_buf, torrent.size),
        api.formatSize(&dl_data_buf, torrent.downloaded),
        api.formatSize(&ul_data_buf, torrent.uploaded),
        torrent.ratio,
    }) catch {};

    // Progress bar
    const bar_w = @min(width -| 4, @as(usize, 50));
    const bar = renderProgressBar(alloc, torrent.progress, bar_w);
    w.print(" {s}\n\n", .{bar}) catch {};

    // Tab bar
    const tab_names = [_]struct { label: []const u8, tab: DetailTab }{
        .{ .label = " General ", .tab = .general },
        .{ .label = " Trackers ", .tab = .trackers },
        .{ .label = " Files ", .tab = .files },
    };

    for (tab_names) |t| {
        if (t.tab == tab) {
            var tab_style = zz.Style{};
            tab_style = tab_style.bold(true);
            tab_style = tab_style.fg(colors.accent);
            tab_style = tab_style.inline_style(true);
            const styled = tab_style.render(alloc, t.label) catch t.label;
            w.print(" [{s}]", .{styled}) catch {};
        } else {
            var tab_style = zz.Style{};
            tab_style = tab_style.fg(colors.muted);
            tab_style = tab_style.inline_style(true);
            const styled = tab_style.render(alloc, t.label) catch t.label;
            w.print("  {s} ", .{styled}) catch {};
        }
    }

    var sep_style = zz.Style{};
    sep_style = sep_style.fg(colors.border);
    sep_style = sep_style.inline_style(true);
    const sep = sep_style.render(alloc, makeRepeated(alloc, '-', @min(width, @as(usize, 60)))) catch "";
    w.print("\n{s}\n\n", .{sep}) catch {};

    // Tab content
    switch (tab) {
        .general => renderGeneralTab(alloc, &lines, torrent, props),
        .trackers => renderTrackersTab(alloc, &lines, trackers, scroll_offset),
        .files => renderFilesTab(alloc, &lines, files, scroll_offset, width),
    }

    return lines.toOwnedSlice(alloc) catch "Error rendering detail view";
}

fn renderGeneralTab(alloc: Allocator, lines: *std.ArrayList(u8), t: api.TorrentInfo, props: api.TorrentProperties) void {
    const w = lines.writer(alloc);

    var size_buf: [32]u8 = undefined;
    var piece_buf: [32]u8 = undefined;

    const save_path = if (props.save_path.len > 0) props.save_path else t.save_path;

    w.print(
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
        t.hash,
        save_path,
        api.formatSize(&size_buf, props.total_size),
        props.pieces_num,
        api.formatSize(&piece_buf, props.piece_size),
        props.nb_connections,
        props.addition_date,
        t.tracker,
        if (t.category.len > 0) t.category else "(none)",
        if (t.tags.len > 0) t.tags else "(none)",
        if (props.comment.len > 0) props.comment else "(none)",
    }) catch {};
}

fn renderTrackersTab(alloc: Allocator, lines: *std.ArrayList(u8), trackers: []const api.TrackerEntry, scroll_offset: usize) void {
    const w = lines.writer(alloc);

    if (trackers.len == 0) {
        var dim_s = zz.Style{};
        dim_s = dim_s.fg(colors.muted);
        dim_s = dim_s.inline_style(true);
        const styled = dim_s.render(alloc, "  No tracker data available.") catch "  No tracker data.";
        w.print("{s}\n", .{styled}) catch {};
        return;
    }

    var start = scroll_offset;
    if (start >= trackers.len) start = 0;

    for (trackers[start..]) |tracker| {
        const status_str: []const u8 = switch (tracker.status) {
            0 => "Disabled",
            1 => "Not contacted",
            2 => "Working",
            3 => "Updating",
            4 => "Not working",
            else => "Unknown",
        };

        var url_s = zz.Style{};
        url_s = url_s.fg(colors.accent);
        url_s = url_s.inline_style(true);
        const styled_url = url_s.render(alloc, tracker.url) catch tracker.url;

        w.print("  [{s}] {s}", .{ status_str, styled_url }) catch {};
        if (tracker.msg.len > 0) {
            w.print("\n        Msg: {s}", .{tracker.msg}) catch {};
        }
        w.print("\n", .{}) catch {};
    }
}

fn renderFilesTab(alloc: Allocator, lines: *std.ArrayList(u8), files: []const api.FileEntry, scroll_offset: usize, width: usize) void {
    const w = lines.writer(alloc);

    if (files.len == 0) {
        var dim_s = zz.Style{};
        dim_s = dim_s.fg(colors.muted);
        dim_s = dim_s.inline_style(true);
        const styled = dim_s.render(alloc, "  No file data available.") catch "  No file data.";
        w.print("{s}\n", .{styled}) catch {};
        return;
    }

    var start = scroll_offset;
    if (start >= files.len) start = 0;

    for (files[start..]) |file| {
        const name_w = if (width > 40) width - 30 else 10;
        var size_buf: [32]u8 = undefined;
        const display_name = truncate(file.name, name_w);
        w.print("  {d:<5} {s}  {s}  {d:.1}%  pri={d}\n", .{
            file.index,
            padRight(alloc, display_name, name_w),
            padLeft(alloc, api.formatSize(&size_buf, file.size), 9),
            file.progress * 100.0,
            file.priority,
        }) catch {};
    }
}

// ── Preferences view ────────────────────────────────────────────

pub fn renderPreferencesView(alloc: Allocator, prefs: api.Preferences, width: usize, height: usize) []const u8 {
    _ = height;

    var title_style = zz.Style{};
    title_style = title_style.bold(true);
    title_style = title_style.fg(colors.title);
    title_style = title_style.inline_style(true);

    const title = title_style.render(alloc, " Daemon Preferences") catch " Daemon Preferences";

    var sep_style = zz.Style{};
    sep_style = sep_style.fg(colors.border);
    sep_style = sep_style.inline_style(true);
    const sep = sep_style.render(alloc, makeRepeated(alloc, '-', @min(width, @as(usize, 40)))) catch "";

    var dl_buf: [32]u8 = undefined;
    var ul_buf: [32]u8 = undefined;
    const dl_limit_str = if (prefs.dl_limit == 0) "Unlimited" else api.formatSpeed(&dl_buf, prefs.dl_limit);
    const up_limit_str = if (prefs.up_limit == 0) "Unlimited" else api.formatSpeed(&ul_buf, prefs.up_limit);

    const body = std.fmt.allocPrint(alloc,
        \\  Listen port:           {d}
        \\  Download limit:        {s}
        \\  Upload limit:          {s}
        \\  Max connections:       {d}
        \\  Max conn/torrent:      {d}
        \\  Max uploads:           {d}
        \\  Max uploads/torrent:   {d}
        \\  DHT:                   {s}
        \\  PEX:                   {s}
        \\  uTP:                   {s}
        \\  Save path:             {s}
        \\  WebUI port:            {d}
    , .{
        prefs.listen_port,
        dl_limit_str,
        up_limit_str,
        prefs.max_connec,
        prefs.max_connec_per_torrent,
        prefs.max_uploads,
        prefs.max_uploads_per_torrent,
        @as([]const u8, if (prefs.dht) "Enabled" else "Disabled"),
        @as([]const u8, if (prefs.pex) "Enabled" else "Disabled"),
        @as([]const u8, if (prefs.enable_utp) "Enabled" else "Disabled"),
        prefs.save_path,
        prefs.web_ui_port,
    }) catch "";

    return std.fmt.allocPrint(alloc, "{s}\n{s}\n{s}", .{ title, sep, body }) catch "";
}
