const std = @import("std");
const log = std.log.scoped(.ban_list);

/// Thread-safe ban list for peer IP filtering.
/// Supports individual IP bans (O(1) lookup via hash map) and
/// CIDR range bans (O(log n) lookup via sorted arrays).
/// All addresses are normalized: IPv4-mapped IPv6 -> plain IPv4,
/// port numbers stripped.
pub const BanList = struct {
    allocator: std.mem.Allocator,

    /// Individual banned IPs. Key is a normalized address key (family tag + raw bytes).
    banned_ips: std.AutoHashMap(AddrKey, BanEntry),

    /// Sorted IPv4 ranges for binary-search matching.
    ipv4_ranges: std.ArrayList(Ipv4Range),

    /// Sorted IPv6 ranges for binary-search matching.
    ipv6_ranges: std.ArrayList(Ipv6Range),

    /// Generation counter, incremented on every mutation.
    generation: u64,

    /// Protects all mutable state for thread safety.
    mutex: std.Thread.Mutex,

    pub const BanSource = enum(u8) {
        manual = 0,
        ipfilter = 1,
    };

    pub const BanEntry = struct {
        source: BanSource,
        reason: ?[]const u8, // heap-allocated, optional comment
        created_at: i64, // unix timestamp
    };

    pub const Ipv4Range = struct {
        start: u32,
        end: u32,
        source: BanSource,
    };

    pub const Ipv6Range = struct {
        start: u128,
        end: u128,
        source: BanSource,
    };

    /// Compact key for the hash map: 1 byte family tag + up to 16 bytes address.
    /// IPv4: [4, a, b, c, d, 0, 0, ...] (17 bytes total)
    /// IPv6: [6, 16 bytes...]
    pub const AddrKey = [17]u8;

    pub const BanInfo = struct {
        ip_str: []const u8,
        source: BanSource,
        reason: ?[]const u8,
        created_at: i64,
    };

    pub const RangeInfo = struct {
        start_str: []const u8,
        end_str: []const u8,
        source: BanSource,
        created_at: i64,
    };

    pub fn init(allocator: std.mem.Allocator) BanList {
        return .{
            .allocator = allocator,
            .banned_ips = std.AutoHashMap(AddrKey, BanEntry).init(allocator),
            .ipv4_ranges = .empty,
            .ipv6_ranges = .empty,
            .generation = 0,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *BanList) void {
        // Free reason strings
        var it = self.banned_ips.valueIterator();
        while (it.next()) |entry| {
            if (entry.reason) |r| self.allocator.free(r);
        }
        self.banned_ips.deinit();
        self.ipv4_ranges.deinit(self.allocator);
        self.ipv6_ranges.deinit(self.allocator);
    }

    /// Check if an address is banned. Thread-safe.
    /// O(1) for individual IPs, O(log n) for CIDR ranges.
    pub fn isBanned(self: *BanList, addr: std.net.Address) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.isBannedUnlocked(addr);
    }

    /// Check without locking (caller holds mutex).
    fn isBannedUnlocked(self: *const BanList, addr: std.net.Address) bool {
        const key = addrToKey(addr);

        // O(1) individual check
        if (self.banned_ips.contains(key)) return true;

        // O(log n) range check
        if (key[0] == 4) {
            const ip = ipv4FromKey(key);
            return rangeContains(Ipv4Range, u32, self.ipv4_ranges.items, ip);
        } else if (key[0] == 6) {
            const ip = ipv6FromKey(key);
            return rangeContains(Ipv6Range, u128, self.ipv6_ranges.items, ip);
        }
        return false;
    }

    /// Add an individual IP ban. Returns true if newly added. Thread-safe.
    pub fn banIp(self: *BanList, addr: std.net.Address, reason: ?[]const u8, source: BanSource) !bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = addrToKey(addr);
        const gop = try self.banned_ips.getOrPut(key);
        if (gop.found_existing) {
            // Update reason if provided
            if (reason) |r| {
                if (gop.value_ptr.reason) |old_r| self.allocator.free(old_r);
                gop.value_ptr.reason = try self.allocator.dupe(u8, r);
            }
            return false;
        }

        gop.value_ptr.* = .{
            .source = source,
            .reason = if (reason) |r| try self.allocator.dupe(u8, r) else null,
            .created_at = std.time.timestamp(),
        };
        self.generation += 1;
        return true;
    }

    /// Add an individual IP ban from a canonical IP string. Thread-safe.
    pub fn banIpStr(self: *BanList, ip_str: []const u8, reason: ?[]const u8, source: BanSource, created_at: ?i64) !bool {
        const addr = parseIpStr(ip_str) orelse return error.InvalidAddress;

        self.mutex.lock();
        defer self.mutex.unlock();

        const key = addrToKey(addr);
        const gop = try self.banned_ips.getOrPut(key);
        if (gop.found_existing) return false;

        gop.value_ptr.* = .{
            .source = source,
            .reason = if (reason) |r| try self.allocator.dupe(u8, r) else null,
            .created_at = created_at orelse std.time.timestamp(),
        };
        self.generation += 1;
        return true;
    }

    /// Remove an individual IP ban. Returns true if it was present. Thread-safe.
    pub fn unbanIp(self: *BanList, addr: std.net.Address) bool {
        self.mutex.lock();
        defer self.mutex.unlock();

        const key = addrToKey(addr);
        if (self.banned_ips.fetchRemove(key)) |kv| {
            if (kv.value.reason) |r| self.allocator.free(r);
            self.generation += 1;
            return true;
        }
        return false;
    }

    /// Remove an individual IP ban by string. Returns true if it was present. Thread-safe.
    pub fn unbanIpStr(self: *BanList, ip_str: []const u8) bool {
        const addr = parseIpStr(ip_str) orelse return false;
        return self.unbanIp(addr);
    }

    /// Add a CIDR range ban (IPv4). Thread-safe.
    pub fn banRangeV4(self: *BanList, start: u32, end: u32, source: BanSource) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.ipv4_ranges.append(self.allocator, .{ .start = start, .end = end, .source = source });
        std.mem.sort(Ipv4Range, self.ipv4_ranges.items, {}, ipv4RangeLessThan);
        self.generation += 1;
    }

    /// Add a CIDR range ban (IPv6). Thread-safe.
    pub fn banRangeV6(self: *BanList, start: u128, end: u128, source: BanSource) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        try self.ipv6_ranges.append(self.allocator, .{ .start = start, .end = end, .source = source });
        std.mem.sort(Ipv6Range, self.ipv6_ranges.items, {}, ipv6RangeLessThan);
        self.generation += 1;
    }

    /// Add a CIDR range from string notation (e.g., "10.0.0.0/8"). Thread-safe.
    pub fn banCidr(self: *BanList, cidr_str: []const u8, source: BanSource) !void {
        const range = parseCidr(cidr_str) orelse return error.InvalidCidr;
        switch (range) {
            .v4 => |r| try self.banRangeV4(r.start, r.end, source),
            .v6 => |r| try self.banRangeV6(r.start, r.end, source),
        }
    }

    /// Remove all bans from a specific source. Thread-safe.
    pub fn clearSource(self: *BanList, source: BanSource) void {
        self.mutex.lock();
        defer self.mutex.unlock();

        // Remove individual IPs with matching source
        var to_remove = std.ArrayList(AddrKey).empty;
        defer to_remove.deinit(self.allocator);

        var it = self.banned_ips.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.source == source) {
                to_remove.append(self.allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (to_remove.items) |key| {
            if (self.banned_ips.fetchRemove(key)) |kv| {
                if (kv.value.reason) |r| self.allocator.free(r);
            }
        }

        // Remove ranges with matching source
        var i: usize = 0;
        while (i < self.ipv4_ranges.items.len) {
            if (self.ipv4_ranges.items[i].source == source) {
                _ = self.ipv4_ranges.orderedRemove(i);
            } else {
                i += 1;
            }
        }
        i = 0;
        while (i < self.ipv6_ranges.items.len) {
            if (self.ipv6_ranges.items[i].source == source) {
                _ = self.ipv6_ranges.orderedRemove(i);
            } else {
                i += 1;
            }
        }

        self.generation += 1;
    }

    /// Return a snapshot of all individual bans for API listing. Thread-safe.
    pub fn listBans(self: *BanList, allocator: std.mem.Allocator) ![]BanInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayList(BanInfo).empty;
        errdefer {
            for (result.items) |info| {
                allocator.free(info.ip_str);
                if (info.reason) |r| allocator.free(r);
            }
            result.deinit(allocator);
        }

        var it = self.banned_ips.iterator();
        while (it.next()) |entry| {
            const ip_str = keyToIpStr(allocator, entry.key_ptr.*) catch continue;
            errdefer allocator.free(ip_str);
            const reason_copy: ?[]const u8 = if (entry.value_ptr.reason) |r|
                allocator.dupe(u8, r) catch null
            else
                null;
            try result.append(allocator, .{
                .ip_str = ip_str,
                .source = entry.value_ptr.source,
                .reason = reason_copy,
                .created_at = entry.value_ptr.created_at,
            });
        }
        return result.toOwnedSlice(allocator);
    }

    /// Return a snapshot of all range bans for API listing. Thread-safe.
    pub fn listRanges(self: *BanList, allocator: std.mem.Allocator) ![]RangeInfo {
        self.mutex.lock();
        defer self.mutex.unlock();

        var result = std.ArrayList(RangeInfo).empty;
        errdefer {
            for (result.items) |info| {
                allocator.free(info.start_str);
                allocator.free(info.end_str);
            }
            result.deinit(allocator);
        }

        for (self.ipv4_ranges.items) |r| {
            const start_str = formatIpv4(allocator, r.start) catch continue;
            errdefer allocator.free(start_str);
            const end_str = formatIpv4(allocator, r.end) catch continue;
            try result.append(allocator, .{
                .start_str = start_str,
                .end_str = end_str,
                .source = r.source,
                .created_at = std.time.timestamp(),
            });
        }
        for (self.ipv6_ranges.items) |r| {
            const start_str = formatIpv6(allocator, r.start) catch continue;
            errdefer allocator.free(start_str);
            const end_str = formatIpv6(allocator, r.end) catch continue;
            try result.append(allocator, .{
                .start_str = start_str,
                .end_str = end_str,
                .source = r.source,
                .created_at = std.time.timestamp(),
            });
        }
        return result.toOwnedSlice(allocator);
    }

    /// Return count of total rules (individual + ranges). Thread-safe.
    pub fn ruleCount(self: *BanList) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.banned_ips.count() + self.ipv4_ranges.items.len + self.ipv6_ranges.items.len;
    }

    /// Return the newline-separated string of all manually banned IPs (for preferences).
    pub fn getBannedIpsString(self: *BanList, allocator: std.mem.Allocator) ![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();

        var buf = std.ArrayList(u8).empty;
        errdefer buf.deinit(allocator);

        var first = true;
        var it = self.banned_ips.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.source != .manual) continue;
            if (!first) try buf.append(allocator, '\n');
            const ip_str = keyToIpStr(allocator, entry.key_ptr.*) catch continue;
            defer allocator.free(ip_str);
            try buf.appendSlice(allocator, ip_str);
            first = false;
        }

        // Include CIDR ranges from manual source
        for (self.ipv4_ranges.items) |r| {
            if (r.source != .manual) continue;
            if (!first) try buf.append(allocator, '\n');
            const s = formatIpv4(allocator, r.start) catch continue;
            defer allocator.free(s);
            const e = formatIpv4(allocator, r.end) catch continue;
            defer allocator.free(e);
            // Try to express as CIDR if possible
            const cidr = rangeToCidrV4(r.start, r.end);
            if (cidr) |prefix_len| {
                try buf.writer(allocator).print("{s}/{}", .{ s, prefix_len });
            } else {
                try buf.writer(allocator).print("{s}-{s}", .{ s, e });
            }
            first = false;
        }

        return buf.toOwnedSlice(allocator);
    }

    /// Replace all manual bans with the ones from a newline-separated string (preferences SET).
    /// Each line is either an IP or a CIDR notation.
    pub fn setBannedIpsFromString(self: *BanList, input: []const u8) !void {
        // First, clear all manual bans
        self.clearSource(.manual);

        // Parse each line
        var line_iter = std.mem.splitScalar(u8, input, '\n');
        while (line_iter.next()) |line| {
            const trimmed = std.mem.trim(u8, line, " \t\r");
            if (trimmed.len == 0) continue;

            // Check if it's CIDR notation
            if (std.mem.indexOfScalar(u8, trimmed, '/') != null) {
                self.banCidr(trimmed, .manual) catch continue;
            } else {
                const addr = parseIpStr(trimmed) orelse continue;
                _ = self.banIp(addr, null, .manual) catch continue;
            }
        }
    }

    // ── Address normalization helpers ──────────────────────────

    /// Convert a std.net.Address to a normalized AddrKey.
    /// IPv4-mapped IPv6 (::ffff:x.x.x.x) is normalized to plain IPv4.
    pub fn addrToKey(addr: std.net.Address) AddrKey {
        var key: AddrKey = [_]u8{0} ** 17;
        switch (addr.any.family) {
            std.posix.AF.INET => {
                key[0] = 4;
                const bytes = @as(*const [4]u8, @ptrCast(&addr.in.sa.addr));
                @memcpy(key[1..5], bytes);
            },
            std.posix.AF.INET6 => {
                const bytes = &addr.in6.sa.addr;
                // Check for IPv4-mapped IPv6: ::ffff:x.x.x.x
                if (isIpv4Mapped(bytes)) {
                    key[0] = 4;
                    @memcpy(key[1..5], bytes[12..16]);
                } else {
                    key[0] = 6;
                    @memcpy(key[1..17], bytes);
                }
            },
            else => {
                key[0] = 0; // unknown family
            },
        }
        return key;
    }

    fn isIpv4Mapped(bytes: *const [16]u8) bool {
        // ::ffff:x.x.x.x = 10 zero bytes, then 0xff 0xff, then 4 IPv4 bytes
        for (bytes[0..10]) |b| {
            if (b != 0) return false;
        }
        return bytes[10] == 0xff and bytes[11] == 0xff;
    }

    fn ipv4FromKey(key: AddrKey) u32 {
        return std.mem.readInt(u32, key[1..5], .big);
    }

    fn ipv6FromKey(key: AddrKey) u128 {
        return std.mem.readInt(u128, key[1..17], .big);
    }

    /// Parse an IP string (v4 or v6) to a std.net.Address (port 0).
    pub fn parseIpStr(s: []const u8) ?std.net.Address {
        // Try IPv4 first
        if (std.net.Address.parseIp4(s, 0)) |addr| return addr else |_| {}
        // Try IPv6
        if (std.net.Address.parseIp6(s, 0)) |addr| return addr else |_| {}
        return null;
    }

    /// Convert an AddrKey back to a human-readable IP string.
    fn keyToIpStr(allocator: std.mem.Allocator, key: AddrKey) ![]const u8 {
        if (key[0] == 4) {
            const ip = std.mem.readInt(u32, key[1..5], .big);
            return formatIpv4(allocator, ip);
        } else if (key[0] == 6) {
            const ip = std.mem.readInt(u128, key[1..17], .big);
            return formatIpv6(allocator, ip);
        }
        return error.InvalidKey;
    }

    fn formatIpv4(allocator: std.mem.Allocator, ip: u32) ![]const u8 {
        return std.fmt.allocPrint(allocator, "{}.{}.{}.{}", .{
            @as(u8, @intCast((ip >> 24) & 0xff)),
            @as(u8, @intCast((ip >> 16) & 0xff)),
            @as(u8, @intCast((ip >> 8) & 0xff)),
            @as(u8, @intCast(ip & 0xff)),
        });
    }

    fn formatIpv6(allocator: std.mem.Allocator, ip: u128) ![]const u8 {
        var bytes: [16]u8 = undefined;
        std.mem.writeInt(u128, &bytes, ip, .big);
        // Simple format: full hex groups
        return std.fmt.allocPrint(allocator, "{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}:{x:0>4}", .{
            std.mem.readInt(u16, bytes[0..2], .big),
            std.mem.readInt(u16, bytes[2..4], .big),
            std.mem.readInt(u16, bytes[4..6], .big),
            std.mem.readInt(u16, bytes[6..8], .big),
            std.mem.readInt(u16, bytes[8..10], .big),
            std.mem.readInt(u16, bytes[10..12], .big),
            std.mem.readInt(u16, bytes[12..14], .big),
            std.mem.readInt(u16, bytes[14..16], .big),
        });
    }

    // ── CIDR parsing ──────────────────────────────────────────

    pub const CidrRange = union(enum) {
        v4: struct { start: u32, end: u32 },
        v6: struct { start: u128, end: u128 },
    };

    /// Parse CIDR notation (e.g., "10.0.0.0/8", "2001:db8::/32").
    pub fn parseCidr(s: []const u8) ?CidrRange {
        const slash_pos = std.mem.indexOfScalar(u8, s, '/') orelse return null;
        const ip_str = s[0..slash_pos];
        const prefix_str = s[slash_pos + 1 ..];
        const prefix_len = std.fmt.parseInt(u8, prefix_str, 10) catch return null;

        // Try IPv4
        if (std.net.Address.parseIp4(ip_str, 0)) |addr| {
            if (prefix_len > 32) return null;
            const ip = std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(&addr.in.sa.addr)), .big);
            if (prefix_len == 0) {
                return .{ .v4 = .{ .start = 0, .end = 0xFFFFFFFF } };
            }
            const mask: u32 = if (prefix_len == 32) 0xFFFFFFFF else ~(@as(u32, 0xFFFFFFFF) >> @intCast(prefix_len));
            const start = ip & mask;
            const end = start | ~mask;
            return .{ .v4 = .{ .start = start, .end = end } };
        } else |_| {}

        // Try IPv6
        if (std.net.Address.parseIp6(ip_str, 0)) |addr| {
            if (prefix_len > 128) return null;
            const ip = std.mem.readInt(u128, &addr.in6.sa.addr, .big);
            if (prefix_len == 0) {
                return .{ .v6 = .{ .start = 0, .end = @as(u128, 0) -% 1 } };
            }
            const mask: u128 = if (prefix_len == 128) @as(u128, 0) -% 1 else ~((@as(u128, 0) -% 1) >> @intCast(prefix_len));
            const start = ip & mask;
            const end = start | ~mask;
            return .{ .v6 = .{ .start = start, .end = end } };
        } else |_| {}

        return null;
    }

    /// Parse an IP range string ("start-end") into a CIDR range.
    pub fn parseRange(s: []const u8) ?CidrRange {
        const sep = std.mem.indexOf(u8, s, "-") orelse return null;
        const start_str = std.mem.trim(u8, s[0..sep], " ");
        const end_str = std.mem.trim(u8, s[sep + 1 ..], " ");

        // Try IPv4
        if (std.net.Address.parseIp4(start_str, 0)) |start_addr| {
            if (std.net.Address.parseIp4(end_str, 0)) |end_addr| {
                const start = std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(&start_addr.in.sa.addr)), .big);
                const end = std.mem.readInt(u32, @as(*const [4]u8, @ptrCast(&end_addr.in.sa.addr)), .big);
                return .{ .v4 = .{ .start = start, .end = end } };
            } else |_| {}
        } else |_| {}

        // Try IPv6
        if (std.net.Address.parseIp6(start_str, 0)) |start_addr| {
            if (std.net.Address.parseIp6(end_str, 0)) |end_addr| {
                const start = std.mem.readInt(u128, &start_addr.in6.sa.addr, .big);
                const end = std.mem.readInt(u128, &end_addr.in6.sa.addr, .big);
                return .{ .v6 = .{ .start = start, .end = end } };
            } else |_| {}
        } else |_| {}

        return null;
    }

    /// Try to express an IPv4 range as a CIDR prefix length, or null if not possible.
    fn rangeToCidrV4(start: u32, end: u32) ?u8 {
        const diff = end - start;
        // Check if diff+1 is a power of 2
        const size = diff +% 1;
        if (size == 0) return 0; // /0 covers everything
        if (size & (size - 1) != 0) return null; // not a power of 2
        // Check start is aligned
        if (start & diff != 0) return null;
        // Calculate prefix length
        var bits: u8 = 0;
        var s = size;
        while (s > 1) : (s >>= 1) bits += 1;
        return 32 - bits;
    }

    // ── Binary search for range matching ──────────────────────

    fn rangeContains(comptime Range: type, comptime Int: type, ranges: []const Range, ip: Int) bool {
        if (ranges.len == 0) return false;

        // Binary search: find the last range where start <= ip
        var lo: usize = 0;
        var hi: usize = ranges.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (ranges[mid].start <= ip) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        // lo is now the first range with start > ip
        // Check ranges[lo-1] if it exists
        if (lo == 0) return false;
        return ranges[lo - 1].end >= ip;
    }

    fn ipv4RangeLessThan(_: void, a: Ipv4Range, b: Ipv4Range) bool {
        return a.start < b.start;
    }

    fn ipv6RangeLessThan(_: void, a: Ipv6Range, b: Ipv6Range) bool {
        return a.start < b.start;
    }

    /// Parse an "ip:port" string, stripping the port. Handles IPv6 bracket notation.
    pub fn parseIpPort(s: []const u8) ?std.net.Address {
        // IPv6 bracket notation: [::1]:6881
        if (s.len > 0 and s[0] == '[') {
            if (std.mem.indexOf(u8, s, "]:")) |bracket_end| {
                return parseIpStr(s[1..bracket_end]);
            }
            // Just [::1] without port
            if (s[s.len - 1] == ']') {
                return parseIpStr(s[1 .. s.len - 1]);
            }
            return null;
        }
        // IPv4: ip:port
        if (std.mem.lastIndexOfScalar(u8, s, ':')) |colon| {
            // Make sure it's not an IPv6 address (which has multiple colons)
            if (std.mem.indexOfScalar(u8, s[0..colon], ':') != null) {
                // Multiple colons -- it's an IPv6 address without brackets
                return parseIpStr(s);
            }
            return parseIpStr(s[0..colon]);
        }
        // No port, just an IP
        return parseIpStr(s);
    }
};

// ── Tests ─────────────────────────────────────────────────

test "bans and unbans individual IPv4" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    const addr = std.net.Address.parseIp4("192.168.1.1", 0) catch unreachable;
    const added = try bl.banIp(addr, "bad peer", .manual);
    try std.testing.expect(added);
    try std.testing.expect(bl.isBanned(addr));

    // Adding again should return false
    const added2 = try bl.banIp(addr, null, .manual);
    try std.testing.expect(!added2);

    // Unban
    const removed = bl.unbanIp(addr);
    try std.testing.expect(removed);
    try std.testing.expect(!bl.isBanned(addr));

    // Unban again should return false
    const removed2 = bl.unbanIp(addr);
    try std.testing.expect(!removed2);
}

test "bans and unbans individual IPv6" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    const addr = std.net.Address.parseIp6("2001:db8::1", 0) catch unreachable;
    const added = try bl.banIp(addr, null, .manual);
    try std.testing.expect(added);
    try std.testing.expect(bl.isBanned(addr));

    const removed = bl.unbanIp(addr);
    try std.testing.expect(removed);
    try std.testing.expect(!bl.isBanned(addr));
}

test "normalizes IPv4-mapped IPv6" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    // Ban the IPv4 address
    const ipv4_addr = std.net.Address.parseIp4("1.2.3.4", 0) catch unreachable;
    _ = try bl.banIp(ipv4_addr, null, .manual);

    // Should be detected as banned when queried as IPv4-mapped IPv6
    const ipv6_mapped = std.net.Address.parseIp6("::ffff:1.2.3.4", 0) catch unreachable;
    try std.testing.expect(bl.isBanned(ipv6_mapped));
}

test "CIDR /8 range covers all addresses" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    try bl.banCidr("10.0.0.0/8", .manual);

    const addr1 = std.net.Address.parseIp4("10.0.0.1", 0) catch unreachable;
    const addr2 = std.net.Address.parseIp4("10.255.255.255", 0) catch unreachable;
    const addr3 = std.net.Address.parseIp4("11.0.0.1", 0) catch unreachable;

    try std.testing.expect(bl.isBanned(addr1));
    try std.testing.expect(bl.isBanned(addr2));
    try std.testing.expect(!bl.isBanned(addr3));
}

test "CIDR /32 is single IP" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    try bl.banCidr("192.168.1.100/32", .manual);

    const exact = std.net.Address.parseIp4("192.168.1.100", 0) catch unreachable;
    const other = std.net.Address.parseIp4("192.168.1.101", 0) catch unreachable;

    try std.testing.expect(bl.isBanned(exact));
    try std.testing.expect(!bl.isBanned(other));
}

test "CIDR /0 matches everything" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    try bl.banCidr("0.0.0.0/0", .manual);

    const addr1 = std.net.Address.parseIp4("1.1.1.1", 0) catch unreachable;
    const addr2 = std.net.Address.parseIp4("255.255.255.255", 0) catch unreachable;

    try std.testing.expect(bl.isBanned(addr1));
    try std.testing.expect(bl.isBanned(addr2));
}

test "CIDR /24 range correctness" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    try bl.banCidr("192.168.1.0/24", .manual);

    const inside = std.net.Address.parseIp4("192.168.1.200", 0) catch unreachable;
    const outside = std.net.Address.parseIp4("192.168.2.1", 0) catch unreachable;

    try std.testing.expect(bl.isBanned(inside));
    try std.testing.expect(!bl.isBanned(outside));
}

test "IPv6 CIDR range" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    try bl.banCidr("2001:db8::/32", .manual);

    const inside = std.net.Address.parseIp6("2001:db8::1", 0) catch unreachable;
    const outside = std.net.Address.parseIp6("2001:db9::1", 0) catch unreachable;

    try std.testing.expect(bl.isBanned(inside));
    try std.testing.expect(!bl.isBanned(outside));
}

test "clearSource removes only ipfilter entries" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    const manual_addr = std.net.Address.parseIp4("1.1.1.1", 0) catch unreachable;
    const ipfilter_addr = std.net.Address.parseIp4("2.2.2.2", 0) catch unreachable;

    _ = try bl.banIp(manual_addr, null, .manual);
    _ = try bl.banIp(ipfilter_addr, null, .ipfilter);
    try bl.banCidr("10.0.0.0/8", .ipfilter);
    try bl.banCidr("172.16.0.0/12", .manual);

    bl.clearSource(.ipfilter);

    try std.testing.expect(bl.isBanned(manual_addr));
    try std.testing.expect(!bl.isBanned(ipfilter_addr));

    // Manual CIDR should survive
    const in_manual_range = std.net.Address.parseIp4("172.16.0.1", 0) catch unreachable;
    try std.testing.expect(bl.isBanned(in_manual_range));

    // ipfilter CIDR should be gone
    const in_ipfilter_range = std.net.Address.parseIp4("10.0.0.1", 0) catch unreachable;
    try std.testing.expect(!bl.isBanned(in_ipfilter_range));
}

test "generation increments on mutation" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    const gen0 = bl.generation;

    const addr = std.net.Address.parseIp4("1.1.1.1", 0) catch unreachable;
    _ = try bl.banIp(addr, null, .manual);
    try std.testing.expect(bl.generation == gen0 + 1);

    _ = bl.unbanIp(addr);
    try std.testing.expect(bl.generation == gen0 + 2);
}

test "parseIpPort handles various formats" {
    // IPv4 with port
    const a1 = BanList.parseIpPort("192.168.1.1:6881");
    try std.testing.expect(a1 != null);

    // IPv6 with brackets and port
    const a2 = BanList.parseIpPort("[2001:db8::1]:6881");
    try std.testing.expect(a2 != null);

    // IPv4 without port
    const a3 = BanList.parseIpPort("192.168.1.1");
    try std.testing.expect(a3 != null);

    // Just an IPv6 address
    const a4 = BanList.parseIpPort("2001:db8::1");
    try std.testing.expect(a4 != null);
}

test "ruleCount returns total" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    try std.testing.expectEqual(@as(usize, 0), bl.ruleCount());

    const addr = std.net.Address.parseIp4("1.1.1.1", 0) catch unreachable;
    _ = try bl.banIp(addr, null, .manual);
    try bl.banCidr("10.0.0.0/8", .manual);

    try std.testing.expectEqual(@as(usize, 2), bl.ruleCount());
}

test "listBans returns snapshot" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    const addr = std.net.Address.parseIp4("192.168.1.1", 0) catch unreachable;
    _ = try bl.banIp(addr, "test reason", .manual);

    const bans = try bl.listBans(std.testing.allocator);
    defer {
        for (bans) |info| {
            std.testing.allocator.free(info.ip_str);
            if (info.reason) |r| std.testing.allocator.free(r);
        }
        std.testing.allocator.free(bans);
    }

    try std.testing.expectEqual(@as(usize, 1), bans.len);
    try std.testing.expectEqualStrings("192.168.1.1", bans[0].ip_str);
    try std.testing.expectEqualStrings("test reason", bans[0].reason.?);
}

test "setBannedIpsFromString replaces manual bans" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    // Add a manual ban
    const addr = std.net.Address.parseIp4("1.1.1.1", 0) catch unreachable;
    _ = try bl.banIp(addr, null, .manual);

    // Replace with new list
    try bl.setBannedIpsFromString("2.2.2.2\n10.0.0.0/8");

    // Old ban should be gone
    try std.testing.expect(!bl.isBanned(addr));

    // New bans should be active
    const new_addr = std.net.Address.parseIp4("2.2.2.2", 0) catch unreachable;
    try std.testing.expect(bl.isBanned(new_addr));

    const in_range = std.net.Address.parseIp4("10.0.0.1", 0) catch unreachable;
    try std.testing.expect(bl.isBanned(in_range));
}

test "individual and range interaction" {
    var bl = BanList.init(std.testing.allocator);
    defer bl.deinit();

    // Ban a range
    try bl.banCidr("10.0.0.0/24", .manual);

    // Also individually ban an IP in the range
    const addr = std.net.Address.parseIp4("10.0.0.5", 0) catch unreachable;
    _ = try bl.banIp(addr, null, .manual);

    // Should be banned (both ways)
    try std.testing.expect(bl.isBanned(addr));

    // Unban individual -- still banned by range
    _ = bl.unbanIp(addr);
    try std.testing.expect(bl.isBanned(addr));
}
