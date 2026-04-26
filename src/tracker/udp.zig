const std = @import("std");
const posix = std.posix;
const types = @import("types.zig");

const log = std.log.scoped(.udp_tracker);

// ── BEP 15 constants ────────────────────────────────────

/// Magic protocol ID for UDP tracker connect requests (BEP 15).
pub const protocol_id: u64 = 0x41727101980;

/// Action codes in UDP tracker protocol.
pub const Action = enum(u32) {
    connect = 0,
    announce = 1,
    scrape = 2,
    @"error" = 3,
};

/// BEP 15 event codes (different from HTTP event names!).
pub const UdpEvent = enum(u32) {
    none = 0,
    completed = 1,
    started = 2,
    stopped = 3,
};

/// BEP 15 allows up to 8 retries (timeout = 15 * 2^n), but we cap at 4
/// to avoid excessively long waits (15 + 30 + 60 + 120 = 225s max).
pub const max_retries: u32 = 4;

/// Base timeout in seconds (BEP 15).
pub const base_timeout_secs: u64 = 15;

/// Connection ID validity period (BEP 15: ~2 minutes).
pub const connection_id_ttl_secs: i64 = 120;

/// Maximum UDP response buffer size.
pub const max_response_size: usize = 4096;

// ── Packet encode/decode ────────────────────────────────

/// 16-byte connect request packet.
pub const ConnectRequest = struct {
    transaction_id: u32,

    pub fn encode(self: ConnectRequest) [16]u8 {
        var buf: [16]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], protocol_id, .big);
        std.mem.writeInt(u32, buf[8..12], @intFromEnum(Action.connect), .big);
        std.mem.writeInt(u32, buf[12..16], self.transaction_id, .big);
        return buf;
    }
};

/// 16-byte connect response packet.
pub const ConnectResponse = struct {
    action: Action,
    transaction_id: u32,
    connection_id: u64,

    pub fn decode(buf: []const u8) !ConnectResponse {
        if (buf.len < 16) return error.PacketTooShort;
        const action_raw = std.mem.readInt(u32, buf[0..4], .big);
        const action = std.meta.intToEnum(Action, action_raw) catch return error.InvalidAction;
        if (action == .@"error") return error.TrackerError;
        if (action != .connect) return error.UnexpectedAction;
        return .{
            .action = action,
            .transaction_id = std.mem.readInt(u32, buf[4..8], .big),
            .connection_id = std.mem.readInt(u64, buf[8..16], .big),
        };
    }
};

/// 98-byte announce request packet.
pub const AnnounceRequest = struct {
    connection_id: u64,
    transaction_id: u32,
    info_hash: [20]u8,
    peer_id: [20]u8,
    downloaded: u64,
    left: u64,
    uploaded: u64,
    event: UdpEvent,
    ip: u32, // 0 = default
    key: u32,
    num_want: i32,
    port: u16,

    pub fn encode(self: AnnounceRequest) [98]u8 {
        var buf: [98]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], self.connection_id, .big);
        std.mem.writeInt(u32, buf[8..12], @intFromEnum(Action.announce), .big);
        std.mem.writeInt(u32, buf[12..16], self.transaction_id, .big);
        @memcpy(buf[16..36], self.info_hash[0..]);
        @memcpy(buf[36..56], self.peer_id[0..]);
        std.mem.writeInt(u64, buf[56..64], self.downloaded, .big);
        std.mem.writeInt(u64, buf[64..72], self.left, .big);
        std.mem.writeInt(u64, buf[72..80], self.uploaded, .big);
        std.mem.writeInt(u32, buf[80..84], @intFromEnum(self.event), .big);
        std.mem.writeInt(u32, buf[84..88], self.ip, .big);
        std.mem.writeInt(u32, buf[88..92], self.key, .big);
        std.mem.writeInt(i32, buf[92..96], self.num_want, .big);
        std.mem.writeInt(u16, buf[96..98], self.port, .big);
        return buf;
    }

    pub fn decode(buf: []const u8) !AnnounceRequest {
        if (buf.len < 98) return error.PacketTooShort;
        return .{
            .connection_id = std.mem.readInt(u64, buf[0..8], .big),
            .transaction_id = std.mem.readInt(u32, buf[12..16], .big),
            .info_hash = buf[16..36].*,
            .peer_id = buf[36..56].*,
            .downloaded = std.mem.readInt(u64, buf[56..64], .big),
            .left = std.mem.readInt(u64, buf[64..72], .big),
            .uploaded = std.mem.readInt(u64, buf[72..80], .big),
            .event = std.meta.intToEnum(UdpEvent, std.mem.readInt(u32, buf[80..84], .big)) catch .none,
            .ip = std.mem.readInt(u32, buf[84..88], .big),
            .key = std.mem.readInt(u32, buf[88..92], .big),
            .num_want = std.mem.readInt(i32, buf[92..96], .big),
            .port = std.mem.readInt(u16, buf[96..98], .big),
        };
    }
};

/// Announce response: 20-byte header + 6 bytes per compact IPv4 peer.
pub const AnnounceResponse = struct {
    action: Action,
    transaction_id: u32,
    interval: u32,
    leechers: u32,
    seeders: u32,
    peers_data: []const u8, // compact peers (6 bytes each for IPv4)

    pub fn decode(buf: []const u8) !AnnounceResponse {
        if (buf.len < 20) return error.PacketTooShort;
        const action_raw = std.mem.readInt(u32, buf[0..4], .big);
        const action = std.meta.intToEnum(Action, action_raw) catch return error.InvalidAction;
        if (action == .@"error") return error.TrackerError;
        if (action != .announce) return error.UnexpectedAction;
        return .{
            .action = action,
            .transaction_id = std.mem.readInt(u32, buf[4..8], .big),
            .interval = std.mem.readInt(u32, buf[8..12], .big),
            .leechers = std.mem.readInt(u32, buf[12..16], .big),
            .seeders = std.mem.readInt(u32, buf[16..20], .big),
            .peers_data = buf[20..],
        };
    }

    /// Parse compact IPv4 peers from the response.
    pub fn parsePeers(self: AnnounceResponse, allocator: std.mem.Allocator) ![]types.Peer {
        return parseCompactPeers(allocator, self.peers_data);
    }
};

/// Scrape request: 16-byte header + 20 bytes per info_hash (up to ~74).
pub const ScrapeRequest = struct {
    connection_id: u64,
    transaction_id: u32,
    info_hashes: []const [20]u8,

    /// Encode a scrape request. Caller must ensure info_hashes.len <= 74.
    pub fn encode(self: ScrapeRequest, buf: []u8) ![]u8 {
        const total = 16 + self.info_hashes.len * 20;
        if (buf.len < total) return error.BufferTooSmall;
        std.mem.writeInt(u64, buf[0..8], self.connection_id, .big);
        std.mem.writeInt(u32, buf[8..12], @intFromEnum(Action.scrape), .big);
        std.mem.writeInt(u32, buf[12..16], self.transaction_id, .big);
        for (self.info_hashes, 0..) |hash, i| {
            @memcpy(buf[16 + i * 20 ..][0..20], hash[0..]);
        }
        return buf[0..total];
    }

    /// Encode a single-hash scrape request into a fixed buffer.
    pub fn encodeSingle(connection_id: u64, transaction_id: u32, info_hash: [20]u8) [36]u8 {
        var buf: [36]u8 = undefined;
        std.mem.writeInt(u64, buf[0..8], connection_id, .big);
        std.mem.writeInt(u32, buf[8..12], @intFromEnum(Action.scrape), .big);
        std.mem.writeInt(u32, buf[12..16], transaction_id, .big);
        @memcpy(buf[16..36], info_hash[0..]);
        return buf;
    }
};

/// Scrape response codec: 8-byte header + 12 bytes per info_hash result.
pub const ScrapeResponse = struct {
    pub const ScrapeEntry = struct {
        seeders: u32,
        completed: u32,
        leechers: u32,
    };

    /// Decode scrape response. Returns entries referencing caller-provided storage.
    pub fn decodeHeader(buf: []const u8) !struct { action: Action, transaction_id: u32, entry_data: []const u8 } {
        if (buf.len < 8) return error.PacketTooShort;
        const action_raw = std.mem.readInt(u32, buf[0..4], .big);
        const action = std.meta.intToEnum(Action, action_raw) catch return error.InvalidAction;
        if (action == .@"error") return error.TrackerError;
        if (action != .scrape) return error.UnexpectedAction;
        return .{
            .action = action,
            .transaction_id = std.mem.readInt(u32, buf[4..8], .big),
            .entry_data = buf[8..],
        };
    }

    /// Parse a single scrape entry at the given index.
    pub fn parseEntry(entry_data: []const u8, index: usize) !ScrapeEntry {
        const offset = index * 12;
        if (entry_data.len < offset + 12) return error.PacketTooShort;
        const d = entry_data[offset..][0..12];
        return .{
            .seeders = std.mem.readInt(u32, d[0..4], .big),
            .completed = std.mem.readInt(u32, d[4..8], .big),
            .leechers = std.mem.readInt(u32, d[8..12], .big),
        };
    }
};

/// Error response: 8-byte header + variable-length error message.
pub const ErrorResponse = struct {
    action: Action,
    transaction_id: u32,
    message: []const u8,

    pub fn decode(buf: []const u8) !ErrorResponse {
        if (buf.len < 8) return error.PacketTooShort;
        const action_raw = std.mem.readInt(u32, buf[0..4], .big);
        const action = std.meta.intToEnum(Action, action_raw) catch return error.InvalidAction;
        if (action != .@"error") return error.UnexpectedAction;
        return .{
            .action = action,
            .transaction_id = std.mem.readInt(u32, buf[4..8], .big),
            .message = buf[8..],
        };
    }
};

// ── Connection ID cache ─────────────────────────────────

/// Per-tracker-host connection ID cache with 2-minute TTL.
pub const ConnectionCache = struct {
    const max_entries = 32;

    entries: [max_entries]Entry = [_]Entry{.{}} ** max_entries,

    const Entry = struct {
        host: [253]u8 = undefined,
        host_len: u8 = 0,
        port: u16 = 0,
        connection_id: u64 = 0,
        obtained_at: i64 = 0,
        valid: bool = false,
    };

    /// Look up a cached connection ID. Returns null if expired or absent.
    pub fn get(self: *ConnectionCache, host: []const u8, port: u16) ?u64 {
        const now = std.time.timestamp();
        for (&self.entries) |*e| {
            if (!e.valid) continue;
            if (now - e.obtained_at >= connection_id_ttl_secs) {
                e.valid = false;
                continue;
            }
            if (e.port == port and e.host_len == host.len and
                std.mem.eql(u8, e.host[0..e.host_len], host))
            {
                return e.connection_id;
            }
        }
        return null;
    }

    /// Store a connection ID in the cache.
    pub fn put(self: *ConnectionCache, host: []const u8, port: u16, connection_id: u64) void {
        if (host.len > 253) return;
        const now = std.time.timestamp();

        // Look for existing entry or empty slot
        var oldest_idx: usize = 0;
        var oldest_time: i64 = std.math.maxInt(i64);
        for (&self.entries, 0..) |*e, i| {
            if (!e.valid) {
                self.storeAt(i, host, port, connection_id, now);
                return;
            }
            // Update existing
            if (e.port == port and e.host_len == host.len and
                std.mem.eql(u8, e.host[0..e.host_len], host))
            {
                self.storeAt(i, host, port, connection_id, now);
                return;
            }
            if (e.obtained_at < oldest_time) {
                oldest_time = e.obtained_at;
                oldest_idx = i;
            }
        }
        // Evict oldest
        self.storeAt(oldest_idx, host, port, connection_id, now);
    }

    /// Invalidate a cached connection ID for a host.
    pub fn invalidate(self: *ConnectionCache, host: []const u8, port: u16) void {
        for (&self.entries) |*e| {
            if (!e.valid) continue;
            if (e.port == port and e.host_len == host.len and
                std.mem.eql(u8, e.host[0..e.host_len], host))
            {
                e.valid = false;
                return;
            }
        }
    }

    fn storeAt(self: *ConnectionCache, idx: usize, host: []const u8, port: u16, connection_id: u64, now: i64) void {
        var e = &self.entries[idx];
        e.valid = true;
        e.port = port;
        e.connection_id = connection_id;
        e.obtained_at = now;
        e.host_len = @intCast(host.len);
        @memcpy(e.host[0..host.len], host);
    }
};

// ── Helper functions ────────────────────────────────────

/// Convert announce event to BEP 15 UDP event code.
pub fn eventToUdp(event: ?types.Request.Event) UdpEvent {
    const ev = event orelse return .none;
    return switch (ev) {
        .completed => .completed,
        .started => .started,
        .stopped => .stopped,
    };
}

/// Calculate BEP 15 retransmission timeout: 15 * 2^n seconds.
pub fn retransmitTimeout(attempt: u32) u64 {
    const clamped = @min(attempt, max_retries);
    return base_timeout_secs * (@as(u64, 1) << @intCast(clamped));
}

/// Generate a random transaction ID.
pub fn generateTransactionId() u32 {
    var buf: [4]u8 = undefined;
    std.crypto.random.bytes(&buf);
    return std.mem.readInt(u32, &buf, .big);
}

pub const parseCompactPeers = types.parseCompactPeers;
pub const parseCompactPeers6 = types.parseCompactPeers6;

/// Check if the first 4 bytes of a response indicate an error action.
pub fn isErrorResponse(buf: []const u8) bool {
    if (buf.len < 4) return false;
    return std.mem.readInt(u32, buf[0..4], .big) == @intFromEnum(Action.@"error");
}

/// Extract error message from an error response.
pub fn parseErrorMessage(buf: []const u8) ?[]const u8 {
    if (buf.len < 8) return null;
    if (!isErrorResponse(buf)) return null;
    if (buf.len > 8) return buf[8..] else return null;
}

/// Get the action from a raw response.
pub fn responseAction(buf: []const u8) ?Action {
    if (buf.len < 4) return null;
    return std.meta.intToEnum(Action, std.mem.readInt(u32, buf[0..4], .big)) catch null;
}

/// Get the transaction ID from a raw response.
pub fn responseTransactionId(buf: []const u8) ?u32 {
    if (buf.len < 8) return null;
    return std.mem.readInt(u32, buf[4..8], .big);
}

// ── URL parsing ─────────────────────────────────────────

pub const ParsedUdpUrl = struct {
    host: []const u8,
    port: u16,
};

pub fn parseUdpUrl(url: []const u8) ?ParsedUdpUrl {
    const after_scheme = if (std.mem.startsWith(u8, url, "udp://"))
        url[6..]
    else
        return null;

    // Strip trailing path (e.g., /announce)
    const host_port = if (std.mem.indexOfScalar(u8, after_scheme, '/')) |slash|
        after_scheme[0..slash]
    else
        after_scheme;

    // Split host:port
    if (std.mem.lastIndexOfScalar(u8, host_port, ':')) |colon| {
        const host = host_port[0..colon];
        const port = std.fmt.parseUnsigned(u16, host_port[colon + 1 ..], 10) catch return null;
        return .{ .host = host, .port = port };
    }

    return null; // No port
}

// ── DNS resolution ──────────────────────────────────────

pub fn resolveAddress(allocator: std.mem.Allocator, host: []const u8, port: u16) !std.net.Address {
    // Try numeric parse first (avoids thread/DNS overhead)
    return std.net.Address.resolveIp(host, port) catch {
        // Fall back to DNS resolution
        const list = try std.net.getAddressList(allocator, host, port);
        defer list.deinit();
        if (list.addrs.len == 0) return error.DnsResolutionFailed;
        return list.addrs[0];
    };
}

// ── Blocking UDP tracker client ─────────────────────────
// Used by background threads (magnet peer collection).
// The daemon uses the io_uring-based UdpTrackerExecutor instead.

/// Connection cache for blocking UDP tracker calls.
var global_conn_cache: ConnectionCache = .{};

/// Reset the global connection cache. For testing only.
pub fn resetGlobalCache() void {
    global_conn_cache = .{};
}

/// Perform a full UDP tracker announce via blocking posix I/O.
/// Implements BEP 15 connect + announce with exponential backoff retries.
pub fn fetchViaUdp(
    allocator: std.mem.Allocator,
    request: types.Request,
) !types.Response {
    const parsed = parseUdpUrl(request.announce_url) orelse return error.InvalidTrackerUrl;

    // Resolve address
    const address = try resolveAddress(allocator, parsed.host, parsed.port);

    // Create UDP socket
    const fd = try posix.socket(
        address.any.family,
        posix.SOCK.DGRAM | posix.SOCK.CLOEXEC,
        posix.IPPROTO.UDP,
    );
    defer posix.close(fd);

    // Connect the UDP socket (allows send/recv instead of sendto/recvfrom)
    try posix.connect(fd, &address.any, address.getOsSockLen());

    // Step 1: Connect (use cached connection ID if available)
    const connection_id = if (global_conn_cache.get(parsed.host, parsed.port)) |cached_id|
        cached_id
    else
        try performConnect(fd, parsed.host, parsed.port);

    // Step 2: Announce
    var announce_txid = generateTransactionId();
    const key_value: u32 = if (request.key) |k| std.mem.readInt(u32, k[0..4], .big) else generateTransactionId();
    const announce_req = AnnounceRequest{
        .connection_id = connection_id,
        .transaction_id = announce_txid,
        .info_hash = request.info_hash,
        .peer_id = request.peer_id,
        .downloaded = request.downloaded,
        .left = request.left,
        .uploaded = request.uploaded,
        .event = eventToUdp(request.event),
        .ip = 0,
        .key = key_value,
        .num_want = @intCast(@min(request.numwant, std.math.maxInt(i32))),
        .port = request.port,
    };
    const announce_buf = announce_req.encode();

    // BEP 15: retry announce with exponential backoff
    var resp_buf: [max_response_size]u8 = undefined;
    var resp_n: usize = 0;
    var announce_ok = false;
    for (0..max_retries) |attempt| {
        const timeout_secs = retransmitTimeout(@intCast(attempt));
        const to = posix.timeval{ .sec = @intCast(timeout_secs), .usec = 0 };
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&to)) catch {};

        sendAll(fd, &announce_buf) catch continue;
        resp_n = posix.recv(fd, &resp_buf, 0) catch |err| {
            if (err == error.WouldBlock) continue; // timeout
            continue;
        };

        if (resp_n < 8) continue;

        // Check for error response
        if (isErrorResponse(resp_buf[0..resp_n])) {
            const msg = parseErrorMessage(resp_buf[0..resp_n]);
            if (msg) |m| log.warn("UDP tracker error: {s}", .{m});
            // If we used a cached connection ID, it may be stale -- retry with fresh connect
            if (attempt == 0 and global_conn_cache.get(parsed.host, parsed.port) != null) {
                global_conn_cache.invalidate(parsed.host, parsed.port);
                const fresh_id = performConnect(fd, parsed.host, parsed.port) catch continue;
                // Rebuild announce with fresh connection ID
                var retry_req = announce_req;
                retry_req.connection_id = fresh_id;
                announce_txid = generateTransactionId();
                retry_req.transaction_id = announce_txid;
                const retry_buf = retry_req.encode();
                sendAll(fd, &retry_buf) catch continue;
                resp_n = posix.recv(fd, &resp_buf, 0) catch continue;
            }
            if (isErrorResponse(resp_buf[0..resp_n])) return error.TrackerError;
        }

        if (resp_n >= 20) {
            announce_ok = true;
            break;
        }
    }
    if (!announce_ok) return error.TrackerTimeout;

    const ann_resp = AnnounceResponse.decode(resp_buf[0..resp_n]) catch |err| {
        // If the cached connection ID was stale, the tracker may have sent an error.
        // Invalidate and let the caller retry.
        global_conn_cache.invalidate(parsed.host, parsed.port);
        return err;
    };
    if (ann_resp.transaction_id != announce_txid) return error.TransactionIdMismatch;

    // Parse compact peers
    const peers = try ann_resp.parsePeers(allocator);

    return .{
        .interval = ann_resp.interval,
        .peers = peers,
        .complete = ann_resp.seeders,
        .incomplete = ann_resp.leechers,
    };
}

/// Perform the UDP connect handshake with exponential backoff retries.
fn performConnect(fd: posix.fd_t, host: []const u8, port: u16) !u64 {
    const transaction_id = generateTransactionId();
    const connect_req = ConnectRequest{ .transaction_id = transaction_id };
    const connect_buf = connect_req.encode();

    for (0..max_retries) |attempt| {
        const timeout_secs = retransmitTimeout(@intCast(attempt));
        const to = posix.timeval{ .sec = @intCast(timeout_secs), .usec = 0 };
        posix.setsockopt(fd, posix.SOL.SOCKET, posix.SO.RCVTIMEO, std.mem.asBytes(&to)) catch {};

        sendAll(fd, &connect_buf) catch continue;

        var connect_resp: [16]u8 = undefined;
        const connect_n = posix.recv(fd, &connect_resp, 0) catch continue;
        if (connect_n < 16) continue;

        // Check for error response
        if (isErrorResponse(&connect_resp)) {
            const msg = parseErrorMessage(&connect_resp);
            if (msg) |m| log.warn("UDP tracker connect error: {s}", .{m});
            continue;
        }

        const resp = ConnectResponse.decode(&connect_resp) catch continue;
        if (resp.transaction_id != transaction_id) continue;

        // Cache the connection ID
        global_conn_cache.put(host, port, resp.connection_id);
        return resp.connection_id;
    }
    return error.TrackerTimeout;
}

/// Send the entire buffer via blocking posix.send.
fn sendAll(fd: posix.fd_t, buffer: []const u8) !void {
    var total: usize = 0;
    while (total < buffer.len) {
        const n = try posix.send(fd, buffer[total..], 0);
        if (n == 0) return error.ConnectionResetByPeer;
        total += n;
    }
}

// ── Tests ───────────────────────────────────────────────

test "encode and decode connect request" {
    const req = ConnectRequest{ .transaction_id = 0xDEADBEEF };
    const buf = req.encode();

    // Verify magic protocol ID
    try std.testing.expectEqual(protocol_id, std.mem.readInt(u64, buf[0..8], .big));
    // Verify action = connect (0)
    try std.testing.expectEqual(@as(u32, 0), std.mem.readInt(u32, buf[8..12], .big));
    // Verify transaction ID
    try std.testing.expectEqual(@as(u32, 0xDEADBEEF), std.mem.readInt(u32, buf[12..16], .big));
}

test "decode connect response" {
    var buf: [16]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 0, .big); // action = connect
    std.mem.writeInt(u32, buf[4..8], 0x12345678, .big); // transaction_id
    std.mem.writeInt(u64, buf[8..16], 0xAABBCCDDEEFF0011, .big); // connection_id

    const resp = try ConnectResponse.decode(&buf);
    try std.testing.expectEqual(Action.connect, resp.action);
    try std.testing.expectEqual(@as(u32, 0x12345678), resp.transaction_id);
    try std.testing.expectEqual(@as(u64, 0xAABBCCDDEEFF0011), resp.connection_id);
}

test "decode connect response rejects short packet" {
    var buf: [15]u8 = undefined;
    try std.testing.expectError(error.PacketTooShort, ConnectResponse.decode(&buf));
}

test "decode connect response rejects error action" {
    var buf: [16]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 3, .big); // action = error
    std.mem.writeInt(u32, buf[4..8], 0, .big);
    std.mem.writeInt(u64, buf[8..16], 0, .big);
    try std.testing.expectError(error.TrackerError, ConnectResponse.decode(&buf));
}

test "decode connect response rejects wrong action" {
    var buf: [16]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 1, .big); // action = announce (wrong for connect response)
    std.mem.writeInt(u32, buf[4..8], 0, .big);
    std.mem.writeInt(u64, buf[8..16], 0, .big);
    try std.testing.expectError(error.UnexpectedAction, ConnectResponse.decode(&buf));
}

test "encode and decode announce request" {
    const info_hash = [_]u8{0xAA} ** 20;
    const peer_id = [_]u8{0xBB} ** 20;
    const req = AnnounceRequest{
        .connection_id = 0x1234567890ABCDEF,
        .transaction_id = 0xFEDCBA98,
        .info_hash = info_hash,
        .peer_id = peer_id,
        .downloaded = 1000,
        .left = 2000,
        .uploaded = 500,
        .event = .started,
        .ip = 0,
        .key = 0x11223344,
        .num_want = 50,
        .port = 6881,
    };
    const buf = req.encode();

    // Verify round-trip
    const decoded = try AnnounceRequest.decode(&buf);
    try std.testing.expectEqual(req.connection_id, decoded.connection_id);
    try std.testing.expectEqual(req.transaction_id, decoded.transaction_id);
    try std.testing.expectEqualSlices(u8, &info_hash, &decoded.info_hash);
    try std.testing.expectEqualSlices(u8, &peer_id, &decoded.peer_id);
    try std.testing.expectEqual(req.downloaded, decoded.downloaded);
    try std.testing.expectEqual(req.left, decoded.left);
    try std.testing.expectEqual(req.uploaded, decoded.uploaded);
    try std.testing.expectEqual(req.event, decoded.event);
    try std.testing.expectEqual(req.ip, decoded.ip);
    try std.testing.expectEqual(req.key, decoded.key);
    try std.testing.expectEqual(req.num_want, decoded.num_want);
    try std.testing.expectEqual(req.port, decoded.port);
}

test "decode announce response" {
    // Build a response with 2 peers
    var buf: [32]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 1, .big); // action = announce
    std.mem.writeInt(u32, buf[4..8], 0xAABBCCDD, .big); // transaction_id
    std.mem.writeInt(u32, buf[8..12], 1800, .big); // interval
    std.mem.writeInt(u32, buf[12..16], 5, .big); // leechers
    std.mem.writeInt(u32, buf[16..20], 10, .big); // seeders
    // Peer 1: 127.0.0.1:6881
    buf[20] = 127;
    buf[21] = 0;
    buf[22] = 0;
    buf[23] = 1;
    std.mem.writeInt(u16, buf[24..26], 6881, .big);
    // Peer 2: 192.168.1.1:8080
    buf[26] = 192;
    buf[27] = 168;
    buf[28] = 1;
    buf[29] = 1;
    std.mem.writeInt(u16, buf[30..32], 8080, .big);

    const resp = try AnnounceResponse.decode(&buf);
    try std.testing.expectEqual(Action.announce, resp.action);
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), resp.transaction_id);
    try std.testing.expectEqual(@as(u32, 1800), resp.interval);
    try std.testing.expectEqual(@as(u32, 5), resp.leechers);
    try std.testing.expectEqual(@as(u32, 10), resp.seeders);

    // Parse peers
    const peers = try resp.parsePeers(std.testing.allocator);
    defer std.testing.allocator.free(peers);
    try std.testing.expectEqual(@as(usize, 2), peers.len);
    try std.testing.expectEqual(@as(u16, 6881), peers[0].address.getPort());
    try std.testing.expectEqual(@as(u16, 8080), peers[1].address.getPort());
}

test "decode announce response rejects short packet" {
    var buf: [19]u8 = undefined;
    try std.testing.expectError(error.PacketTooShort, AnnounceResponse.decode(&buf));
}

test "decode announce response rejects error action" {
    var buf: [20]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 3, .big); // error
    @memset(buf[4..], 0);
    try std.testing.expectError(error.TrackerError, AnnounceResponse.decode(&buf));
}

test "encode and decode scrape request single hash" {
    const info_hash = [_]u8{0xCC} ** 20;
    const buf = ScrapeRequest.encodeSingle(0x1122334455667788, 0xAABBCCDD, info_hash);

    try std.testing.expectEqual(@as(u64, 0x1122334455667788), std.mem.readInt(u64, buf[0..8], .big));
    try std.testing.expectEqual(@intFromEnum(Action.scrape), std.mem.readInt(u32, buf[8..12], .big));
    try std.testing.expectEqual(@as(u32, 0xAABBCCDD), std.mem.readInt(u32, buf[12..16], .big));
    try std.testing.expectEqualSlices(u8, &info_hash, buf[16..36]);
}

test "encode scrape request multiple hashes" {
    const hash1 = [_]u8{0xAA} ** 20;
    const hash2 = [_]u8{0xBB} ** 20;
    const hashes = [_][20]u8{ hash1, hash2 };
    var buf: [56]u8 = undefined;
    const encoded = try (ScrapeRequest{
        .connection_id = 0x1234,
        .transaction_id = 0x5678,
        .info_hashes = &hashes,
    }).encode(&buf);
    try std.testing.expectEqual(@as(usize, 56), encoded.len);
    try std.testing.expectEqualSlices(u8, &hash1, encoded[16..36]);
    try std.testing.expectEqualSlices(u8, &hash2, encoded[36..56]);
}

test "decode scrape response" {
    var buf: [20]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 2, .big); // action = scrape
    std.mem.writeInt(u32, buf[4..8], 0x11111111, .big); // transaction_id
    std.mem.writeInt(u32, buf[8..12], 42, .big); // seeders
    std.mem.writeInt(u32, buf[12..16], 100, .big); // completed
    std.mem.writeInt(u32, buf[16..20], 7, .big); // leechers

    const header = try ScrapeResponse.decodeHeader(&buf);
    try std.testing.expectEqual(Action.scrape, header.action);
    try std.testing.expectEqual(@as(u32, 0x11111111), header.transaction_id);

    const entry = try ScrapeResponse.parseEntry(header.entry_data, 0);
    try std.testing.expectEqual(@as(u32, 42), entry.seeders);
    try std.testing.expectEqual(@as(u32, 100), entry.completed);
    try std.testing.expectEqual(@as(u32, 7), entry.leechers);
}

test "decode scrape response rejects short packet" {
    var buf: [7]u8 = undefined;
    try std.testing.expectError(error.PacketTooShort, ScrapeResponse.decodeHeader(&buf));
}

test "decode error response" {
    const msg = "tracker is down";
    var buf: [8 + msg.len]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 3, .big); // action = error
    std.mem.writeInt(u32, buf[4..8], 0xDEAD, .big);
    @memcpy(buf[8..], msg);

    const err_resp = try ErrorResponse.decode(&buf);
    try std.testing.expectEqual(Action.@"error", err_resp.action);
    try std.testing.expectEqual(@as(u32, 0xDEAD), err_resp.transaction_id);
    try std.testing.expectEqualStrings(msg, err_resp.message);
}

test "error response detection" {
    var error_buf: [8]u8 = undefined;
    std.mem.writeInt(u32, error_buf[0..4], 3, .big);
    @memset(error_buf[4..], 0);
    try std.testing.expect(isErrorResponse(&error_buf));

    var connect_buf: [8]u8 = undefined;
    std.mem.writeInt(u32, connect_buf[0..4], 0, .big);
    @memset(connect_buf[4..], 0);
    try std.testing.expect(!isErrorResponse(&connect_buf));
}

test "event to UDP conversion" {
    try std.testing.expectEqual(UdpEvent.none, eventToUdp(null));
    try std.testing.expectEqual(UdpEvent.started, eventToUdp(.started));
    try std.testing.expectEqual(UdpEvent.completed, eventToUdp(.completed));
    try std.testing.expectEqual(UdpEvent.stopped, eventToUdp(.stopped));
}

test "retransmit timeout calculation" {
    // varuna sets max_retries=4 (faster failover than BEP 15's 8). The
    // test was originally written against the BEP 15 default; it has
    // been updated to track the production value. Changing the cap
    // here without changing `max_retries` would silently drift again.
    try std.testing.expectEqual(@as(u64, 15), retransmitTimeout(0));
    try std.testing.expectEqual(@as(u64, 30), retransmitTimeout(1));
    try std.testing.expectEqual(@as(u64, 60), retransmitTimeout(2));
    try std.testing.expectEqual(@as(u64, 120), retransmitTimeout(3));
    try std.testing.expectEqual(@as(u64, 240), retransmitTimeout(4));
    // Clamped at max_retries (4 -> 240 seconds).
    try std.testing.expectEqual(@as(u64, 240), retransmitTimeout(5));
    try std.testing.expectEqual(@as(u64, 240), retransmitTimeout(8));
    try std.testing.expectEqual(@as(u64, 240), retransmitTimeout(100));
}

test "connection cache basic operations" {
    var cache = ConnectionCache{};

    // Initially empty
    try std.testing.expect(cache.get("tracker.example.com", 6969) == null);

    // Put and retrieve
    cache.put("tracker.example.com", 6969, 0x1234567890ABCDEF);
    const id = cache.get("tracker.example.com", 6969);
    try std.testing.expect(id != null);
    try std.testing.expectEqual(@as(u64, 0x1234567890ABCDEF), id.?);

    // Different port returns null
    try std.testing.expect(cache.get("tracker.example.com", 6970) == null);

    // Different host returns null
    try std.testing.expect(cache.get("other.example.com", 6969) == null);
}

test "connection cache invalidation" {
    var cache = ConnectionCache{};
    cache.put("tracker.example.com", 6969, 0xAAAA);
    try std.testing.expect(cache.get("tracker.example.com", 6969) != null);

    cache.invalidate("tracker.example.com", 6969);
    try std.testing.expect(cache.get("tracker.example.com", 6969) == null);
}

test "connection cache update existing" {
    var cache = ConnectionCache{};
    cache.put("tracker.example.com", 6969, 0x1111);
    cache.put("tracker.example.com", 6969, 0x2222);

    const id = cache.get("tracker.example.com", 6969);
    try std.testing.expect(id != null);
    try std.testing.expectEqual(@as(u64, 0x2222), id.?);
}

test "parse compact peers from UDP response" {
    // 2 peers: 127.0.0.1:6881, 10.0.0.1:8080
    var data: [12]u8 = undefined;
    data[0] = 127;
    data[1] = 0;
    data[2] = 0;
    data[3] = 1;
    std.mem.writeInt(u16, data[4..6], 6881, .big);
    data[6] = 10;
    data[7] = 0;
    data[8] = 0;
    data[9] = 1;
    std.mem.writeInt(u16, data[10..12], 8080, .big);

    const peers = try parseCompactPeers(std.testing.allocator, &data);
    defer std.testing.allocator.free(peers);

    try std.testing.expectEqual(@as(usize, 2), peers.len);
    try std.testing.expectEqual(@as(u16, 6881), peers[0].address.getPort());
    try std.testing.expectEqual(@as(u16, 8080), peers[1].address.getPort());
}

test "parse compact peers rejects invalid length" {
    var data: [7]u8 = undefined; // not divisible by 6
    try std.testing.expectError(error.InvalidPeersField, parseCompactPeers(std.testing.allocator, &data));
}

test "parse compact peers empty" {
    const data: []const u8 = &.{};
    const peers = try parseCompactPeers(std.testing.allocator, data);
    defer std.testing.allocator.free(peers);
    try std.testing.expectEqual(@as(usize, 0), peers.len);
}

test "parse compact IPv6 peers" {
    // 1 peer: ::1 port 6881
    var data: [18]u8 = undefined;
    @memset(data[0..15], 0);
    data[15] = 1; // ::1
    std.mem.writeInt(u16, data[16..18], 6881, .big);

    const peers = try parseCompactPeers6(std.testing.allocator, &data);
    defer std.testing.allocator.free(peers);

    try std.testing.expectEqual(@as(usize, 1), peers.len);
    try std.testing.expectEqual(@as(u16, 6881), peers[0].address.getPort());
}

test "parse udp tracker url" {
    const parsed = parseUdpUrl("udp://tracker.example.com:6969/announce").?;
    try std.testing.expectEqualStrings("tracker.example.com", parsed.host);
    try std.testing.expectEqual(@as(u16, 6969), parsed.port);
}

test "parse udp url without path" {
    const parsed = parseUdpUrl("udp://tracker.example.com:1337").?;
    try std.testing.expectEqualStrings("tracker.example.com", parsed.host);
    try std.testing.expectEqual(@as(u16, 1337), parsed.port);
}

test "parse non-udp url returns null" {
    try std.testing.expect(parseUdpUrl("http://tracker.example.com:6969") == null);
}

test "url scheme detection" {
    try std.testing.expect(parseUdpUrl("udp://tracker:6969") != null);
    try std.testing.expect(parseUdpUrl("http://tracker:6969") == null);
    try std.testing.expect(parseUdpUrl("https://tracker:6969") == null);
    try std.testing.expect(parseUdpUrl("wss://tracker:6969") == null);
    try std.testing.expect(parseUdpUrl("") == null);
}

test "response action extraction" {
    var buf: [8]u8 = undefined;
    std.mem.writeInt(u32, buf[0..4], 0, .big);
    @memset(buf[4..], 0);
    try std.testing.expectEqual(Action.connect, responseAction(&buf).?);

    std.mem.writeInt(u32, buf[0..4], 1, .big);
    try std.testing.expectEqual(Action.announce, responseAction(&buf).?);

    std.mem.writeInt(u32, buf[0..4], 2, .big);
    try std.testing.expectEqual(Action.scrape, responseAction(&buf).?);

    std.mem.writeInt(u32, buf[0..4], 3, .big);
    try std.testing.expectEqual(Action.@"error", responseAction(&buf).?);

    // Too short
    try std.testing.expect(responseAction(&[_]u8{ 0, 0 }) == null);
}

test "response transaction id extraction" {
    var buf: [8]u8 = undefined;
    @memset(buf[0..4], 0);
    std.mem.writeInt(u32, buf[4..8], 0xCAFEBABE, .big);
    try std.testing.expectEqual(@as(u32, 0xCAFEBABE), responseTransactionId(&buf).?);

    // Too short
    try std.testing.expect(responseTransactionId(&[_]u8{ 0, 0, 0, 0, 0 }) == null);
}

test "full connect then announce packet flow" {
    // Simulate the full protocol exchange with mock buffers

    // 1. Client encodes connect request
    const connect_req = ConnectRequest{ .transaction_id = 42 };
    const connect_pkt = connect_req.encode();
    try std.testing.expectEqual(@as(usize, 16), connect_pkt.len);

    // 2. Server sends connect response
    var connect_resp_buf: [16]u8 = undefined;
    std.mem.writeInt(u32, connect_resp_buf[0..4], 0, .big);
    std.mem.writeInt(u32, connect_resp_buf[4..8], 42, .big);
    std.mem.writeInt(u64, connect_resp_buf[8..16], 0xDEADBEEFCAFE, .big);
    const connect_resp = try ConnectResponse.decode(&connect_resp_buf);
    try std.testing.expectEqual(@as(u32, 42), connect_resp.transaction_id);

    // 3. Client encodes announce request using connection ID
    const ann_req = AnnounceRequest{
        .connection_id = connect_resp.connection_id,
        .transaction_id = 43,
        .info_hash = [_]u8{0xFF} ** 20,
        .peer_id = [_]u8{0x00} ** 20,
        .downloaded = 0,
        .left = 1024 * 1024,
        .uploaded = 0,
        .event = .started,
        .ip = 0,
        .key = 12345,
        .num_want = 50,
        .port = 6881,
    };
    const ann_pkt = ann_req.encode();
    try std.testing.expectEqual(@as(usize, 98), ann_pkt.len);

    // 4. Server sends announce response with 1 peer
    var ann_resp_buf: [26]u8 = undefined;
    std.mem.writeInt(u32, ann_resp_buf[0..4], 1, .big); // announce
    std.mem.writeInt(u32, ann_resp_buf[4..8], 43, .big);
    std.mem.writeInt(u32, ann_resp_buf[8..12], 1800, .big); // interval
    std.mem.writeInt(u32, ann_resp_buf[12..16], 3, .big); // leechers
    std.mem.writeInt(u32, ann_resp_buf[16..20], 5, .big); // seeders
    ann_resp_buf[20] = 192;
    ann_resp_buf[21] = 168;
    ann_resp_buf[22] = 1;
    ann_resp_buf[23] = 100;
    std.mem.writeInt(u16, ann_resp_buf[24..26], 51413, .big);

    const ann_resp = try AnnounceResponse.decode(&ann_resp_buf);
    try std.testing.expectEqual(@as(u32, 43), ann_resp.transaction_id);
    try std.testing.expectEqual(@as(u32, 1800), ann_resp.interval);
    try std.testing.expectEqual(@as(u32, 5), ann_resp.seeders);
    try std.testing.expectEqual(@as(u32, 3), ann_resp.leechers);

    const peers = try ann_resp.parsePeers(std.testing.allocator);
    defer std.testing.allocator.free(peers);
    try std.testing.expectEqual(@as(usize, 1), peers.len);
    try std.testing.expectEqual(@as(u16, 51413), peers[0].address.getPort());
}

test "full connect then scrape packet flow" {
    // 1. Connect
    const connect_req = ConnectRequest{ .transaction_id = 100 };
    const connect_pkt = connect_req.encode();
    try std.testing.expectEqual(@as(usize, 16), connect_pkt.len);

    // 2. Server response
    var connect_resp_buf: [16]u8 = undefined;
    std.mem.writeInt(u32, connect_resp_buf[0..4], 0, .big);
    std.mem.writeInt(u32, connect_resp_buf[4..8], 100, .big);
    std.mem.writeInt(u64, connect_resp_buf[8..16], 0xBEEF, .big);
    const connect_resp = try ConnectResponse.decode(&connect_resp_buf);

    // 3. Scrape request
    const scrape_buf = ScrapeRequest.encodeSingle(connect_resp.connection_id, 101, [_]u8{0xDD} ** 20);
    try std.testing.expectEqual(@as(usize, 36), scrape_buf.len);

    // 4. Scrape response
    var scrape_resp_buf: [20]u8 = undefined;
    std.mem.writeInt(u32, scrape_resp_buf[0..4], 2, .big);
    std.mem.writeInt(u32, scrape_resp_buf[4..8], 101, .big);
    std.mem.writeInt(u32, scrape_resp_buf[8..12], 50, .big); // seeders
    std.mem.writeInt(u32, scrape_resp_buf[12..16], 200, .big); // completed
    std.mem.writeInt(u32, scrape_resp_buf[16..20], 10, .big); // leechers

    const header = try ScrapeResponse.decodeHeader(&scrape_resp_buf);
    try std.testing.expectEqual(@as(u32, 101), header.transaction_id);

    const entry = try ScrapeResponse.parseEntry(header.entry_data, 0);
    try std.testing.expectEqual(@as(u32, 50), entry.seeders);
    try std.testing.expectEqual(@as(u32, 200), entry.completed);
    try std.testing.expectEqual(@as(u32, 10), entry.leechers);
}

test "connection cache reuse skips connect" {
    var cache = ConnectionCache{};

    // First call: no cached ID
    try std.testing.expect(cache.get("tracker.example.com", 6969) == null);

    // Simulate a successful connect
    cache.put("tracker.example.com", 6969, 0xCAFEBABE);

    // Second call: cached ID available
    const id = cache.get("tracker.example.com", 6969);
    try std.testing.expect(id != null);
    try std.testing.expectEqual(@as(u64, 0xCAFEBABE), id.?);
}

test "transaction id is random" {
    const id1 = generateTransactionId();
    const id2 = generateTransactionId();
    // Not a guarantee, but extremely unlikely to be equal
    try std.testing.expect(id1 != id2);
}

test "announce request size is exactly 98 bytes" {
    const req = AnnounceRequest{
        .connection_id = 0,
        .transaction_id = 0,
        .info_hash = [_]u8{0} ** 20,
        .peer_id = [_]u8{0} ** 20,
        .downloaded = 0,
        .left = 0,
        .uploaded = 0,
        .event = .none,
        .ip = 0,
        .key = 0,
        .num_want = -1,
        .port = 0,
    };
    const buf = req.encode();
    try std.testing.expectEqual(@as(usize, 98), buf.len);
}

test "connect request size is exactly 16 bytes" {
    const req = ConnectRequest{ .transaction_id = 0 };
    const buf = req.encode();
    try std.testing.expectEqual(@as(usize, 16), buf.len);
}

test "scrape single request size is exactly 36 bytes" {
    const buf = ScrapeRequest.encodeSingle(0, 0, [_]u8{0} ** 20);
    try std.testing.expectEqual(@as(usize, 36), buf.len);
}
