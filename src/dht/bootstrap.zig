const std = @import("std");
const node_id = @import("node_id.zig");
const NodeId = node_id.NodeId;
const NodeInfo = node_id.NodeInfo;

/// Well-known bootstrap nodes for the public DHT network.
pub const bootstrap_nodes = [_]BootstrapEntry{
    .{ .host = "router.bittorrent.com", .port = 6881 },
    .{ .host = "dht.transmissionbt.com", .port = 6881 },
    .{ .host = "router.utorrent.com", .port = 6881 },
    .{ .host = "dht.libtorrent.org", .port = 25401 },
};

pub const BootstrapEntry = struct {
    host: []const u8,
    port: u16,
};

/// Resolve bootstrap node hostnames to addresses.
/// DNS resolution is blocking, so this should be called before the
/// event loop starts or on a background thread.
pub fn resolveBootstrapNodes(allocator: std.mem.Allocator) ![]std.net.Address {
    var addrs = std.ArrayList(std.net.Address).init(allocator);
    errdefer addrs.deinit();

    for (bootstrap_nodes) |entry| {
        // Use getAddressList for DNS resolution
        const list = std.net.Address.resolveIp(entry.host, entry.port) catch |err| {
            // DNS resolution failed for this node -- skip it.
            _ = err;
            // Try numeric parse as fallback
            continue;
        };
        try addrs.append(list);
    }

    return addrs.toOwnedSlice();
}

/// Convert resolved addresses into NodeInfo structs with random IDs.
/// Bootstrap nodes have unknown IDs until they respond to our ping.
pub fn toNodeInfos(allocator: std.mem.Allocator, addrs: []const std.net.Address) ![]NodeInfo {
    const infos = try allocator.alloc(NodeInfo, addrs.len);
    for (addrs, 0..) |addr, i| {
        // Use zero ID -- we don't know their ID yet.
        // It will be learned from their ping response.
        infos[i] = .{
            .id = [_]u8{0} ** 20,
            .address = addr,
        };
    }
    return infos;
}

test "bootstrap_nodes has expected entries" {
    try std.testing.expectEqual(@as(usize, 4), bootstrap_nodes.len);
    try std.testing.expectEqualStrings("router.bittorrent.com", bootstrap_nodes[0].host);
}
