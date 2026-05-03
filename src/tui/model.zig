const std = @import("std");
const mock_data = @import("mock_data.zig");

pub const Pane = enum {
    filters,
    torrents,
    detail,

    pub fn next(self: Pane) Pane {
        return switch (self) {
            .filters => .torrents,
            .torrents => .detail,
            .detail => .filters,
        };
    }

    pub fn prev(self: Pane) Pane {
        return switch (self) {
            .filters => .detail,
            .torrents => .filters,
            .detail => .torrents,
        };
    }
};

pub const DetailTab = enum {
    files,
    peers,
    trackers,
    info,

    pub fn next(self: DetailTab) DetailTab {
        return switch (self) {
            .files => .peers,
            .peers => .trackers,
            .trackers => .info,
            .info => .files,
        };
    }

    pub fn prev(self: DetailTab) DetailTab {
        return switch (self) {
            .files => .info,
            .peers => .files,
            .trackers => .peers,
            .info => .trackers,
        };
    }

    pub fn label(self: DetailTab) []const u8 {
        return switch (self) {
            .files => "Files",
            .peers => "Peers",
            .trackers => "Trackers",
            .info => "Info",
        };
    }
};

pub const Filter = enum {
    all,
    downloading,
    seeding,
    paused,
    errored,

    pub const values = [_]Filter{ .all, .downloading, .seeding, .paused, .errored };

    pub fn label(self: Filter) []const u8 {
        return switch (self) {
            .all => "All",
            .downloading => "Downloading",
            .seeding => "Seeding",
            .paused => "Paused",
            .errored => "Errored",
        };
    }

    pub fn matches(self: Filter, torrent: mock_data.Torrent) bool {
        return switch (self) {
            .all => true,
            .downloading => torrent.status == .downloading and !torrent.paused,
            .seeding => torrent.status == .seeding,
            .paused => torrent.paused or torrent.status == .paused,
            .errored => torrent.status == .errored,
        };
    }
};

pub const AppState = struct {
    torrents: [mock_data.initial_torrents.len]mock_data.Torrent,
    marked: [mock_data.initial_torrents.len]bool = [_]bool{false} ** mock_data.initial_torrents.len,
    selected_index: usize = 0,
    filter_index: usize = 0,
    active_pane: Pane = .torrents,
    detail_tab: DetailTab = .files,
    show_help: bool = false,
    show_remove_confirm: bool = false,
    filter_open: bool = false,
    add_torrent_open: bool = false,
    add_torrent_input: [512]u8 = undefined,
    add_torrent_input_len: usize = 0,
    tick_count: u64 = 0,

    pub fn init() AppState {
        return .{ .torrents = mock_data.initial_torrents };
    }

    pub fn selectedTorrent(self: *AppState) *mock_data.Torrent {
        self.ensureSelectedVisible();
        return &self.torrents[self.selected_index];
    }

    pub fn selectedTorrentConst(self: *const AppState) *const mock_data.Torrent {
        return &self.torrents[self.visibleSelectedIndex()];
    }

    pub fn moveSelection(self: *AppState, delta: isize) void {
        self.ensureSelectedVisible();
        if (delta < 0) {
            var steps: usize = @intCast(-delta);
            while (steps > 0) : (steps -= 1) {
                self.selected_index = self.previousVisibleTorrentIndex(self.selected_index) orelse self.selected_index;
            }
        } else {
            var steps: usize = @intCast(delta);
            while (steps > 0) : (steps -= 1) {
                self.selected_index = self.nextVisibleTorrentIndex(self.selected_index) orelse self.selected_index;
            }
        }
    }

    pub fn moveActiveSelection(self: *AppState, delta: isize) void {
        switch (self.active_pane) {
            .filters => self.moveFilterSelection(delta),
            .torrents => self.moveSelection(delta),
            .detail => self.moveDetailSelection(delta),
        }
    }

    pub fn selectedFilter(self: *const AppState) Filter {
        return Filter.values[self.filter_index];
    }

    pub fn moveFilterSelection(self: *AppState, delta: isize) void {
        if (delta < 0) {
            self.filter_index -|= @as(usize, @intCast(-delta));
        } else {
            self.filter_index = @min(Filter.values.len - 1, self.filter_index + @as(usize, @intCast(delta)));
        }
        self.ensureSelectedVisible();
    }

    pub fn moveDetailSelection(self: *AppState, delta: isize) void {
        if (delta < 0) {
            var steps: usize = @intCast(-delta);
            while (steps > 0) : (steps -= 1) self.prevDetailTab();
        } else {
            var steps: usize = @intCast(delta);
            while (steps > 0) : (steps -= 1) self.nextDetailTab();
        }
    }

    pub fn nextPane(self: *AppState) void {
        self.active_pane = self.active_pane.next();
    }

    pub fn prevPane(self: *AppState) void {
        self.active_pane = self.active_pane.prev();
    }

    pub fn nextDetailTab(self: *AppState) void {
        self.detail_tab = self.detail_tab.next();
    }

    pub fn prevDetailTab(self: *AppState) void {
        self.detail_tab = self.detail_tab.prev();
    }

    pub fn togglePauseSelected(self: *AppState) void {
        const torrent = self.selectedTorrent();
        torrent.paused = !torrent.paused;
        torrent.status = if (torrent.paused) .paused else .downloading;
        if (torrent.paused) {
            torrent.down_mib = 0;
            torrent.up_mib = 0;
        }
        self.ensureSelectedVisible();
    }

    pub fn toggleMarkSelected(self: *AppState) void {
        self.ensureSelectedVisible();
        self.marked[self.selected_index] = !self.marked[self.selected_index];
    }

    pub fn visibleTorrentIndexAt(self: *const AppState, visible_row: usize) ?usize {
        var visible: usize = 0;
        for (self.torrents, 0..) |torrent, i| {
            if (!self.selectedFilter().matches(torrent)) continue;
            if (visible == visible_row) return i;
            visible += 1;
        }
        return null;
    }

    pub fn visibleTorrentCount(self: *const AppState) usize {
        var count: usize = 0;
        for (self.torrents) |torrent| {
            if (self.selectedFilter().matches(torrent)) count += 1;
        }
        return count;
    }

    pub fn openAddTorrentModal(self: *AppState) void {
        self.add_torrent_open = true;
        self.add_torrent_input_len = 0;
    }

    pub fn closeAddTorrentModal(self: *AppState) void {
        self.add_torrent_open = false;
        self.add_torrent_input_len = 0;
    }

    pub fn submitAddTorrentModal(self: *AppState) void {
        self.closeAddTorrentModal();
    }

    pub fn appendAddTorrentText(self: *AppState, text: []const u8) void {
        const available = self.add_torrent_input.len - self.add_torrent_input_len;
        const n = @min(available, text.len);
        @memcpy(self.add_torrent_input[self.add_torrent_input_len..][0..n], text[0..n]);
        self.add_torrent_input_len += n;
    }

    pub fn appendAddTorrentChar(self: *AppState, ch: u21) void {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(ch, &buf) catch return;
        self.appendAddTorrentText(buf[0..len]);
    }

    pub fn backspaceAddTorrentText(self: *AppState) void {
        if (self.add_torrent_input_len == 0) return;
        self.add_torrent_input_len -= 1;
        while (self.add_torrent_input_len > 0 and (self.add_torrent_input[self.add_torrent_input_len] & 0xc0) == 0x80) {
            self.add_torrent_input_len -= 1;
        }
    }

    pub fn addTorrentInput(self: *const AppState) []const u8 {
        return self.add_torrent_input[0..self.add_torrent_input_len];
    }

    pub fn advanceMockStats(self: *AppState) void {
        self.tick_count +%= 1;
        for (&self.torrents, 0..) |*torrent, i| {
            if (torrent.paused or torrent.status == .seeding or torrent.status == .errored) continue;
            const wave = @as(f64, @floatFromInt((self.tick_count + i * 3) % 11)) - 5.0;
            torrent.down_mib = @max(0.2, @min(8.5, torrent.down_mib + wave * 0.02));
            torrent.up_mib = @max(0.1, @min(1.8, torrent.up_mib + wave * 0.01));
            torrent.progress = @min(0.999, torrent.progress + 0.0005);
        }
    }

    fn ensureSelectedVisible(self: *AppState) void {
        if (self.selectedFilter().matches(self.torrents[self.selected_index])) return;
        if (self.firstVisibleTorrentIndex()) |idx| self.selected_index = idx;
    }

    fn visibleSelectedIndex(self: *const AppState) usize {
        if (self.selectedFilter().matches(self.torrents[self.selected_index])) return self.selected_index;
        return self.firstVisibleTorrentIndex() orelse self.selected_index;
    }

    fn firstVisibleTorrentIndex(self: *const AppState) ?usize {
        for (self.torrents, 0..) |torrent, i| {
            if (self.selectedFilter().matches(torrent)) return i;
        }
        return null;
    }

    fn previousVisibleTorrentIndex(self: *const AppState, from: usize) ?usize {
        if (from == 0) return null;
        var i = from;
        while (i > 0) {
            i -= 1;
            if (self.selectedFilter().matches(self.torrents[i])) return i;
        }
        return null;
    }

    fn nextVisibleTorrentIndex(self: *const AppState, from: usize) ?usize {
        var i = from + 1;
        while (i < self.torrents.len) : (i += 1) {
            if (self.selectedFilter().matches(self.torrents[i])) return i;
        }
        return null;
    }
};

pub fn handleKey(state: *AppState, input: []const u8) bool {
    if (input.len == 0) return true;
    if (std.mem.eql(u8, input, "\x1b[A")) {
        state.moveActiveSelection(-1);
        return true;
    }
    if (std.mem.eql(u8, input, "\x1b[B")) {
        state.moveActiveSelection(1);
        return true;
    }
    if (std.mem.eql(u8, input, "\x1b[C")) {
        state.nextPane();
        return true;
    }
    if (std.mem.eql(u8, input, "\x1b[D")) {
        state.prevPane();
        return true;
    }

    for (input) |ch| {
        if (state.add_torrent_open) {
            switch (ch) {
                13 => state.submitAddTorrentModal(),
                27 => state.closeAddTorrentModal(),
                8, 127 => state.backspaceAddTorrentText(),
                else => if (ch >= 32 and ch < 127) {
                    const one = [_]u8{ch};
                    state.appendAddTorrentText(one[0..]);
                },
            }
            continue;
        }
        if (state.show_remove_confirm) {
            switch (ch) {
                'y', 'Y', 'd', 'D', 13 => state.show_remove_confirm = false,
                27, 'n', 'N', 'q' => state.show_remove_confirm = false,
                else => {},
            }
            continue;
        }
        if (state.filter_open) {
            switch (ch) {
                27, 13, 'q' => state.filter_open = false,
                else => {},
            }
            continue;
        }

        switch (ch) {
            'q' => return false,
            'j' => state.moveActiveSelection(1),
            'k' => state.moveActiveSelection(-1),
            'g' => state.selected_index = 0,
            'G' => state.selected_index = state.torrents.len - 1,
            'h' => state.prevPane(),
            'l' => state.nextPane(),
            '1' => state.active_pane = .filters,
            '2' => state.active_pane = .torrents,
            '3' => state.active_pane = .detail,
            '[' => state.prevDetailTab(),
            ']' => state.nextDetailTab(),
            ' ' => state.togglePauseSelected(),
            'a' => state.openAddTorrentModal(),
            'm' => state.toggleMarkSelected(),
            '?' => state.show_help = !state.show_help,
            '/' => state.filter_open = true,
            'd' => state.show_remove_confirm = true,
            27 => state.show_help = false,
            else => {},
        }
    }
    return true;
}

test "pane navigation cycles" {
    var state = AppState.init();
    try std.testing.expectEqual(Pane.torrents, state.active_pane);
    state.nextPane();
    try std.testing.expectEqual(Pane.detail, state.active_pane);
    state.nextPane();
    try std.testing.expectEqual(Pane.filters, state.active_pane);
    state.prevPane();
    try std.testing.expectEqual(Pane.detail, state.active_pane);
}
