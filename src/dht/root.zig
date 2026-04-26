pub const bootstrap = @import("bootstrap.zig");
pub const dht = @import("dht.zig");
pub const krpc = @import("krpc.zig");
pub const lookup = @import("lookup.zig");
pub const node_id = @import("node_id.zig");
pub const persistence = @import("persistence.zig");
pub const routing_table = @import("routing_table.zig");
pub const token = @import("token.zig");

// Re-export primary types
pub const DhtEngine = dht.DhtEngine;
pub const NodeId = node_id.NodeId;
pub const NodeInfo = node_id.NodeInfo;
pub const RoutingTable = routing_table.RoutingTable;

// Wire source-side `test "..."` blocks into the test runner. Mirrors
// the pattern in `src/torrent/root.zig`, `src/crypto/root.zig`,
// `src/io/root.zig`, and `src/storage/root.zig`. The parent
// `src/root.zig` test block must also opt-in via `_ = dht;`.
test {
    _ = bootstrap;
    _ = dht;
    _ = krpc;
    _ = lookup;
    _ = node_id;
    _ = persistence;
    _ = routing_table;
    _ = token;
}
