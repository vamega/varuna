const std = @import("std");
const bencode = @import("../torrent/bencode.zig");
const bencode_encode = @import("../torrent/bencode_encode.zig");

/// BEP 11 Peer Exchange (PEX) implementation.
///
/// PEX messages are sent as BEP 10 extension messages using the ut_pex
/// extension ID. Each message contains peers added and dropped since
/// the last PEX exchange, encoded as compact IPv4/IPv6 addresses with
/// per-peer flags.
///
/// PEX is completely disabled for private torrents (BEP 27).

// ── Constants ────────────────────────────────────────────

/// Interval between PEX messages (seconds), per BEP 11.
pub const pex_interval_secs: i64 = 60;

/// Maximum number of added peers per PEX message (BEP 11 recommends 50).
pub const max_added_per_message: usize = 50;

/// Maximum number of dropped peers per PEX message.
pub const max_dropped_per_message: usize = 50;

/// Size of a compact IPv4 peer entry (4 bytes IP + 2 bytes port).
pub const compact_ipv4_size: usize = 6;

/// Size of a compact IPv6 peer entry (16 bytes IP + 2 bytes port).
pub const compact_ipv6_size: usize = 18;

// ── Peer flags (BEP 11) ─────────────────────────────────

pub const PeerFlags = packed struct(u8) {
    /// Prefers encryption (BEP 6).
    encryption: bool = false,
    /// Peer is a seed / upload only.
    seed: bool = false,
    /// Supports uTP (BEP 29).
    utp: bool = false,
    /// Peer has holepunch support (BEP 55).
    holepunch: bool = false,
    /// Peer is reachable (connectable).
    reachable: bool = false,
    _padding: u3 = 0,
};

// ── Parsed PEX message ──────────────────────────────────

/// A single peer entry from a PEX message.
pub const PexPeer = struct {
    address: std.net.Address,
    flags: PeerFlags = .{},
};

/// Parsed ut_pex message (BEP 11).
pub const PexMessage = struct {
    added: []PexPeer,
    dropped: []PexPeer,

    pub fn deinit(self: *PexMessage, allocator: std.mem.Allocator) void {
        allocator.free(self.added);
        allocator.free(self.dropped);
        self.* = undefined;
    }
};

// ── PEX state per peer ──────────────────────────────────

/// Tracks PEX state for a single peer connection.
/// Maintains the set of peers we have sent to this peer so we can
/// compute added/dropped deltas for the next message.
pub const PexState = struct {
    /// Timestamp of the last PEX message sent to this peer.
    last_pex_time: i64 = 0,
    /// Set of peer addresses we last told this peer about.
    /// Keys are compact IPv4 representations (6 bytes each).
    sent_peers: std.AutoHashMapUnmanaged(CompactPeer, void) = .empty,

    pub fn deinit(self: *PexState, allocator: std.mem.Allocator) void {
        self.sent_peers.deinit(allocator);
        self.* = undefined;
    }
};

/// Compact peer representation for hashmap keys.
/// Supports both IPv4 (6 bytes) and IPv6 (18 bytes).
pub const CompactPeer = struct {
    data: [18]u8 = @as([18]u8, @splat(0)),
    len: u8 = 0,

    pub fn fromAddress(addr: std.net.Address) CompactPeer {
        var result = CompactPeer{};
        switch (addr.any.family) {
            std.posix.AF.INET => {
                const ip4 = @as(*const std.posix.sockaddr.in, @ptrCast(@alignCast(&addr.any)));
                const ip_bytes = std.mem.asBytes(&ip4.addr);
                @memcpy(result.data[0..4], ip_bytes);
                // `ip4.port` is already in network byte order (BE) — copying
                // the raw bytes gives us the BEP 11 wire encoding directly.
                // Calling `writeInt(.., .big)` on the raw value would
                // double-swap on LE hosts, producing the wrong port (BUG
                // surfaced by the previously-dark "CompactPeer roundtrip"
                // tests after dark-test wiring).
                @memcpy(result.data[4..6], std.mem.asBytes(&ip4.port));
                result.len = compact_ipv4_size;
            },
            std.posix.AF.INET6 => {
                const ip6 = @as(*const std.posix.sockaddr.in6, @ptrCast(@alignCast(&addr.any)));
                const ip_bytes = std.mem.asBytes(&ip6.addr);
                @memcpy(result.data[0..16], ip_bytes);
                @memcpy(result.data[16..18], std.mem.asBytes(&ip6.port));
                result.len = compact_ipv6_size;
            },
            else => {},
        }
        return result;
    }

    pub fn toAddress(self: CompactPeer) ?std.net.Address {
        if (self.len == compact_ipv4_size) {
            return addressFromCompactIpv4(self.data[0..compact_ipv4_size]);
        } else if (self.len == compact_ipv6_size) {
            return addressFromCompactIpv6(self.data[0..compact_ipv6_size]);
        }
        return null;
    }
};

// ── Torrent-level PEX state ─────────────────────────────

/// Tracks the set of known connected peers for a torrent, used to
/// generate PEX added/dropped lists.
pub const TorrentPexState = struct {
    /// Currently connected peers (address -> flags).
    connected_peers: std.AutoHashMapUnmanaged(CompactPeer, PeerFlags) = .empty,

    pub fn deinit(self: *TorrentPexState, allocator: std.mem.Allocator) void {
        self.connected_peers.deinit(allocator);
        self.* = undefined;
    }

    /// Register a peer as connected.
    pub fn addPeer(self: *TorrentPexState, allocator: std.mem.Allocator, addr: std.net.Address, flags: PeerFlags) void {
        const key = CompactPeer.fromAddress(addr);
        if (key.len == 0) return;
        self.connected_peers.put(allocator, key, flags) catch {};
    }

    /// Remove a peer (disconnected).
    pub fn removePeer(self: *TorrentPexState, addr: std.net.Address) void {
        const key = CompactPeer.fromAddress(addr);
        if (key.len == 0) return;
        _ = self.connected_peers.remove(key);
    }
};

// ── Parsing ─────────────────────────────────────────────

/// Parse a ut_pex message payload (bencoded dictionary).
/// The payload is the data after the BEP 10 sub-ID byte.
pub fn parsePexMessage(allocator: std.mem.Allocator, data: []const u8) !PexMessage {
    const root = bencode.parse(allocator, data) catch return error.InvalidPexMessage;

    const dict = switch (root) {
        .dict => |d| d,
        else => {
            bencode.freeValue(allocator, root);
            return error.InvalidPexMessage;
        },
    };
    defer bencode.freeValue(allocator, root);

    var added = std.ArrayList(PexPeer).empty;
    defer added.deinit(allocator);
    var dropped = std.ArrayList(PexPeer).empty;
    defer dropped.deinit(allocator);

    // Parse "added" (compact IPv4 peers)
    const added_data = if (bencode.dictGet(dict, "added")) |v|
        (if (v == .bytes) v.bytes else null)
    else
        null;
    const added_flags = if (bencode.dictGet(dict, "added.f")) |v|
        (if (v == .bytes) v.bytes else null)
    else
        null;

    if (added_data) |data_bytes| {
        const peer_count = data_bytes.len / compact_ipv4_size;
        for (0..peer_count) |i| {
            const offset = i * compact_ipv4_size;
            const addr = addressFromCompactIpv4(data_bytes[offset..][0..compact_ipv4_size]) orelse continue;
            const flags: PeerFlags = if (added_flags != null and i < added_flags.?.len)
                @bitCast(added_flags.?[i])
            else
                .{};
            try added.append(allocator, .{ .address = addr, .flags = flags });
        }
    }

    // Parse "added6" (compact IPv6 peers)
    const added6_data = if (bencode.dictGet(dict, "added6")) |v|
        (if (v == .bytes) v.bytes else null)
    else
        null;
    const added6_flags = if (bencode.dictGet(dict, "added6.f")) |v|
        (if (v == .bytes) v.bytes else null)
    else
        null;

    if (added6_data) |data_bytes| {
        const peer_count = data_bytes.len / compact_ipv6_size;
        for (0..peer_count) |i| {
            const offset = i * compact_ipv6_size;
            const addr = addressFromCompactIpv6(data_bytes[offset..][0..compact_ipv6_size]) orelse continue;
            const flags: PeerFlags = if (added6_flags != null and i < added6_flags.?.len)
                @bitCast(added6_flags.?[i])
            else
                .{};
            try added.append(allocator, .{ .address = addr, .flags = flags });
        }
    }

    // Parse "dropped" (compact IPv4 peers)
    const dropped_data = if (bencode.dictGet(dict, "dropped")) |v|
        (if (v == .bytes) v.bytes else null)
    else
        null;

    if (dropped_data) |data_bytes| {
        const peer_count = data_bytes.len / compact_ipv4_size;
        for (0..peer_count) |i| {
            const offset = i * compact_ipv4_size;
            const addr = addressFromCompactIpv4(data_bytes[offset..][0..compact_ipv4_size]) orelse continue;
            try dropped.append(allocator, .{ .address = addr, .flags = .{} });
        }
    }

    // Parse "dropped6" (compact IPv6 peers)
    const dropped6_data = if (bencode.dictGet(dict, "dropped6")) |v|
        (if (v == .bytes) v.bytes else null)
    else
        null;

    if (dropped6_data) |data_bytes| {
        const peer_count = data_bytes.len / compact_ipv6_size;
        for (0..peer_count) |i| {
            const offset = i * compact_ipv6_size;
            const addr = addressFromCompactIpv6(data_bytes[offset..][0..compact_ipv6_size]) orelse continue;
            try dropped.append(allocator, .{ .address = addr, .flags = .{} });
        }
    }

    return .{
        .added = try added.toOwnedSlice(allocator),
        .dropped = try dropped.toOwnedSlice(allocator),
    };
}

// ── Message generation ──────────────────────────────────

/// Build a ut_pex message payload (bencoded dictionary) containing
/// the delta between the current connected peers and what was
/// previously sent to this peer.
///
/// Returns null if there are no changes to report.
pub fn buildPexMessage(
    allocator: std.mem.Allocator,
    torrent_pex: *const TorrentPexState,
    peer_pex: *PexState,
) !?[]u8 {
    // Compute added: peers in torrent_pex.connected_peers but not in peer_pex.sent_peers
    var added_v4 = std.ArrayList(u8).empty;
    defer added_v4.deinit(allocator);
    var added_v4_flags = std.ArrayList(u8).empty;
    defer added_v4_flags.deinit(allocator);
    var added_v6 = std.ArrayList(u8).empty;
    defer added_v6.deinit(allocator);
    var added_v6_flags = std.ArrayList(u8).empty;
    defer added_v6_flags.deinit(allocator);
    var added_keys = std.ArrayList(CompactPeer).empty;
    defer added_keys.deinit(allocator);

    var added_count: usize = 0;
    var it = torrent_pex.connected_peers.iterator();
    while (it.next()) |entry| {
        if (added_count >= max_added_per_message) break;
        if (!peer_pex.sent_peers.contains(entry.key_ptr.*)) {
            const key = entry.key_ptr.*;
            if (key.len == compact_ipv4_size) {
                try added_v4.appendSlice(allocator, key.data[0..compact_ipv4_size]);
                try added_v4_flags.append(allocator, @bitCast(entry.value_ptr.*));
            } else if (key.len == compact_ipv6_size) {
                try added_v6.appendSlice(allocator, key.data[0..compact_ipv6_size]);
                try added_v6_flags.append(allocator, @bitCast(entry.value_ptr.*));
            }
            try added_keys.append(allocator, key);
            added_count += 1;
        }
    }

    // Compute dropped: peers in peer_pex.sent_peers but not in torrent_pex.connected_peers
    var dropped_v4 = std.ArrayList(u8).empty;
    defer dropped_v4.deinit(allocator);
    var dropped_v6 = std.ArrayList(u8).empty;
    defer dropped_v6.deinit(allocator);
    var dropped_keys = std.ArrayList(CompactPeer).empty;
    defer dropped_keys.deinit(allocator);

    var dropped_count: usize = 0;
    var sent_it = peer_pex.sent_peers.iterator();
    while (sent_it.next()) |entry| {
        if (dropped_count >= max_dropped_per_message) break;
        if (!torrent_pex.connected_peers.contains(entry.key_ptr.*)) {
            const key = entry.key_ptr.*;
            if (key.len == compact_ipv4_size) {
                try dropped_v4.appendSlice(allocator, key.data[0..compact_ipv4_size]);
            } else if (key.len == compact_ipv6_size) {
                try dropped_v6.appendSlice(allocator, key.data[0..compact_ipv6_size]);
            }
            try dropped_keys.append(allocator, key);
            dropped_count += 1;
        }
    }

    // If nothing changed, skip
    if (added_count == 0 and dropped_count == 0) return null;

    // Build bencoded message.
    // Keys must be sorted: "added" < "added.f" < "added6" < "added6.f" < "dropped" < "dropped6"
    var entry_count: usize = 0;
    // Always include added and dropped (even if empty) for compatibility
    entry_count += 2; // "added", "dropped"
    if (added_v4_flags.items.len > 0) entry_count += 1; // "added.f"
    if (added_v6.items.len > 0) entry_count += 1; // "added6"
    if (added_v6_flags.items.len > 0) entry_count += 1; // "added6.f"
    if (dropped_v6.items.len > 0) entry_count += 1; // "dropped6"

    var entries = try allocator.alloc(bencode.Value.Entry, entry_count);
    defer allocator.free(entries);

    var idx: usize = 0;
    entries[idx] = .{ .key = "added", .value = .{ .bytes = added_v4.items } };
    idx += 1;
    if (added_v4_flags.items.len > 0) {
        entries[idx] = .{ .key = "added.f", .value = .{ .bytes = added_v4_flags.items } };
        idx += 1;
    }
    if (added_v6.items.len > 0) {
        entries[idx] = .{ .key = "added6", .value = .{ .bytes = added_v6.items } };
        idx += 1;
    }
    if (added_v6_flags.items.len > 0) {
        entries[idx] = .{ .key = "added6.f", .value = .{ .bytes = added_v6_flags.items } };
        idx += 1;
    }
    entries[idx] = .{ .key = "dropped", .value = .{ .bytes = dropped_v4.items } };
    idx += 1;
    if (dropped_v6.items.len > 0) {
        entries[idx] = .{ .key = "dropped6", .value = .{ .bytes = dropped_v6.items } };
        idx += 1;
    }

    const payload = try bencode_encode.encode(allocator, .{ .dict = entries[0..idx] });

    // Update peer's sent_peers only for peers reflected in this delta.
    // This preserves capped additions/drops for later messages.
    for (added_keys.items) |key| {
        peer_pex.sent_peers.put(allocator, key, {}) catch {};
    }
    for (dropped_keys.items) |key| {
        _ = peer_pex.sent_peers.remove(key);
    }

    return payload;
}

// ── Compact address helpers ─────────────────────────────

fn addressFromCompactIpv4(data: *const [compact_ipv4_size]u8) ?std.net.Address {
    const port = std.mem.readInt(u16, data[4..6], .big);
    if (port == 0) return null;
    // Filter 0.0.0.0
    if (data[0] == 0 and data[1] == 0 and data[2] == 0 and data[3] == 0) return null;
    return std.net.Address.initIp4(data[0..4].*, port);
}

fn addressFromCompactIpv6(data: *const [compact_ipv6_size]u8) ?std.net.Address {
    const port = std.mem.readInt(u16, data[16..18], .big);
    if (port == 0) return null;
    return std.net.Address.initIp6(data[0..16].*, port, 0, 0);
}

// ── Tests ────────────────────────────────────────────────

test "parse empty PEX message" {
    const input = "d5:added0:7:dropped0:e";
    var msg = try parsePexMessage(std.testing.allocator, input);
    defer msg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), msg.added.len);
    try std.testing.expectEqual(@as(usize, 0), msg.dropped.len);
}

test "parse PEX message with IPv4 peers" {
    // Build a bencoded PEX message with one added IPv4 peer: 192.168.1.1:6881
    // Compact: 0xC0 0xA8 0x01 0x01 0x1A 0xE1
    const compact = [_]u8{ 0xC0, 0xA8, 0x01, 0x01, 0x1A, 0xE1 };
    const flags_byte = [_]u8{0x02}; // seed flag
    const input = "d5:added6:" ++ compact ++ "7:added.f1:" ++ flags_byte ++ "7:dropped0:e";

    var msg = try parsePexMessage(std.testing.allocator, input);
    defer msg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), msg.added.len);
    try std.testing.expectEqual(@as(usize, 0), msg.dropped.len);

    const peer = msg.added[0];
    try std.testing.expectEqual(@as(u16, 6881), peer.address.getPort());
    try std.testing.expect(peer.flags.seed);
    try std.testing.expect(!peer.flags.encryption);
}

test "parse PEX message with dropped peers" {
    const compact = [_]u8{ 10, 0, 0, 1, 0x1A, 0xE1 };
    const input = "d5:added0:7:dropped6:" ++ compact ++ "e";

    var msg = try parsePexMessage(std.testing.allocator, input);
    defer msg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), msg.added.len);
    try std.testing.expectEqual(@as(usize, 1), msg.dropped.len);
    try std.testing.expectEqual(@as(u16, 6881), msg.dropped[0].address.getPort());
}

test "parse PEX message rejects non-dict" {
    try std.testing.expectError(
        error.InvalidPexMessage,
        parsePexMessage(std.testing.allocator, "i42e"),
    );
}

test "parse PEX message handles minimal dict" {
    var msg = try parsePexMessage(std.testing.allocator, "de");
    defer msg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), msg.added.len);
    try std.testing.expectEqual(@as(usize, 0), msg.dropped.len);
}

test "parse PEX message filters zero port" {
    // Port 0 should be filtered out
    const compact = [_]u8{ 192, 168, 1, 1, 0, 0 };
    const input = "d5:added6:" ++ compact ++ "7:dropped0:e";

    var msg = try parsePexMessage(std.testing.allocator, input);
    defer msg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), msg.added.len);
}

test "parse PEX message filters 0.0.0.0" {
    const compact = [_]u8{ 0, 0, 0, 0, 0x1A, 0xE1 };
    const input = "d5:added6:" ++ compact ++ "7:dropped0:e";

    var msg = try parsePexMessage(std.testing.allocator, input);
    defer msg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), msg.added.len);
}

test "CompactPeer roundtrip IPv4" {
    const addr = std.net.Address.initIp4(.{ 192, 168, 1, 100 }, 51413);
    const compact = CompactPeer.fromAddress(addr);
    try std.testing.expectEqual(@as(u8, compact_ipv4_size), compact.len);

    const recovered = compact.toAddress() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 51413), recovered.getPort());
}

test "CompactPeer roundtrip IPv6" {
    const addr = std.net.Address.initIp6(
        .{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 },
        51413,
        0,
        0,
    );
    const compact = CompactPeer.fromAddress(addr);
    try std.testing.expectEqual(@as(u8, compact_ipv6_size), compact.len);

    const recovered = compact.toAddress() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(u16, 51413), recovered.getPort());
}

test "build PEX message with added peers" {
    var torrent_pex = TorrentPexState{};
    defer torrent_pex.deinit(std.testing.allocator);

    var peer_pex = PexState{};
    defer peer_pex.deinit(std.testing.allocator);

    // Add some peers to the torrent
    const addr1 = std.net.Address.initIp4(.{ 192, 168, 1, 1 }, 6881);
    const addr2 = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 51413);
    torrent_pex.addPeer(std.testing.allocator, addr1, .{ .seed = true });
    torrent_pex.addPeer(std.testing.allocator, addr2, .{});

    // Build PEX message -- should include both peers as added
    const payload = try buildPexMessage(std.testing.allocator, &torrent_pex, &peer_pex) orelse
        return error.TestUnexpectedResult;
    defer std.testing.allocator.free(payload);

    // Parse it back
    var msg = try parsePexMessage(std.testing.allocator, payload);
    defer msg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), msg.added.len);
    try std.testing.expectEqual(@as(usize, 0), msg.dropped.len);
}

test "build PEX message with dropped peers" {
    var torrent_pex = TorrentPexState{};
    defer torrent_pex.deinit(std.testing.allocator);

    var peer_pex = PexState{};
    defer peer_pex.deinit(std.testing.allocator);

    // First exchange: tell peer about addr1
    const addr1 = std.net.Address.initIp4(.{ 192, 168, 1, 1 }, 6881);
    torrent_pex.addPeer(std.testing.allocator, addr1, .{});

    const payload1 = try buildPexMessage(std.testing.allocator, &torrent_pex, &peer_pex) orelse
        return error.TestUnexpectedResult;
    std.testing.allocator.free(payload1);

    // Now remove addr1 from the torrent
    torrent_pex.removePeer(addr1);

    // Second exchange: addr1 should appear as dropped
    const payload2 = try buildPexMessage(std.testing.allocator, &torrent_pex, &peer_pex) orelse
        return error.TestUnexpectedResult;
    defer std.testing.allocator.free(payload2);

    var msg = try parsePexMessage(std.testing.allocator, payload2);
    defer msg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), msg.added.len);
    try std.testing.expectEqual(@as(usize, 1), msg.dropped.len);
}

test "build PEX message returns null when no changes" {
    var torrent_pex = TorrentPexState{};
    defer torrent_pex.deinit(std.testing.allocator);

    var peer_pex = PexState{};
    defer peer_pex.deinit(std.testing.allocator);

    // No peers at all -- should return null
    const result = try buildPexMessage(std.testing.allocator, &torrent_pex, &peer_pex);
    try std.testing.expect(result == null);
}

test "build PEX message returns null after sync" {
    var torrent_pex = TorrentPexState{};
    defer torrent_pex.deinit(std.testing.allocator);

    var peer_pex = PexState{};
    defer peer_pex.deinit(std.testing.allocator);

    const addr1 = std.net.Address.initIp4(.{ 192, 168, 1, 1 }, 6881);
    torrent_pex.addPeer(std.testing.allocator, addr1, .{});

    // First exchange
    const payload = try buildPexMessage(std.testing.allocator, &torrent_pex, &peer_pex) orelse
        return error.TestUnexpectedResult;
    std.testing.allocator.free(payload);

    // Second exchange with no changes -- should return null
    const result = try buildPexMessage(std.testing.allocator, &torrent_pex, &peer_pex);
    try std.testing.expect(result == null);
}

test "PeerFlags bit layout" {
    const flags = PeerFlags{ .encryption = true, .seed = true, .utp = true };
    const byte: u8 = @bitCast(flags);
    try std.testing.expectEqual(@as(u8, 0x07), byte);

    const recovered: PeerFlags = @bitCast(@as(u8, 0x02));
    try std.testing.expect(recovered.seed);
    try std.testing.expect(!recovered.encryption);
    try std.testing.expect(!recovered.utp);
}

test "TorrentPexState add and remove" {
    var state = TorrentPexState{};
    defer state.deinit(std.testing.allocator);

    const addr = std.net.Address.initIp4(.{ 192, 168, 1, 1 }, 6881);
    state.addPeer(std.testing.allocator, addr, .{ .seed = true });
    try std.testing.expectEqual(@as(u32, 1), state.connected_peers.count());

    state.removePeer(addr);
    try std.testing.expectEqual(@as(u32, 0), state.connected_peers.count());
}

test "max_added_per_message is respected" {
    var torrent_pex = TorrentPexState{};
    defer torrent_pex.deinit(std.testing.allocator);

    var peer_pex = PexState{};
    defer peer_pex.deinit(std.testing.allocator);

    // Add more peers than the limit
    for (0..max_added_per_message + 10) |i| {
        const port: u16 = @intCast(10000 + i);
        const addr = std.net.Address.initIp4(.{ 192, 168, 1, 1 }, port);
        torrent_pex.addPeer(std.testing.allocator, addr, .{});
    }

    const payload = try buildPexMessage(std.testing.allocator, &torrent_pex, &peer_pex) orelse
        return error.TestUnexpectedResult;
    defer std.testing.allocator.free(payload);

    var msg = try parsePexMessage(std.testing.allocator, payload);
    defer msg.deinit(std.testing.allocator);

    // Should be capped at max_added_per_message
    try std.testing.expect(msg.added.len <= max_added_per_message);
}

test "capped dropped peers remain pending for later messages" {
    var torrent_pex = TorrentPexState{};
    defer torrent_pex.deinit(std.testing.allocator);

    var peer_pex = PexState{};
    defer peer_pex.deinit(std.testing.allocator);

    for (0..max_dropped_per_message + 10) |i| {
        const port: u16 = @intCast(10000 + i);
        const addr = std.net.Address.initIp4(.{ 10, 0, 0, @intCast((i % 250) + 1) }, port);
        try peer_pex.sent_peers.put(std.testing.allocator, CompactPeer.fromAddress(addr), {});
    }

    const payload1 = try buildPexMessage(std.testing.allocator, &torrent_pex, &peer_pex) orelse
        return error.TestUnexpectedResult;
    defer std.testing.allocator.free(payload1);
    var msg1 = try parsePexMessage(std.testing.allocator, payload1);
    defer msg1.deinit(std.testing.allocator);
    try std.testing.expectEqual(max_dropped_per_message, msg1.dropped.len);

    const payload2 = try buildPexMessage(std.testing.allocator, &torrent_pex, &peer_pex) orelse
        return error.TestUnexpectedResult;
    defer std.testing.allocator.free(payload2);
    var msg2 = try parsePexMessage(std.testing.allocator, payload2);
    defer msg2.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 10), msg2.dropped.len);
}

test "parse PEX message with multiple IPv4 peers" {
    // Two peers: 192.168.1.1:6881 and 10.0.0.1:51413 (0xC8D5)
    const compact = [_]u8{ 0xC0, 0xA8, 0x01, 0x01, 0x1A, 0xE1, 10, 0, 0, 1, 0xC8, 0xD5 };
    const flags_bytes = [_]u8{ 0x01, 0x02 };
    const input = "d5:added12:" ++ compact ++ "7:added.f2:" ++ flags_bytes ++ "7:dropped0:e";

    var msg = try parsePexMessage(std.testing.allocator, input);
    defer msg.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), msg.added.len);
    try std.testing.expectEqual(@as(u16, 6881), msg.added[0].address.getPort());
    try std.testing.expect(msg.added[0].flags.encryption);
    try std.testing.expectEqual(@as(u16, 51413), msg.added[1].address.getPort());
    try std.testing.expect(msg.added[1].flags.seed);
}

test "fuzz PEX message parser" {
    try std.testing.fuzz({}, struct {
        fn run(_: void, input: []const u8) anyerror!void {
            var msg = parsePexMessage(std.testing.allocator, input) catch return;
            msg.deinit(std.testing.allocator);
        }
    }.run, .{
        .corpus = &.{
            "de",
            "d5:added0:7:dropped0:e",
            "d5:added6:\xc0\xa8\x01\x01\x1a\xe17:dropped0:e",
            "i42e",
            "",
            "d",
            "d5:added",
        },
    });
}
