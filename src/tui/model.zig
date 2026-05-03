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

pub const SortKey = enum {
    queue,
    name,
    progress,
    down,
    up,
    peers,
    ratio,
    status,

    pub fn label(self: SortKey) []const u8 {
        return switch (self) {
            .queue => "queue",
            .name => "name",
            .progress => "progress",
            .down => "down",
            .up => "up",
            .peers => "peers",
            .ratio => "ratio",
            .status => "status",
        };
    }

    pub fn next(self: SortKey) SortKey {
        return switch (self) {
            .queue => .name,
            .name => .progress,
            .progress => .down,
            .down => .up,
            .up => .peers,
            .peers => .ratio,
            .ratio => .status,
            .status => .queue,
        };
    }
};

pub const SortDirection = enum {
    asc,
    desc,

    pub fn toggle(self: SortDirection) SortDirection {
        return switch (self) {
            .asc => .desc,
            .desc => .asc,
        };
    }

    pub fn symbol(self: SortDirection) []const u8 {
        return switch (self) {
            .asc => "↑",
            .desc => "↓",
        };
    }
};

pub const SymbolSet = enum {
    unicode,
    nerd_font,

    pub fn label(self: SymbolSet) []const u8 {
        return switch (self) {
            .unicode => "Unicode",
            .nerd_font => "Nerd Font",
        };
    }

    pub fn next(self: SymbolSet) SymbolSet {
        return switch (self) {
            .unicode => .nerd_font,
            .nerd_font => .unicode,
        };
    }
};

pub const Theme = enum {
    btop_dark,

    pub fn label(self: Theme) []const u8 {
        return switch (self) {
            .btop_dark => "btop dark",
        };
    }
};

pub const SettingsItem = enum {
    symbols,
    theme,

    pub const values = [_]SettingsItem{ .symbols, .theme };

    pub fn label(self: SettingsItem) []const u8 {
        return switch (self) {
            .symbols => "Symbol set",
            .theme => "Theme",
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
    detail_selected_row: usize = 0,
    torrent_scroll_offset: usize = 0,
    detail_scroll_offset: usize = 0,
    sort_key: SortKey = .queue,
    sort_direction: SortDirection = .asc,
    symbol_set: SymbolSet = .unicode,
    theme: Theme = .btop_dark,
    settings_open: bool = false,
    settings_index: usize = 0,
    filter_query: [128]u8 = undefined,
    filter_query_len: usize = 0,
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
        const count = self.visibleTorrentCount();
        if (count == 0) return;
        const current = self.visiblePositionOf(self.selected_index) orelse 0;
        const target = addClamped(current, delta, count - 1);
        self.selected_index = self.visibleTorrentIndexAt(target) orelse self.selected_index;
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
        self.torrent_scroll_offset = 0;
    }

    pub fn moveDetailSelection(self: *AppState, delta: isize) void {
        const count = self.detailItemCount();
        if (count == 0) {
            self.detail_selected_row = 0;
            self.detail_scroll_offset = 0;
            return;
        }
        self.detail_selected_row = addClamped(@min(self.detail_selected_row, count - 1), delta, count - 1);
    }

    pub fn nextPane(self: *AppState) void {
        self.active_pane = self.active_pane.next();
    }

    pub fn prevPane(self: *AppState) void {
        self.active_pane = self.active_pane.prev();
    }

    pub fn nextDetailTab(self: *AppState) void {
        self.detail_tab = self.detail_tab.next();
        self.resetDetailScroll();
    }

    pub fn prevDetailTab(self: *AppState) void {
        self.detail_tab = self.detail_tab.prev();
        self.resetDetailScroll();
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
        var indexes: [mock_data.initial_torrents.len]usize = undefined;
        const count = self.sortedVisibleIndexes(&indexes);
        if (visible_row >= count) return null;
        return indexes[visible_row];
    }

    pub fn visibleTorrentCount(self: *const AppState) usize {
        var count: usize = 0;
        for (self.torrents, 0..) |_, i| {
            if (self.torrentMatchesVisibleFilters(i)) count += 1;
        }
        return count;
    }

    pub fn ensureTorrentVisible(self: *AppState, view_rows: usize) void {
        self.torrent_scroll_offset = self.effectiveTorrentScrollOffset(view_rows);
    }

    pub fn effectiveTorrentScrollOffset(self: *const AppState, view_rows: usize) usize {
        if (view_rows == 0) return 0;
        const count = self.visibleTorrentCount();
        if (count <= view_rows) return 0;

        const offset = @min(self.torrent_scroll_offset, count - view_rows);
        const selected_position = self.visiblePositionOf(self.visibleSelectedIndex()) orelse 0;
        if (selected_position < offset) return selected_position;
        if (selected_position >= offset + view_rows) return selected_position - view_rows + 1;
        return offset;
    }

    pub fn detailItemCount(self: *const AppState) usize {
        const torrent = self.selectedTorrentConst();
        return switch (self.detail_tab) {
            .files => torrent.files.len,
            .peers => torrent.peers_list.len,
            .trackers => 3,
            .info => 5,
        };
    }

    pub fn ensureDetailVisible(self: *AppState, view_rows: usize) void {
        self.detail_scroll_offset = self.effectiveDetailScrollOffset(view_rows);
    }

    pub fn effectiveDetailScrollOffset(self: *const AppState, view_rows: usize) usize {
        if (view_rows == 0) return 0;
        const count = self.detailItemCount();
        if (count <= view_rows) return 0;

        const offset = @min(self.detail_scroll_offset, count - view_rows);
        const selected_row = @min(self.detail_selected_row, count - 1);
        if (selected_row < offset) return selected_row;
        if (selected_row >= offset + view_rows) return selected_row - view_rows + 1;
        return offset;
    }

    pub fn selectFirstVisible(self: *AppState) void {
        if (self.visibleTorrentIndexAt(0)) |idx| self.selected_index = idx;
        self.torrent_scroll_offset = 0;
    }

    pub fn selectLastVisible(self: *AppState) void {
        const count = self.visibleTorrentCount();
        if (count == 0) return;
        if (self.visibleTorrentIndexAt(count - 1)) |idx| self.selected_index = idx;
    }

    pub fn setSort(self: *AppState, key: SortKey, direction: SortDirection) void {
        self.sort_key = key;
        self.sort_direction = direction;
        self.ensureSelectedVisible();
    }

    pub fn cycleSortKey(self: *AppState) void {
        self.setSort(self.sort_key.next(), self.sort_direction);
    }

    pub fn toggleSortDirection(self: *AppState) void {
        self.setSort(self.sort_key, self.sort_direction.toggle());
    }

    pub fn openSettingsModal(self: *AppState) void {
        self.settings_open = true;
        self.settings_index = 0;
    }

    pub fn closeSettingsModal(self: *AppState) void {
        self.settings_open = false;
    }

    pub fn selectedSetting(self: *const AppState) SettingsItem {
        return SettingsItem.values[self.settings_index];
    }

    pub fn moveSettingsSelection(self: *AppState, delta: isize) void {
        if (delta < 0) {
            self.settings_index -|= @as(usize, @intCast(-delta));
        } else {
            self.settings_index = @min(SettingsItem.values.len - 1, self.settings_index + @as(usize, @intCast(delta)));
        }
    }

    pub fn toggleSelectedSetting(self: *AppState) void {
        switch (self.selectedSetting()) {
            .symbols => self.symbol_set = self.symbol_set.next(),
            .theme => self.theme = .btop_dark,
        }
    }

    pub fn filterQuery(self: *const AppState) []const u8 {
        return self.filter_query[0..self.filter_query_len];
    }

    pub fn openFilterModal(self: *AppState) void {
        self.filter_open = true;
    }

    pub fn closeFilterModal(self: *AppState) void {
        self.filter_open = false;
        self.ensureSelectedVisible();
    }

    pub fn setFilterQuery(self: *AppState, text: []const u8) void {
        self.filter_query_len = 0;
        self.appendFilterText(text);
        self.ensureSelectedVisible();
        self.torrent_scroll_offset = 0;
    }

    pub fn appendFilterText(self: *AppState, text: []const u8) void {
        const available = self.filter_query.len - self.filter_query_len;
        const n = @min(available, text.len);
        @memcpy(self.filter_query[self.filter_query_len..][0..n], text[0..n]);
        self.filter_query_len += n;
        self.ensureSelectedVisible();
    }

    pub fn appendFilterChar(self: *AppState, ch: u21) void {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(ch, &buf) catch return;
        self.appendFilterText(buf[0..len]);
    }

    pub fn backspaceFilterQuery(self: *AppState) void {
        if (self.filter_query_len == 0) return;
        self.filter_query_len -= 1;
        while (self.filter_query_len > 0 and (self.filter_query[self.filter_query_len] & 0xc0) == 0x80) {
            self.filter_query_len -= 1;
        }
        self.ensureSelectedVisible();
    }

    pub fn clearFilterQuery(self: *AppState) void {
        self.filter_query_len = 0;
        self.ensureSelectedVisible();
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

    pub fn torrentMatchesVisibleFilters(self: *const AppState, index: usize) bool {
        const torrent = self.torrents[index];
        if (!self.selectedFilter().matches(torrent)) return false;
        const query = self.filterQuery();
        if (query.len == 0) return true;
        return containsAsciiIgnoreCase(torrent.name, query) or
            containsAsciiIgnoreCase(torrent.tracker, query) or
            containsAsciiIgnoreCase(torrent.category, query) or
            containsAsciiIgnoreCase(torrent.status.label(), query);
    }

    fn ensureSelectedVisible(self: *AppState) void {
        if (self.torrentMatchesVisibleFilters(self.selected_index)) return;
        if (self.firstVisibleTorrentIndex()) |idx| self.selected_index = idx;
        self.resetDetailScroll();
    }

    fn visibleSelectedIndex(self: *const AppState) usize {
        if (self.torrentMatchesVisibleFilters(self.selected_index)) return self.selected_index;
        return self.firstVisibleTorrentIndex() orelse self.selected_index;
    }

    fn firstVisibleTorrentIndex(self: *const AppState) ?usize {
        return self.visibleTorrentIndexAt(0);
    }

    fn previousVisibleTorrentIndex(self: *const AppState, from: usize) ?usize {
        const position = self.visiblePositionOf(from) orelse return self.firstVisibleTorrentIndex();
        if (position == 0) return null;
        return self.visibleTorrentIndexAt(position - 1);
    }

    fn nextVisibleTorrentIndex(self: *const AppState, from: usize) ?usize {
        const position = self.visiblePositionOf(from) orelse return self.firstVisibleTorrentIndex();
        return self.visibleTorrentIndexAt(position + 1);
    }

    fn resetDetailScroll(self: *AppState) void {
        self.detail_selected_row = 0;
        self.detail_scroll_offset = 0;
    }

    fn visiblePositionOf(self: *const AppState, torrent_index: usize) ?usize {
        var indexes: [mock_data.initial_torrents.len]usize = undefined;
        const count = self.sortedVisibleIndexes(&indexes);
        for (indexes[0..count], 0..) |idx, position| {
            if (idx == torrent_index) return position;
        }
        return null;
    }

    fn sortedVisibleIndexes(self: *const AppState, out: *[mock_data.initial_torrents.len]usize) usize {
        var count: usize = 0;
        for (self.torrents, 0..) |_, idx| {
            if (!self.torrentMatchesVisibleFilters(idx)) continue;
            out[count] = idx;
            count += 1;
        }

        var i: usize = 1;
        while (i < count) : (i += 1) {
            const value = out[i];
            var j = i;
            while (j > 0 and self.lessTorrentIndex(value, out[j - 1])) : (j -= 1) {
                out[j] = out[j - 1];
            }
            out[j] = value;
        }
        return count;
    }

    fn lessTorrentIndex(self: *const AppState, left: usize, right: usize) bool {
        const cmp = self.compareTorrentIndex(left, right);
        if (cmp == 0) return left < right;
        return switch (self.sort_direction) {
            .asc => cmp < 0,
            .desc => cmp > 0,
        };
    }

    fn compareTorrentIndex(self: *const AppState, left: usize, right: usize) i8 {
        const a = self.torrents[left];
        const b = self.torrents[right];
        return switch (self.sort_key) {
            .queue => compareUsize(left, right),
            .name => compareAsciiIgnoreCase(a.name, b.name),
            .progress => compareFloat(a.progress, b.progress),
            .down => compareFloat(a.down_mib, b.down_mib),
            .up => compareFloat(a.up_mib, b.up_mib),
            .peers => compareU32(@as(u32, a.seeds) + @as(u32, a.peers), @as(u32, b.seeds) + @as(u32, b.peers)),
            .ratio => compareFloat(a.ratio, b.ratio),
            .status => compareAsciiIgnoreCase(a.status.label(), b.status.label()),
        };
    }
};

fn addClamped(value: usize, delta: isize, max_value: usize) usize {
    if (delta < 0) return value -| @as(usize, @intCast(-delta));
    return @min(max_value, value + @as(usize, @intCast(delta)));
}

fn compareUsize(left: usize, right: usize) i8 {
    if (left < right) return -1;
    if (left > right) return 1;
    return 0;
}

fn compareU32(left: u32, right: u32) i8 {
    if (left < right) return -1;
    if (left > right) return 1;
    return 0;
}

fn compareFloat(left: f64, right: f64) i8 {
    if (left < right) return -1;
    if (left > right) return 1;
    return 0;
}

fn compareAsciiIgnoreCase(left: []const u8, right: []const u8) i8 {
    const n = @min(left.len, right.len);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const a = std.ascii.toLower(left[i]);
        const b = std.ascii.toLower(right[i]);
        if (a < b) return -1;
        if (a > b) return 1;
    }
    return compareUsize(left.len, right.len);
}

fn containsAsciiIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;

    var start: usize = 0;
    while (start + needle.len <= haystack.len) : (start += 1) {
        var i: usize = 0;
        while (i < needle.len) : (i += 1) {
            if (std.ascii.toLower(haystack[start + i]) != std.ascii.toLower(needle[i])) break;
        }
        if (i == needle.len) return true;
    }
    return false;
}

pub fn handleKey(state: *AppState, input: []const u8) bool {
    if (input.len == 0) return true;
    if (std.mem.eql(u8, input, "\x1b[A")) {
        if (state.settings_open) state.moveSettingsSelection(-1) else state.moveActiveSelection(-1);
        return true;
    }
    if (std.mem.eql(u8, input, "\x1b[B")) {
        if (state.settings_open) state.moveSettingsSelection(1) else state.moveActiveSelection(1);
        return true;
    }
    if (std.mem.eql(u8, input, "\x1b[C")) {
        if (state.settings_open) state.toggleSelectedSetting() else state.nextPane();
        return true;
    }
    if (std.mem.eql(u8, input, "\x1b[D")) {
        if (state.settings_open) state.toggleSelectedSetting() else state.prevPane();
        return true;
    }

    for (input) |ch| {
        if (state.settings_open) {
            switch (ch) {
                13, 27, 'q', ',' => state.closeSettingsModal(),
                'j' => state.moveSettingsSelection(1),
                'k' => state.moveSettingsSelection(-1),
                'h', 'l', ' ' => state.toggleSelectedSetting(),
                else => {},
            }
            continue;
        }
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
                13, 27 => state.closeFilterModal(),
                8, 127 => state.backspaceFilterQuery(),
                21 => state.clearFilterQuery(),
                else => if (ch >= 32 and ch < 127) {
                    const one = [_]u8{ch};
                    state.appendFilterText(one[0..]);
                },
            }
            continue;
        }

        switch (ch) {
            'q' => return false,
            'j' => state.moveActiveSelection(1),
            'k' => state.moveActiveSelection(-1),
            'g' => state.selectFirstVisible(),
            'G' => state.selectLastVisible(),
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
            ',' => state.openSettingsModal(),
            '/' => state.openFilterModal(),
            's' => state.cycleSortKey(),
            'S' => state.toggleSortDirection(),
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
