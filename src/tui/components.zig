const std = @import("std");
const zz = @import("zigzag");
const model = @import("model.zig");
const mock_data = @import("mock_data.zig");

pub const Style = enum {
    reset,
    dim,
    bright,
    accent,
    blue,
    cyan,
    green,
    yellow,
    orange,
    red,
    marked,
    inverse,
};

pub const Symbols = struct {
    brand: []const u8,
    down: []const u8,
    up: []const u8,
    seed: []const u8,
    pause: []const u8,
    err: []const u8,
    queued: []const u8,
    selected: []const u8,
    marked: []const u8,
    settings: []const u8,
    file_ok: []const u8,
    file_skip: []const u8,
    peer: []const u8,
};

pub fn symbolsFor(set: model.SymbolSet) Symbols {
    return switch (set) {
        .unicode => .{
            .brand = "◆",
            .down = "↓",
            .up = "↑",
            .seed = "✓",
            .pause = "⏸",
            .err = "⚠",
            .queued = "◌",
            .selected = "▶",
            .marked = "●",
            .settings = "⚙",
            .file_ok = "✓",
            .file_skip = "⊘",
            .peer = "☷",
        },
        .nerd_font => .{
            .brand = "\u{f1c0}",
            .down = "\u{f019}",
            .up = "\u{f093}",
            .seed = "\u{f00c}",
            .pause = "\u{f04c}",
            .err = "\u{f071}",
            .queued = "\u{f017}",
            .selected = "\u{f054}",
            .marked = "\u{f111}",
            .settings = "\u{f013}",
            .file_ok = "\u{f00c}",
            .file_skip = "\u{f05e}",
            .peer = "\u{f0c0}",
        },
    };
}

pub fn panelTitle(out: *std.ArrayList(u8), allocator: std.mem.Allocator, title: []const u8, active: bool, color: bool) !void {
    try style(out, allocator, title, if (active) .accent else .bright, color);
}

pub fn filterRow(out: *std.ArrayList(u8), allocator: std.mem.Allocator, label: []const u8, count: usize, active: bool, color: bool) !void {
    if (active) try style(out, allocator, "› ", .accent, color) else try out.appendSlice(allocator, "  ");
    try out.appendSlice(allocator, label);
    try out.print(allocator, " {d}", .{count});
}

pub fn key(out: *std.ArrayList(u8), allocator: std.mem.Allocator, lhs: []const u8, rhs: []const u8, color: bool) !void {
    try style(out, allocator, "‹", .dim, color);
    try style(out, allocator, lhs, .accent, color);
    try style(out, allocator, "› ", .dim, color);
    try style(out, allocator, rhs, .dim, color);
    try out.appendSlice(allocator, "  ");
}

pub fn modalLine(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, width: usize, text_style: Style, color: bool) !void {
    try out.appendSlice(allocator, "│ ");
    var line = std.ArrayList(u8).empty;
    defer line.deinit(allocator);
    try style(&line, allocator, text, text_style, color);
    try appendPadded(out, allocator, line.items, width - 4);
    try out.appendSlice(allocator, " │");
}

pub fn progressBar(out: *std.ArrayList(u8), allocator: std.mem.Allocator, progress: f64, width: usize, status: mock_data.TorrentStatus, color: bool) !void {
    const fill: usize = @intFromFloat(@floor(@max(0, @min(1, progress)) * @as(f64, @floatFromInt(width))));
    try out.appendSlice(allocator, "▕");
    try appendStyledGlyphRepeat(out, allocator, "▰", fill, statusStyle(status), color);
    try appendStyledGlyphRepeat(out, allocator, "▱", width - fill, .dim, color);
    try out.appendSlice(allocator, "▏");
}

pub fn miniProgress(out: *std.ArrayList(u8), allocator: std.mem.Allocator, progress: f64, width: usize, status: mock_data.TorrentStatus, color: bool) !void {
    if (width < 8) {
        try appendPercent(out, allocator, progress, width);
        return;
    }

    const bar_w = width - 5;
    const fill: usize = @intFromFloat(@floor(@max(0, @min(1, progress)) * @as(f64, @floatFromInt(bar_w))));
    try appendStyledGlyphRepeat(out, allocator, "▰", fill, statusStyle(status), color);
    try appendStyledGlyphRepeat(out, allocator, "▱", bar_w - fill, .dim, color);
    try out.append(allocator, ' ');
    try appendPercent(out, allocator, progress, 4);
}

pub fn statusGlyph(torrent: *const mock_data.Torrent, symbols: Symbols) []const u8 {
    if (torrent.paused) return symbols.pause;
    return switch (torrent.status) {
        .downloading => symbols.down,
        .seeding => symbols.seed,
        .paused => symbols.pause,
        .errored => symbols.err,
        .queued => symbols.queued,
    };
}

pub fn statusStyle(status: mock_data.TorrentStatus) Style {
    return switch (status) {
        .downloading => .blue,
        .seeding => .green,
        .paused => .yellow,
        .errored => .red,
        .queued => .dim,
    };
}

pub fn style(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, s: Style, enabled: bool) !void {
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
        .dim => (zz.Style{}).fg(zz.Color.fromRgb(108, 112, 134)).dim(true),
        .bright => (zz.Style{}).fg(zz.Color.fromRgb(205, 214, 244)).bold(true),
        .accent => (zz.Style{}).fg(zz.Color.fromRgb(203, 166, 247)).bold(true),
        .blue => (zz.Style{}).fg(zz.Color.fromRgb(137, 180, 250)).bold(true),
        .cyan => (zz.Style{}).fg(zz.Color.fromRgb(148, 226, 213)).bold(true),
        .green => (zz.Style{}).fg(zz.Color.fromRgb(166, 227, 161)).bold(true),
        .yellow => (zz.Style{}).fg(zz.Color.fromRgb(249, 226, 175)).bold(true),
        .orange => (zz.Style{}).fg(zz.Color.fromRgb(250, 179, 135)).bold(true),
        .red => (zz.Style{}).fg(zz.Color.fromRgb(243, 139, 168)).bold(true),
        .marked => (zz.Style{}).fg(zz.Color.fromRgb(249, 226, 175)).bold(true),
        .inverse => (zz.Style{}).fg(zz.Color.fromRgb(205, 214, 244)).bg(zz.Color.fromRgb(69, 71, 90)).bold(true),
    };
}

pub fn appendRate(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: f64, width: usize) !void {
    var buf: [32]u8 = undefined;
    const text = if (value <= 0.05) "–" else std.fmt.bufPrint(&buf, "{d:.1}M", .{value}) catch "–";
    try appendLeftPad(out, allocator, text, width);
}

pub fn appendPercent(out: *std.ArrayList(u8), allocator: std.mem.Allocator, value: f64, width: usize) !void {
    var buf: [16]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:.0}%", .{@max(0, @min(100, value * 100.0))}) catch "–";
    try appendLeftPad(out, allocator, text, width);
}

pub fn appendPeers(out: *std.ArrayList(u8), allocator: std.mem.Allocator, seeds: u32, peers: u32, width: usize) !void {
    var buf: [32]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d}/{d}", .{ seeds, peers }) catch "–";
    try appendLeftPad(out, allocator, text, width);
}

pub fn appendPadded(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, width: usize) !void {
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

pub fn appendLeftPad(out: *std.ArrayList(u8), allocator: std.mem.Allocator, text: []const u8, width: usize) !void {
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

pub fn appendRepeat(out: *std.ArrayList(u8), allocator: std.mem.Allocator, ch: u8, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try out.append(allocator, ch);
}

pub fn appendGlyphRepeat(out: *std.ArrayList(u8), allocator: std.mem.Allocator, glyph: []const u8, count: usize) !void {
    var i: usize = 0;
    while (i < count) : (i += 1) try out.appendSlice(allocator, glyph);
}

fn appendStyledGlyphRepeat(out: *std.ArrayList(u8), allocator: std.mem.Allocator, glyph: []const u8, count: usize, s: Style, color: bool) !void {
    if (count == 0) return;
    var segment = std.ArrayList(u8).empty;
    defer segment.deinit(allocator);
    try appendGlyphRepeat(&segment, allocator, glyph, count);
    try style(out, allocator, segment.items, s, color);
}

pub fn appendHRule(out: *std.ArrayList(u8), allocator: std.mem.Allocator, width: usize) !void {
    try appendGlyphRepeat(out, allocator, "─", width);
    try out.append(allocator, '\n');
}

pub const PanelRule = enum { top, bottom };

pub fn appendPanelRule(out: *std.ArrayList(u8), allocator: std.mem.Allocator, left_w: usize, center_w: usize, right_w: usize, rule: PanelRule) !void {
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

pub fn appendBoxRule(out: *std.ArrayList(u8), allocator: std.mem.Allocator, width: usize) !void {
    try out.appendSlice(allocator, "┌");
    try appendGlyphRepeat(out, allocator, "─", width - 2);
    try out.appendSlice(allocator, "┐\n");
}
