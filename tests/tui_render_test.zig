const std = @import("std");
const tui = @import("varuna_tui");

test "mock TUI render includes lazygit-style panes and selected torrent" {
    var state = tui.model.AppState.init();

    const frame = try tui.render.renderFrame(std.testing.allocator, &state, .{
        .width = 140,
        .height = 38,
        .color = false,
    });
    defer std.testing.allocator.free(frame);

    try std.testing.expect(std.mem.indexOf(u8, frame, "varuna") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "Filters [1]") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "Torrents [2]") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "Detail [3]") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "LibreOffice.25.2.5.Linux.x86-64.tar.gz") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "j/k nav") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "Network") == null);
}

test "mock TUI exposes a ZigZag app model" {
    try std.testing.expect(@hasDecl(tui, "app"));
    try std.testing.expect(@hasDecl(tui.app.Model, "Msg"));
    try std.testing.expect(@hasDecl(tui.app.Model, "init"));
    try std.testing.expect(@hasDecl(tui.app.Model, "update"));
    try std.testing.expect(@hasDecl(tui.app.Model, "view"));
}

test "mock TUI styled view emits ANSI color and Unicode UI characters" {
    var state = tui.model.AppState.init();

    const frame = try tui.render.renderFrame(std.testing.allocator, &state, .{
        .width = 120,
        .height = 36,
        .color = true,
    });
    defer std.testing.allocator.free(frame);

    try std.testing.expect(std.mem.indexOf(u8, frame, "\x1b[") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "┌") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "▶") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "█") != null);
}

test "mock TUI model navigation clamps and pause toggles selected torrent" {
    var state = tui.model.AppState.init();

    try std.testing.expectEqual(@as(usize, 0), state.selected_index);
    state.moveSelection(-10);
    try std.testing.expectEqual(@as(usize, 0), state.selected_index);

    state.moveSelection(2);
    try std.testing.expectEqual(@as(usize, 2), state.selected_index);
    try std.testing.expect(!state.selectedTorrent().paused);

    state.togglePauseSelected();
    try std.testing.expect(state.selectedTorrent().paused);

    state.moveSelection(1000);
    try std.testing.expectEqual(tui.mock_data.torrents.len - 1, state.selected_index);
}

test "add torrent modal accepts text and closes on submit" {
    var state = tui.model.AppState.init();
    state.openAddTorrentModal();
    state.appendAddTorrentText("magnet:?xt=urn:btih:abc123");

    const open_frame = try tui.render.renderFrame(std.testing.allocator, &state, .{
        .width = 120,
        .height = 36,
        .color = false,
    });
    defer std.testing.allocator.free(open_frame);
    try std.testing.expect(std.mem.indexOf(u8, open_frame, "Add torrent") != null);
    try std.testing.expect(std.mem.indexOf(u8, open_frame, "magnet:?xt=urn:btih:abc123") != null);

    state.submitAddTorrentModal();
    try std.testing.expect(!state.add_torrent_open);
    try std.testing.expectEqual(@as(usize, 0), state.add_torrent_input_len);
}

test "marked torrents render with marker and styled highlight" {
    var state = tui.model.AppState.init();
    state.toggleMarkSelected();

    const frame = try tui.render.renderFrame(std.testing.allocator, &state, .{
        .width = 120,
        .height = 36,
        .color = true,
    });
    defer std.testing.allocator.free(frame);

    try std.testing.expect(state.marked[0]);
    try std.testing.expect(std.mem.indexOf(u8, frame, "●DN") != null);
    try std.testing.expect(std.mem.indexOf(u8, frame, "\x1b[") != null);
}

test "active pane movement changes filters and detail tabs" {
    var state = tui.model.AppState.init();

    state.active_pane = .filters;
    state.moveActiveSelection(1);
    try std.testing.expectEqual(tui.model.Filter.downloading, state.selectedFilter());
    state.moveActiveSelection(1);
    try std.testing.expectEqual(tui.model.Filter.seeding, state.selectedFilter());
    try std.testing.expectEqual(tui.mock_data.TorrentStatus.seeding, state.selectedTorrentConst().status);

    state.active_pane = .detail;
    state.moveActiveSelection(1);
    try std.testing.expectEqual(tui.model.DetailTab.peers, state.detail_tab);
}
