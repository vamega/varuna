const std = @import("std");
const zz = @import("zigzag");

const model_mod = @import("model.zig");
const render = @import("render.zig");

pub const Model = struct {
    state: model_mod.AppState = undefined,

    pub const Msg = union(enum) {
        key: zz.msg.Key,
        tick: zz.msg.Tick,
        window_size: zz.msg.WindowSize,
    };

    pub fn init(self: *Model, _: *zz.Context) zz.Cmd(Msg) {
        self.* = .{ .state = model_mod.AppState.init() };
        return .{ .every = 250 * std.time.ns_per_ms };
    }

    pub fn update(self: *Model, msg: Msg, _: *zz.Context) zz.Cmd(Msg) {
        switch (msg) {
            .key => |key| return self.handleKey(key),
            .tick => self.state.advanceMockStats(),
            .window_size => {},
        }
        return .none;
    }

    pub fn view(self: *const Model, ctx: *const zz.Context) []const u8 {
        const width = if (ctx.width > 1) ctx.width - 1 else ctx.width;
        const height = if (ctx.height > 1) ctx.height - 1 else ctx.height;
        return render.renderFrame(ctx.allocator, &self.state, .{
            .width = width,
            .height = height,
            .color = true,
        }) catch "render error";
    }

    fn handleKey(self: *Model, key: zz.msg.Key) zz.Cmd(Msg) {
        if (self.state.add_torrent_open) {
            return self.handleAddTorrentKey(key);
        }
        if (self.state.filter_open) {
            return self.handleFilterKey(key);
        }

        switch (key.key) {
            .char => |ch| switch (ch) {
                'q' => return .quit,
                'j' => self.state.moveActiveSelection(1),
                'k' => self.state.moveActiveSelection(-1),
                'g' => self.state.selectFirstVisible(),
                'G' => self.state.selectLastVisible(),
                'h' => self.state.prevPane(),
                'l' => self.state.nextPane(),
                '1' => self.state.active_pane = .filters,
                '2' => self.state.active_pane = .torrents,
                '3' => self.state.active_pane = .detail,
                '[' => self.state.prevDetailTab(),
                ']' => self.state.nextDetailTab(),
                '?' => self.state.show_help = !self.state.show_help,
                '/' => self.state.openFilterModal(),
                'd' => self.state.show_remove_confirm = true,
                'a' => self.state.openAddTorrentModal(),
                'm' => self.state.toggleMarkSelected(),
                's' => self.state.cycleSortKey(),
                'S' => self.state.toggleSortDirection(),
                else => {},
            },
            .space => self.state.togglePauseSelected(),
            .up => self.state.moveActiveSelection(-1),
            .down => self.state.moveActiveSelection(1),
            .left => self.state.prevPane(),
            .right => self.state.nextPane(),
            .home => self.state.selectFirstVisible(),
            .end => self.state.selectLastVisible(),
            .escape => {
                self.state.show_help = false;
                self.state.show_remove_confirm = false;
                self.state.closeFilterModal();
            },
            else => {},
        }
        return .none;
    }

    fn handleAddTorrentKey(self: *Model, key: zz.msg.Key) zz.Cmd(Msg) {
        switch (key.key) {
            .enter => self.state.submitAddTorrentModal(),
            .escape => self.state.closeAddTorrentModal(),
            .backspace => self.state.backspaceAddTorrentText(),
            .space => self.state.appendAddTorrentChar(' '),
            .char => |ch| if (!key.modifiers.ctrl and !key.modifiers.alt) self.state.appendAddTorrentChar(ch),
            else => {},
        }
        return .none;
    }

    fn handleFilterKey(self: *Model, key: zz.msg.Key) zz.Cmd(Msg) {
        switch (key.key) {
            .enter => self.state.closeFilterModal(),
            .escape => self.state.closeFilterModal(),
            .backspace => self.state.backspaceFilterQuery(),
            .space => self.state.appendFilterChar(' '),
            .char => |ch| {
                if (key.modifiers.ctrl and ch == 'u') {
                    self.state.clearFilterQuery();
                } else if (!key.modifiers.ctrl and !key.modifiers.alt) {
                    self.state.appendFilterChar(ch);
                }
            },
            else => {},
        }
        return .none;
    }
};

pub const Program = zz.Program(Model);

pub fn run(allocator: std.mem.Allocator) !void {
    var program = try Program.initWithOptions(allocator, .{
        .fps = 12,
        .title = "varuna-tui",
    });
    defer program.deinit();
    try program.run();
}
