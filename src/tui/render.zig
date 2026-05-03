const std = @import("std");
const zz = @import("zigzag");
const model = @import("model.zig");
const mock_data = @import("mock_data.zig");

pub const RenderOptions = struct {
    width: u16 = 120,
    height: u16 = 36,
    color: bool = true,
};

const Style = enum { reset, dim, bright, accent, blue, green, marked, inverse };

pub fn renderFrame(allocator: std.mem.Allocator, state: *const model.AppState, options: RenderOptions) ![]u8 {
    const width: usize = @max(options.width, 82);
    const height: usize = @max(options.height, 24);
    const color = options.color;
    const main_h: usize = height - 5;

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try renderTop(&out, allocator, state, width, color);
    try appendHRule(&out, allocator, width);

    const left_w = clamp(width / 6, 22, 30);
    const right_w = clamp(width / 4, 34, 52);
    const center_w = width - left_w - right_w - 4;
    const modal_h: usize = 7;
    const modal_w: usize = @min(width - 8, @as(usize, 72));
    const modal_top = if (main_h > modal_h) (main_h - modal_h) / 2 else 0;

    try appendPanelRule(&out, allocator, left_w, center_w, right_w, .top);
    var row: usize = 0;
    while (row < main_h) : (row += 1) {
        if (state.add_torrent_open and row >= modal_top and row < modal_top + modal_h) {
            try renderModalOverlayRow(&out, allocator, state, row - modal_top, width, modal_w, color);
        } else {
            try renderMainRow(&out, allocator, state, row, left_w, center_w, right_w, color);
        }
    }
    try appendPanelRule(&out, allocator, left_w, center_w, right_w, .bottom);

    try renderFooter(&out, allocator, width, color);
    return out.toOwnedSlice(allocator);
}

fn renderTop(out: *std.ArrayList(u8), allocator: std.mem.Allocator, state: *const model.AppState, width: usize, color: bool) !void {
    var line = std.ArrayList(u8).empty;
    defer line.deinit(allocator);

    const totals = computeTotals(state);
    try style(&line, allocator, " varuna ", .accent, color);
    try line.appendSlice(allocator, "v0.1 mock  ");
    try style(&line, allocator, "UP ", .green, color);
    try line.print(allocator, "{d:.1} MiB/s  ", .{totals.up});
    try style(&line, allocator, "DN ", .blue, color);
    try line.print(allocator, "{d:.1} MiB/s  ", .{totals.down});
    try line.print(allocator, "{d} seeding  {d} downloading  {d} paused", .{ totals.seeding, totals.downloading, totals.paused });
    try line.print(allocator, "  selected: {s}", .{state.selectedTorrentConst().name});
    try appendPadded(out, allocator, line.items, width);
    try out.append(allocator, '\n');
}

fn renderMainRow(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    state: *const model.AppState,
    row: usize,
    left_w: usize,
    center_w: usize,
    right_w: usize,
    color: bool,
) !void {
    try out.appendSlice(allocator, "│");
    try renderLeftCell(out, allocator, state, row, left_w, color);
    try out.appendSlice(allocator, "│");
    try renderTorrentCell(out, allocator, state, row, center_w, color);
    try out.appendSlice(allocator, "│");
    try renderDetailCell(out, allocator, state, row, right_w, color);
    try out.appendSlice(allocator, "│\n");
}

fn renderLeftCell(out: *std.ArrayList(u8), allocator: std.mem.Allocator, state: *const model.AppState, row: usize, width: usize, color: bool) !void {
    var cell = std.ArrayList(u8).empty;
    defer cell.deinit(allocator);
    switch (row) {
        0 => try panelTitle(&cell, allocator, "Filters [1]", state.active_pane == .filters, color),
        1 => try filterRow(&cell, allocator, model.Filter.all.label(), state.torrents.len, state.filter_index == 0, color),
        2 => try filterRow(&cell, allocator, model.Filter.downloading.label(), countStatus(state, .downloading), state.filter_index == 1, color),
        3 => try filterRow(&cell, allocator, model.Filter.seeding.label(), countStatus(state, .seeding), state.filter_index == 2, color),
        4 => try filterRow(&cell, allocator, model.Filter.paused.label(), countPaused(state), state.filter_index == 3, color),
        5 => try filterRow(&cell, allocator, model.Filter.errored.label(), countStatus(state, .errored), state.filter_index == 4, color),
        7 => try style(&cell, allocator, "TRACKERS", .dim, color),
        8 => try filterRow(&cell, allocator, "linuxtracker.org", 6, false, color),
        9 => try filterRow(&cell, allocator, "archive.org", 4, false, color),
        10 => try filterRow(&cell, allocator, "flacsforall.org", 2, false, color),
        11 => try filterRow(&cell, allocator, "pubtorrent.io", 3, false, color),
        13 => try style(&cell, allocator, "CATEGORIES", .dim, color),
        14 => try filterRow(&cell, allocator, "#linux", 6, false, color),
        15 => try filterRow(&cell, allocator, "#audio", 2, false, color),
        16 => try filterRow(&cell, allocator, "#video", 2, false, color),
        17 => try filterRow(&cell, allocator, "#archive", 3, false, color),
        else => {},
    }
    try appendPadded(out, allocator, cell.items, width);
}

fn renderTorrentCell(out: *std.ArrayList(u8), allocator: std.mem.Allocator, state: *const model.AppState, row: usize, width: usize, color: bool) !void {
    var cell = std.ArrayList(u8).empty;
    defer cell.deinit(allocator);
    if (row == 0) {
        try panelTitle(&cell, allocator, "Torrents [2]", state.active_pane == .torrents, color);
        try cell.print(allocator, "  {d}", .{state.visibleTorrentCount()});
    } else if (row == 1) {
        try appendTorrentHeader(&cell, allocator, width, color);
    } else {
        const visible_row = row - 2;
        if (state.visibleTorrentIndexAt(visible_row)) |idx| {
            try appendTorrentRow(&cell, allocator, &state.torrents[idx], idx == state.selected_index, state.marked[idx], width, color);
        }
    }
    try appendPadded(out, allocator, cell.items, width);
}

fn renderDetailCell(out: *std.ArrayList(u8), allocator: std.mem.Allocator, state: *const model.AppState, row: usize, width: usize, color: bool) !void {
    var cell = std.ArrayList(u8).empty;
    defer cell.deinit(allocator);
    const torrent = state.selectedTorrentConst();
    if (row == 0) {
        try panelTitle(&cell, allocator, "Detail [3]", state.active_pane == .detail, color);
    } else if (row == 1) {
        inline for (.{ model.DetailTab.files, model.DetailTab.peers, model.DetailTab.trackers, model.DetailTab.info }, 0..) |tab, i| {
            if (i != 0) try cell.append(allocator, ' ');
            try style(&cell, allocator, tab.label(), if (state.detail_tab == tab) .accent else .dim, color);
        }
    } else if (row == 2) {
        try cell.print(allocator, "{s}  {d:.0}%  ratio {d:.2}", .{ torrent.status.label(), torrent.progress * 100.0, torrent.ratio });
    } else if (row == 3) {
        try progressBar(&cell, allocator, torrent.progress, @min(width, @as(usize, 28)), torrent.status);
    } else {
        switch (state.detail_tab) {
            .files => try renderFilesDetail(&cell, allocator, torrent, row - 4, color),
            .peers => try renderPeersDetail(&cell, allocator, torrent, row - 4, color),
            .trackers => try renderTrackersDetail(&cell, allocator, torrent, row - 4),
            .info => try renderInfoDetail(&cell, allocator, torrent, row - 4),
        }
    }
    try appendPadded(out, allocator, cell.items, width);
}

fn appendTorrentHeader(out: *std.ArrayList(u8), allocator: std.mem.Allocator, width: usize, color: bool) !void {
    const name_w = torrentNameWidth(width);
    try appendPadded(out, allocator, "M ST", 5);
    try out.append(allocator, ' ');
    try appendPadded(out, allocator, "NAME", name_w);
    try out.append(allocator, ' ');
    try appendLeftPad(out, allocator, "DONE", 6);
    try out.append(allocator, ' ');
    try appendLeftPad(out, allocator, "DN", 7);
    try out.append(allocator, ' ');
    try appendLeftPad(out, allocator, "UP", 7);
    try out.append(allocator, ' ');
    try style(out, allocator, "PEERS", .dim, color);
}

fn appendTorrentRow(out: *std.ArrayList(u8), allocator: std.mem.Allocator, torrent: *const mock_data.Torrent, selected: bool, marked: bool, width: usize, color: bool) !void {
    var row = std.ArrayList(u8).empty;
    defer row.deinit(allocator);
    const name_w = torrentNameWidth(width);
    try row.appendSlice(allocator, if (selected) "▶" else " ");
    try row.appendSlice(allocator, if (marked) "●" else " ");
    try row.appendSlice(allocator, torrent.status.short());
    try row.append(allocator, ' ');
    try appendPadded(&row, allocator, torrent.name, name_w);
    try row.append(allocator, ' ');
    try appendPercent(&row, allocator, torrent.progress, 6);
    try row.append(allocator, ' ');
    try appendRate(&row, allocator, torrent.down_mib, 7);
    try row.append(allocator, ' ');
    try appendRate(&row, allocator, torrent.up_mib, 7);
    try row.append(allocator, ' ');
    try appendPeers(&row, allocator, torrent.seeds, torrent.peers, 7);
    if (selected and color) {
        try style(out, allocator, "", .inverse, color);
        try appendPadded(out, allocator, row.items, width);
        try style(out, allocator, "", .reset, color);
    } else if (marked and color) {
        try style(out, allocator, row.items, .marked, color);
        const row_width = zz.measure.width(row.items);
        if (row_width < width) try appendRepeat(out, allocator, ' ', width - row_width);
    } else {
        try appendPadded(out, allocator, row.items, width);
    }
}

fn renderFilesDetail(out: *std.ArrayList(u8), allocator: std.mem.Allocator, torrent: *const mock_data.Torrent, row: usize, color: bool) !void {
    if (row >= torrent.files.len) return;
    const file = torrent.files[row];
    try style(out, allocator, if (file.skipped) "skip " else "ok   ", if (file.skipped) .dim else .green, color);
    try out.appendSlice(allocator, file.path);
    try out.print(allocator, "  {d:.2} GiB", .{file.size_gib});
}

fn renderPeersDetail(out: *std.ArrayList(u8), allocator: std.mem.Allocator, torrent: *const mock_data.Torrent, row: usize, color: bool) !void {
    if (row >= torrent.peers_list.len) return;
    const peer = torrent.peers_list[row];
    try style(out, allocator, peer.address, .blue, color);
    try out.print(allocator, "  {s}  dn {d:.1} up {d:.1}  {d:.0}%", .{ peer.client, peer.down_mib, peer.up_mib, peer.progress * 100.0 });
}

fn renderTrackersDetail(out: *std.ArrayList(u8), allocator: std.mem.Allocator, torrent: *const mock_data.Torrent, row: usize) !void {
    switch (row) {
        0 => try out.print(allocator, "{s}  working  next announce 00:12", .{torrent.tracker}),
        1 => try out.appendSlice(allocator, "backup.tracker.local  idle"),
        2 => try out.appendSlice(allocator, "udp://tracker.example:6969  disabled"),
        else => {},
    }
}

fn renderInfoDetail(out: *std.ArrayList(u8), allocator: std.mem.Allocator, torrent: *const mock_data.Torrent, row: usize) !void {
    switch (row) {
        0 => try out.print(allocator, "Name: {s}", .{torrent.name}),
        1 => try out.print(allocator, "Category: {s}", .{torrent.category}),
        2 => try out.print(allocator, "State: {s}", .{torrent.status.label()}),
        3 => try out.print(allocator, "ETA: {d} min", .{torrent.eta_min}),
        4 => try out.print(allocator, "Tracker: {s}", .{torrent.tracker}),
        else => {},
    }
}

fn renderModalOverlayRow(out: *std.ArrayList(u8), allocator: std.mem.Allocator, state: *const model.AppState, row: usize, width: usize, modal_w: usize, color: bool) !void {
    const left_pad = (width - modal_w) / 2;
    const right_pad = width - modal_w - left_pad;
    try appendRepeat(out, allocator, ' ', left_pad);
    switch (row) {
        0 => {
            try out.appendSlice(allocator, "╭");
            try appendGlyphRepeat(out, allocator, "─", modal_w - 2);
            try out.appendSlice(allocator, "╮");
        },
        1 => try renderModalLine(out, allocator, "Add torrent", modal_w, .accent, color),
        2 => try renderModalLine(out, allocator, "Paste a magnet link, info hash, or .torrent path", modal_w, .bright, color),
        3 => {
            var input = std.ArrayList(u8).empty;
            defer input.deinit(allocator);
            try style(&input, allocator, "› ", .accent, color);
            try input.appendSlice(allocator, state.addTorrentInput());
            if (state.addTorrentInput().len == 0) {
                try style(&input, allocator, "magnet:?xt=urn:btih:...", .dim, color);
            }
            try renderModalLine(out, allocator, input.items, modal_w, .reset, false);
        },
        4 => try renderModalLine(out, allocator, "Enter adds mock torrent   Esc cancels", modal_w, .dim, color),
        5 => try renderModalLine(out, allocator, "", modal_w, .reset, color),
        else => {
            try out.appendSlice(allocator, "╰");
            try appendGlyphRepeat(out, allocator, "─", modal_w - 2);
            try out.appendSlice(allocator, "╯");
        },
    }
    try appendRepeat(out, allocator, ' ', right_pad);
    try out.append(allocator, '\n');
}

fn renderModalLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, width: usize, text_style: Style, color: bool) !void {
    try out.appendSlice(allocator, "│ ");
    var line = std.ArrayList(u8).empty;
    defer line.deinit(allocator);
    try style(&line, allocator, text, text_style, color);
    try appendPadded(out, allocator, line.items, width - 4);
    try out.appendSlice(allocator, " │");
}

fn renderNetwork(out: *std.ArrayList(u8), allocator: std.mem.Allocator, state: *const model.AppState, width: usize, height: usize, color: bool) !void {
    try appendBoxRule(out, allocator, width);
    const totals = computeTotals(state);
    var row: usize = 0;
    while (row + 2 < height) : (row += 1) {
        try out.append(allocator, '|');
        if (row == 0) {
            var title = std.ArrayList(u8).empty;
            defer title.deinit(allocator);
            try panelTitle(&title, allocator, "Network", false, color);
            try title.print(allocator, "  last 60s  peak 170.5 MiB/s  dn {d:.1} MiB/s  up {d:.1} MiB/s", .{ totals.down, totals.up });
            try appendPadded(out, allocator, title.items, width - 2);
        } else {
            try out.append(allocator, ' ');
            const graph_w = @min(width - 4, @as(usize, 78));
            const fill = @min(graph_w, 14 + ((row * 11 + state.selected_index) % 30));
            try style(out, allocator, "", if (row % 2 == 0) .blue else .accent, color);
            try appendRepeat(out, allocator, '#', fill);
            try style(out, allocator, "", .reset, color);
            try appendRepeat(out, allocator, '.', graph_w - fill);
            try appendPadded(out, allocator, "", width - graph_w - 3);
        }
        try out.appendSlice(allocator, "|\n");
    }
    try appendBoxRule(out, allocator, width);
}

fn renderFooter(out: *std.ArrayList(u8), allocator: std.mem.Allocator, width: usize, color: bool) !void {
    var footer = std.ArrayList(u8).empty;
    defer footer.deinit(allocator);
    try key(&footer, allocator, "j/k", "nav", color);
    try key(&footer, allocator, "h/l", "pane", color);
    try key(&footer, allocator, "space", "pause", color);
    try key(&footer, allocator, "m", "mark", color);
    try key(&footer, allocator, "a", "add", color);
    try key(&footer, allocator, "[/]", "tab", color);
    try key(&footer, allocator, "/", "filter", color);
    try key(&footer, allocator, "d", "remove", color);
    try key(&footer, allocator, "?", "help", color);
    try key(&footer, allocator, "q", "quit", color);
    try appendPadded(out, allocator, footer.items, width);
    try out.append(allocator, '\n');
}

fn panelTitle(out: *std.ArrayList(u8), allocator: std.mem.Allocator, title: []const u8, active: bool, color: bool) !void {
    try style(out, allocator, title, if (active) .accent else .bright, color);
}

fn filterRow(out: *std.ArrayList(u8), allocator: std.mem.Allocator, label: []const u8, count: usize, active: bool, color: bool) !void {
    if (active) try style(out, allocator, "> ", .accent, color) else try out.appendSlice(allocator, "  ");
    try out.appendSlice(allocator, label);
    try out.print(allocator, " {d}", .{count});
}

fn key(out: *std.ArrayList(u8), allocator: std.mem.Allocator, lhs: []const u8, rhs: []const u8, color: bool) !void {
    try style(out, allocator, lhs, .accent, color);
    try out.append(allocator, ' ');
    try style(out, allocator, rhs, .dim, color);
    try out.appendSlice(allocator, "  ");
}

fn progressBar(out: *std.ArrayList(u8), allocator: std.mem.Allocator, progress: f64, width: usize, status: mock_data.TorrentStatus) !void {
    const fill: usize = @intFromFloat(@floor(@max(0, @min(1, progress)) * @as(f64, @floatFromInt(width))));
    const fill_glyph = switch (status) {
        .paused => "▒",
        .errored => "▓",
        else => "█",
    };
    try out.appendSlice(allocator, "▕");
    try appendGlyphRepeat(out, allocator, fill_glyph, fill);
    try appendGlyphRepeat(out, allocator, "░", width - fill);
    try out.appendSlice(allocator, "▏");
}

fn style(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, s: Style, enabled: bool) !void {
    if (!enabled or text.len == 0) {
        try out.appendSlice(allocator, text);
        return;
    }

    const styled = styleFor(s);
    const rendered = try styled.render(allocator, text);
    defer allocator.free(rendered);
    try out.appendSlice(allocator, rendered);
}

fn styleFor(s: Style) zz.Style {
    return switch (s) {
        .reset => zz.Style{},
        .dim => (zz.Style{}).fg(zz.Color.brightBlack()).dim(true),
        .bright => (zz.Style{}).fg(zz.Color.brightWhite()).bold(true),
        .accent => (zz.Style{}).fg(zz.Color.brightMagenta()).bold(true),
        .blue => (zz.Style{}).fg(zz.Color.brightBlue()).bold(true),
        .green => (zz.Style{}).fg(zz.Color.brightGreen()).bold(true),
        .marked => (zz.Style{}).fg(zz.Color.brightYellow()).bold(true),
        .inverse => (zz.Style{}).reverse(true),
    };
}

fn appendRate(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: f64, width: usize) !void {
    var buf: [32]u8 = undefined;
    const text = if (value <= 0.05) "-" else std.fmt.bufPrint(&buf, "{d:.1}M", .{value}) catch "-";
    try appendLeftPad(out, allocator, text, width);
}

fn appendPercent(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: f64, width: usize) !void {
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:.0}%", .{@max(0, @min(100, value * 100.0))}) catch "-";
    try appendLeftPad(out, allocator, text, width);
}

fn appendPeers(out: *std.ArrayList(u8), allocator: std.mem.Allocator, seeds: u32, peers: u32, width: usize) !void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}/{d}", .{ seeds, peers }) catch "-";
    try appendLeftPad(out, allocator, text, width);
}

fn appendPadded(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, width: usize) !void {
    const visible_width = zz.measure.width(text);
    if (visible_width >= width) {
        const clipped = try zz.measure.truncate(allocator, text, width);
        defer allocator.free(clipped);
        try out.appendSlice(allocator, clipped);
        return;
    }
    try out.appendSlice(allocator, text);
    try appendRepeat(out, allocator, ' ', width - visible_width);
}

fn appendLeftPad(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, width: usize) !void {
    const visible_width = zz.measure.width(text);
    if (visible_width >= width) {
        const clipped = try zz.measure.truncate(allocator, text, width);
        defer allocator.free(clipped);
        try out.appendSlice(allocator, clipped);
        return;
    }
    try appendRepeat(out, allocator, ' ', width - visible_width);
    try out.appendSlice(allocator, text);
}

fn appendRepeat(out: *std.ArrayList(u8), allocator: std.mem.Allocator, ch: u8, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try out.append(allocator, ch);
}

fn appendGlyphRepeat(out: *std.ArrayList(u8), allocator: std.mem.Allocator, glyph: []const u8, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try out.appendSlice(allocator, glyph);
}

fn appendHRule(out: *std.ArrayList(u8), allocator: std.mem.Allocator, width: usize) !void {
    try appendGlyphRepeat(out, allocator, "─", width);
    try out.append(allocator, '\n');
}

const PanelRule = enum { top, bottom };

fn appendPanelRule(out: *std.ArrayList(u8), allocator: std.mem.Allocator, left_w: usize, center_w: usize, right_w: usize, rule: PanelRule) !void {
    const chars = switch (rule) {
        .top => .{ "┌", "┬", "┐" },
        .bottom => .{ "└", "┴", "┘" },
    };
    try out.appendSlice(allocator, chars[0]);
    try appendGlyphRepeat(out, allocator, "─", left_w);
    try out.appendSlice(allocator, chars[1]);
    try appendGlyphRepeat(out, allocator, "─", center_w);
    try out.appendSlice(allocator, chars[1]);
    try appendGlyphRepeat(out, allocator, "─", right_w);
    try out.appendSlice(allocator, chars[2]);
    try out.append(allocator, '\n');
}

fn appendBoxRule(out: *std.ArrayList(u8), allocator: std.mem.Allocator, width: usize) !void {
    try out.appendSlice(allocator, "┌");
    try appendGlyphRepeat(out, allocator, "─", width - 2);
    try out.appendSlice(allocator, "┐\n");
}

fn torrentNameWidth(width: usize) usize {
    const fixed_w = 5 + 1 + 6 + 1 + 7 + 1 + 7 + 1 + 7;
    if (width <= fixed_w + 10) return @max(@as(usize, 8), width / 4);
    return width - fixed_w;
}

fn countStatus(state: *const model.AppState, status: mock_data.TorrentStatus) usize {
    var count: usize = 0;
    for (state.torrents) |torrent| {
        if (torrent.status == status) count += 1;
    }
    return count;
}

fn countPaused(state: *const model.AppState) usize {
    var count: usize = 0;
    for (state.torrents) |torrent| {
        if (torrent.paused) count += 1;
    }
    return count;
}

const Totals = struct {
    down: f64 = 0,
    up: f64 = 0,
    seeding: usize = 0,
    downloading: usize = 0,
    paused: usize = 0,
};

fn computeTotals(state: *const model.AppState) Totals {
    var totals = Totals{};
    for (state.torrents) |torrent| {
        totals.down += torrent.down_mib;
        totals.up += torrent.up_mib;
        switch (torrent.status) {
            .seeding => totals.seeding += 1,
            .downloading => totals.downloading += 1,
            .paused => totals.paused += 1,
            else => {},
        }
    }
    return totals;
}

fn clamp(value: usize, min: usize, max: usize) usize {
    return @min(max, @max(min, value));
}

test "render produces requested number of lines" {
    var state = model.AppState.init();
    const frame = try renderFrame(std.testing.allocator, &state, .{ .width = 100, .height = 28, .color = false });
    defer std.testing.allocator.free(frame);
    var lines: usize = 0;
    for (frame) |ch| {
        if (ch == '\n') lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 28), lines);
}
