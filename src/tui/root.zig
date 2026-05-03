pub const app = @import("app.zig");
pub const mock_data = @import("mock_data.zig");
pub const model = @import("model.zig");
pub const render = @import("render.zig");

test {
    _ = mock_data;
    _ = model;
    _ = render;
}
