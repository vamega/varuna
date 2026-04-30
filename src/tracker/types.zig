const std = @import("std");
const Random = @import("../runtime/random.zig").Random;

pub const Request = struct {
    announce_url: []const u8,
    info_hash: [20]u8,
    peer_id: [20]u8,
    port: u16,
    uploaded: u64 = 0,
    downloaded: u64 = 0,
    left: u64,
    event: ?Event = .started,
    key: ?[8]u8 = null,
    numwant: u32 = 50,

    info_hash_v2: ?[32]u8 = null,

    pub const Event = enum {
        started,
        completed,
        stopped,
    };

    /// Generate the BEP 3 `key` parameter. The key is a stable
    /// per-client identifier sent to trackers; predictability isn't a
    /// security concern, so we route through the runtime `Random`
    /// abstraction so tests/sim runs see a deterministic key.
    pub fn generateKey(rng: *Random) [8]u8 {
        const hex = "0123456789abcdef";
        var buf: [8]u8 = undefined;
        var random_bytes: [8]u8 = undefined;
        rng.bytes(&random_bytes);
        for (random_bytes, 0..) |byte, i| {
            buf[i] = hex[byte & 0x0f];
        }
        return buf;
    }
};

pub const Peer = struct {
    address: std.net.Address,
};

pub const Response = struct {
    interval: u32,
    peers: []Peer,
    complete: ?u32 = null,
    incomplete: ?u32 = null,
    warning_message: ?[]const u8 = null,
};

pub fn appendPercentEncoded(
    allocator: std.mem.Allocator,
    url: *std.ArrayList(u8),
    bytes: []const u8,
) !void {
    const hex = "0123456789ABCDEF";

    for (bytes) |byte| {
        if (isUnreserved(byte)) {
            try url.append(allocator, byte);
        } else {
            try url.append(allocator, '%');
            try url.append(allocator, hex[byte >> 4]);
            try url.append(allocator, hex[byte & 0x0f]);
        }
    }
}

pub fn isUnreserved(byte: u8) bool {
    return switch (byte) {
        'A'...'Z', 'a'...'z', '0'...'9', '-', '.', '_', '~' => true,
        else => false,
    };
}

pub fn parseCompactPeers(allocator: std.mem.Allocator, bytes: []const u8) ![]Peer {
    if (bytes.len % 6 != 0) {
        return error.InvalidPeersField;
    }

    const count = bytes.len / 6;
    const peers = try allocator.alloc(Peer, count);
    errdefer allocator.free(peers);

    for (peers, 0..) |*peer, index| {
        const chunk = bytes[index * 6 ..][0..6];
        const port = std.mem.readInt(u16, chunk[4..6], .big);
        peer.* = .{
            .address = std.net.Address.initIp4(.{ chunk[0], chunk[1], chunk[2], chunk[3] }, port),
        };
    }

    return peers;
}

pub fn parseCompactPeers6(allocator: std.mem.Allocator, bytes: []const u8) ![]Peer {
    if (bytes.len % 18 != 0) {
        return error.InvalidPeersField;
    }

    const count = bytes.len / 18;
    const peers = try allocator.alloc(Peer, count);
    errdefer allocator.free(peers);

    for (peers, 0..) |*peer, index| {
        const chunk = bytes[index * 18 ..][0..18];
        const port = std.mem.readInt(u16, chunk[16..18], .big);
        peer.* = .{
            .address = std.net.Address.initIp6(chunk[0..16].*, port, 0, 0),
        };
    }

    return peers;
}
