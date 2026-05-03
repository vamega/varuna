const std = @import("std");
const zz = @import("zigzag");
const ui = @import("components.zig");
const model = @import("model.zig");
const mock_data = @import("mock_data.zig");

const Style = ui.Style;
const Symbols = ui.Symbols;
const appendBoxRule = ui.appendBoxRule;
const appendGlyphRepeat = ui.appendGlyphRepeat;
const appendHRule = ui.appendHRule;
const appendLeftPad = ui.appendLeftPad;
const appendMiniProgress = ui.miniProgress;
const appendPadded = ui.appendPadded;
const appendPanelRule = ui.appendPanelRule;
const appendPeers = ui.appendPeers;
const appendRate = ui.appendRate;
const appendRepeat = ui.appendRepeat;
const filterRow = ui.filterRow;
const key = ui.key;
const panelTitle = ui.panelTitle;
const progressBar = ui.progressBar;
const renderModalLine = ui.modalLine;
const statusGlyph = ui.statusGlyph;
const statusStyle = ui.statusStyle;
const style = ui.style;

pub const RenderOptions = struct {
    width: u16 = 120,
    height: u16 = 36,
    color: bool = true,
};

pub fn renderFrame(allocator: std.mem.Allocator, state: *const model.AppState, options: RenderOptions) ![]u8 {
    const width: usize = @max(options.width, 82);
    const height: usize = @max(options.height, 5);
    const color = options.color;
    const main_h: usize = height - 5;
    const symbols = ui.symbolsFor(state.symbol_set);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try renderTop(&out, allocator, state, symbols, width, color);
    try appendHRule(&out, allocator, width);

    const left_w = clamp(width / 6, 22, 30);
    const right_w = clamp(width / 4, 34, 52);
    const center_w = width - left_w - right_w - 4;
    const modal_h: usize = 7;
    const modal_w: usize = @min(width - 8, @as(usize, 72));
    const modal_top = if (main_h > modal_h) (main_h - modal_h) / 2 else 0;

    try appendPanelRule(&out, allocator, left_w, center_w, right_w, .top);
    const modal_open = state.add_torrent_open or state.filter_open or state.settings_open;
    var row: usize = 0;
    while (row < main_h) : (row += 1) {
        if (modal_open and row >= modal_top and row < modal_top + modal_h) {
            try renderModalOverlayRow(&out, allocator, state, symbols, row - modal_top, width, modal_w, color);
        } else {
            try renderMainRow(&out, allocator, state, symbols, row, main_h, left_w, center_w, right_w, color);
        }
    }
    try appendPanelRule(&out, allocator, left_w, center_w, right_w, .bottom);

    try renderFooter(&out, allocator, width, color);
    return out.toOwnedSlice(allocator);
}

fn renderTop(out: *std.ArrayList(u8), allocator: std.mem.Allocator, state: *const model.AppState, symbols: Symbols, width: usize, color: bool) !void {
    var line = std.ArrayList(u8).empty;
    defer line.deinit(allocator);

    const totals = computeTotals(state);
    try style(&line, allocator, symbols.brand, .accent, color);
    try style(&line, allocator, " varuna ", .bright, color);
    try style(&line, allocator, "v0.1 mock", .dim, color);
    try line.appendSlice(allocator, "  ·  ");
    try style(&line, allocator, symbols.up, .green, color);
    try line.append(allocator, ' ');
    try line.print(allocator, "{d:.1} MiB/s  ", .{totals.up});
    try style(&line, allocator, symbols.down, .blue, color);
    try line.append(allocator, ' ');
    try line.print(allocator, "{d:.1} MiB/s  ", .{totals.down});
    try style(&line, allocator, symbols.seed, .green, color);
    try line.print(allocator, " {d} seeding  ", .{totals.seeding});
    try style(&line, allocator, symbols.down, .blue, color);
    try line.print(allocator, " {d} dn  ", .{totals.downloading});
    try style(&line, allocator, symbols.pause, .yellow, color);
    try line.print(allocator, " {d} paused  ", .{totals.paused});
    try style(&line, allocator, symbols.settings, .accent, color);
    try line.print(allocator, " {s}", .{state.symbol_set.label()});
    try line.print(allocator, "  ·  selected: {s}", .{state.selectedTorrentConst().name});
    try appendPadded(out, allocator, line.items, width);
    try out.append(allocator, '\n');
}

fn renderMainRow(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    state: *const model.AppState,
    symbols: Symbols,
    row: usize,
    main_h: usize,
    left_w: usize,
    center_w: usize,
    right_w: usize,
    color: bool,
) !void {
    try out.appendSlice(allocator, "│");
    try renderLeftCell(out, allocator, state, row, left_w, color);
    try out.appendSlice(allocator, "│");
    try renderTorrentCell(out, allocator, state, symbols, row, main_h, center_w, color);
    try out.appendSlice(allocator, "│");
    try renderDetailCell(out, allocator, state, symbols, row, main_h, right_w, color);
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

fn renderTorrentCell(out: *std.ArrayList(u8), allocator: std.mem.Allocator, state: *const model.AppState, symbols: Symbols, row: usize, main_h: usize, width: usize, color: bool) !void {
    var cell = std.ArrayList(u8).empty;
    defer cell.deinit(allocator);
    if (row == 0) {
        try panelTitle(&cell, allocator, "Torrents [2]", state.active_pane == .torrents, color);
        try cell.print(allocator, "  {d}  sort {s}{s}", .{ state.visibleTorrentCount(), state.sort_key.label(), state.sort_direction.symbol() });
        if (state.filterQuery().len > 0) try cell.print(allocator, "  filter {s}", .{state.filterQuery()});
    } else if (row == 1) {
        try appendTorrentHeader(&cell, allocator, width, color);
    } else {
        const visible_rows = main_h -| 2;
        const visible_row = state.effectiveTorrentScrollOffset(visible_rows) + row - 2;
        if (state.visibleTorrentIndexAt(visible_row)) |idx| {
            try appendTorrentRow(&cell, allocator, &state.torrents[idx], symbols, idx == state.selected_index, state.marked[idx], width, color);
        }
    }
    try appendPadded(out, allocator, cell.items, width);
}

fn renderDetailCell(out: *std.ArrayList(u8), allocator: std.mem.Allocator, state: *const model.AppState, symbols: Symbols, row: usize, main_h: usize, width: usize, color: bool) !void {
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
        try progressBar(&cell, allocator, torrent.progress, @min(width, @as(usize, 28)), torrent.status, color);
    } else {
        const visible_rows = main_h -| 4;
        const detail_row = state.effectiveDetailScrollOffset(visible_rows) + row - 4;
        if (detail_row < state.detailItemCount()) {
            const selected = state.active_pane == .detail and detail_row == state.detail_selected_row;
            try cell.appendSlice(allocator, if (selected) symbols.selected else " ");
            try cell.append(allocator, ' ');
            switch (state.detail_tab) {
                .files => try renderFilesDetail(&cell, allocator, torrent, symbols, detail_row, color),
                .peers => try renderPeersDetail(&cell, allocator, torrent, symbols, detail_row, color),
                .trackers => try renderTrackersDetail(&cell, allocator, torrent, detail_row),
                .info => try renderInfoDetail(&cell, allocator, torrent, detail_row),
            }
        }
    }
    try appendPadded(out, allocator, cell.items, width);
}

fn appendTorrentHeader(out: *std.ArrayList(u8), allocator: std.mem.Allocator, width: usize, color: bool) !void {
    const name_w = torrentNameWidth(width);
    try appendPadded(out, allocator, "M  ST", 8);
    try out.append(allocator, ' ');
    try appendPadded(out, allocator, "NAME", name_w);
    try out.append(allocator, ' ');
    try appendLeftPad(out, allocator, "PROGRESS", 12);
    try out.append(allocator, ' ');
    try appendLeftPad(out, allocator, "DN", 7);
    try out.append(allocator, ' ');
    try appendLeftPad(out, allocator, "UP", 7);
    try out.append(allocator, ' ');
    try style(out, allocator, "PEERS", .dim, color);
}

fn appendTorrentRow(out: *std.ArrayList(u8), allocator: std.mem.Allocator, torrent: *const mock_data.Torrent, symbols: Symbols, selected: bool, marked: bool, width: usize, color: bool) !void {
    var row = std.ArrayList(u8).empty;
    defer row.deinit(allocator);
    const name_w = torrentNameWidth(width);
    try row.appendSlice(allocator, if (selected) symbols.selected else " ");
    try row.appendSlice(allocator, if (marked) symbols.marked else " ");
    try row.append(allocator, ' ');
    try row.appendSlice(allocator, statusGlyph(torrent, symbols));
    try row.append(allocator, ' ');
    try row.appendSlice(allocator, torrent.status.short());
    const prefix_width = zz.measure.width(row.items);
    if (prefix_width < 8) try appendRepeat(&row, allocator, ' ', 8 - prefix_width);
    try row.append(allocator, ' ');
    try appendPadded(&row, allocator, torrent.name, name_w);
    try row.append(allocator, ' ');
    try appendMiniProgress(&row, allocator, torrent.progress, 12, torrent.status, false);
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
    } else if (color) {
        try appendTorrentRowStyled(out, allocator, torrent, symbols, width, color);
    } else {
        try appendPadded(out, allocator, row.items, width);
    }
}

fn appendTorrentRowStyled(out: *std.ArrayList(u8), allocator: std.mem.Allocator, torrent: *const mock_data.Torrent, symbols: Symbols, width: usize, color: bool) !void {
    const name_w = torrentNameWidth(width);
    try appendPadded(out, allocator, "  ", 2);
    try out.append(allocator, ' ');
    try style(out, allocator, statusGlyph(torrent, symbols), statusStyle(torrent.status), color);
    try out.append(allocator, ' ');
    try style(out, allocator, torrent.status.short(), statusStyle(torrent.status), color);
    const prefix_width = 2 + 1 + zz.measure.width(statusGlyph(torrent, symbols)) + 1 + zz.measure.width(torrent.status.short());
    if (prefix_width < 8) try appendRepeat(out, allocator, ' ', 8 - prefix_width);
    try out.append(allocator, ' ');
    try appendPadded(out, allocator, torrent.name, name_w);
    try out.append(allocator, ' ');
    try appendMiniProgress(out, allocator, torrent.progress, 12, torrent.status, color);
    try out.append(allocator, ' ');
    try appendStyledRate(out, allocator, torrent.down_mib, 7, .blue, color);
    try out.append(allocator, ' ');
    try appendStyledRate(out, allocator, torrent.up_mib, 7, .green, color);
    try out.append(allocator, ' ');
    try appendStyledPeers(out, allocator, torrent.seeds, torrent.peers, 7, .dim, color);
    const row_width = zz.measure.width(out.items);
    if (row_width < width) try appendRepeat(out, allocator, ' ', width - row_width);
}

fn appendStyledRate(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: f64, width: usize, s: Style, color: bool) !void {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);
    try appendRate(&text, allocator, value, width);
    try style(out, allocator, text.items, s, color);
}

fn appendStyledPeers(out: *std.ArrayList(u8), allocator: std.mem.Allocator, seeds: u32, peers: u32, width: usize, s: Style, color: bool) !void {
    var text = std.ArrayList(u8).empty;
    defer text.deinit(allocator);
    try appendPeers(&text, allocator, seeds, peers, width);
    try style(out, allocator, text.items, s, color);
}

fn renderFilesDetail(out: *std.ArrayList(u8), allocator: std.mem.Allocator, torrent: *const mock_data.Torrent, symbols: Symbols, row: usize, color: bool) !void {
    if (row >= torrent.files.len) return;
    const file = torrent.files[row];
    try style(out, allocator, if (file.skipped) symbols.file_skip else symbols.file_ok, if (file.skipped) .dim else .green, color);
    try out.append(allocator, ' ');
    try out.appendSlice(allocator, file.path);
    try out.print(allocator, "  {d:.2} GiB", .{file.size_gib});
}

fn renderPeersDetail(out: *std.ArrayList(u8), allocator: std.mem.Allocator, torrent: *const mock_data.Torrent, symbols: Symbols, row: usize, color: bool) !void {
    if (row >= torrent.peers_list.len) return;
    const peer = torrent.peers_list[row];
    try style(out, allocator, symbols.peer, .cyan, color);
    try out.append(allocator, ' ');
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

fn renderModalOverlayRow(out: *std.ArrayList(u8), allocator: std.mem.Allocator, state: *const model.AppState, symbols: Symbols, row: usize, width: usize, modal_w: usize, color: bool) !void {
    if (state.settings_open) return renderSettingsModalOverlayRow(out, allocator, state, symbols, row, width, modal_w, color);

    const left_pad = (width - modal_w) / 2;
    const right_pad = width - modal_w - left_pad;
    const title = if (state.add_torrent_open) "Add torrent" else "Filter torrents";
    const subtitle = if (state.add_torrent_open) "Paste a magnet link, info hash, or .torrent path" else "Match name, tracker, category, or status";
    const help = if (state.add_torrent_open) "Enter adds mock torrent   Esc cancels" else "Enter applies filter   Esc closes   Ctrl-U clears";
    const input_text = if (state.add_torrent_open) state.addTorrentInput() else state.filterQuery();
    const placeholder = if (state.add_torrent_open) "magnet:?xt=urn:btih:..." else "linuxtracker, seeding, #linux...";
    try appendRepeat(out, allocator, ' ', left_pad);
    switch (row) {
        0 => {
            try out.appendSlice(allocator, "╭");
            try appendGlyphRepeat(out, allocator, "─", modal_w - 2);
            try out.appendSlice(allocator, "╮");
        },
        1 => try renderModalLine(out, allocator, title, modal_w, .accent, color),
        2 => try renderModalLine(out, allocator, subtitle, modal_w, .bright, color),
        3 => {
            var input = std.ArrayList(u8).empty;
            defer input.deinit(allocator);
            try style(&input, allocator, "› ", .accent, color);
            try input.appendSlice(allocator, input_text);
            if (input_text.len == 0) {
                try style(&input, allocator, placeholder, .dim, color);
            }
            try renderModalLine(out, allocator, input.items, modal_w, .reset, false);
        },
        4 => try renderModalLine(out, allocator, help, modal_w, .dim, color),
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

fn renderSettingsModalOverlayRow(out: *std.ArrayList(u8), allocator: std.mem.Allocator, state: *const model.AppState, symbols: Symbols, row: usize, width: usize, modal_w: usize, color: bool) !void {
    const left_pad = (width - modal_w) / 2;
    const right_pad = width - modal_w - left_pad;
    try appendRepeat(out, allocator, ' ', left_pad);
    switch (row) {
        0 => {
            try out.appendSlice(allocator, "╭");
            try appendGlyphRepeat(out, allocator, "─", modal_w - 2);
            try out.appendSlice(allocator, "╮");
        },
        1 => {
            var title = std.ArrayList(u8).empty;
            defer title.deinit(allocator);
            try style(&title, allocator, symbols.settings, .accent, color);
            try title.appendSlice(allocator, " Settings");
            try renderModalLine(out, allocator, title.items, modal_w, .reset, false);
        },
        2 => try renderSettingLine(out, allocator, state, model.SettingsItem.symbols, modal_w, color),
        3 => try renderSettingLine(out, allocator, state, model.SettingsItem.theme, modal_w, color),
        4 => try renderModalLine(out, allocator, "j/k select   h/l or space change   Enter closes", modal_w, .dim, color),
        5 => try renderModalLine(out, allocator, "Nerd Font mode uses private-use glyphs; switch back if your terminal lacks them.", modal_w, .dim, color),
        else => {
            try out.appendSlice(allocator, "╰");
            try appendGlyphRepeat(out, allocator, "─", modal_w - 2);
            try out.appendSlice(allocator, "╯");
        },
    }
    try appendRepeat(out, allocator, ' ', right_pad);
    try out.append(allocator, '\n');
}

fn renderSettingLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, state: *const model.AppState, item: model.SettingsItem, modal_w: usize, color: bool) !void {
    var line = std.ArrayList(u8).empty;
    defer line.deinit(allocator);
    const selected = state.selectedSetting() == item;
    try style(&line, allocator, if (selected) "› " else "  ", if (selected) .accent else .dim, color);
    try line.appendSlice(allocator, item.label());
    const label_width = zz.measure.width(line.items);
    if (label_width < 22) try appendRepeat(&line, allocator, ' ', 22 - label_width);
    const value = switch (item) {
        .symbols => state.symbol_set.label(),
        .theme => state.theme.label(),
    };
    try style(&line, allocator, value, if (selected) .green else .bright, color);
    try renderModalLine(out, allocator, line.items, modal_w, .reset, false);
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
    try key(&footer, allocator, ",", "settings", color);
    try key(&footer, allocator, "q", "quit", color);
    try key(&footer, allocator, "space", "pause", color);
    try key(&footer, allocator, "m", "mark", color);
    try key(&footer, allocator, "a", "add", color);
    try key(&footer, allocator, "s/S", "sort", color);
    try key(&footer, allocator, "[/]", "tab", color);
    try key(&footer, allocator, "/", "filter", color);
    try key(&footer, allocator, "d", "remove", color);
    try key(&footer, allocator, "?", "help", color);
    try appendPadded(out, allocator, footer.items, width);
    try out.append(allocator, '\n');
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
