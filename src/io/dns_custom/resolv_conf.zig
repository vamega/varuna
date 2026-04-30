//! `/etc/resolv.conf` parser — minimal subset for the BitTorrent
//! workload.
//!
//! We only care about the `nameserver` directive (IPv4 or IPv6
//! addresses, one per line). `search`, `domain`, `options ndots`,
//! and `options timeout` / `options attempts` are ignored —
//! BitTorrent always uses FQDNs (trackers, web-seed URLs, DHT
//! bootstrap nodes), so search domains and ndots aren't needed.
//!
//! Comments (`#` or `;` to end of line) and blank lines are skipped.
//!
//! The parser is line-oriented and pure (operates on a slice). No
//! I/O is performed here; the caller reads the file via the IO
//! contract and passes the bytes in.
//!
//! See `docs/custom-dns-design.md` §3 (resolv.conf) for context.

const std = @import("std");

/// Maximum number of name-servers we will accept from resolv.conf.
/// glibc itself caps at 3 (`MAXNS` in resolv.h). We allow a few more
/// for hosts with multi-tunnel + per-link DNS configs without
/// blowing up if someone has a weird /etc/resolv.conf.
pub const max_nameservers: usize = 8;

/// Default fallback servers used if resolv.conf is missing or has no
/// `nameserver` lines. `127.0.0.53` is systemd-resolved's stub
/// listener; `8.8.8.8` is the universal "always works" fallback.
pub const fallback_servers = [_]std.net.Address{
    std.net.Address.initIp4(.{ 127, 0, 0, 53 }, 53),
    std.net.Address.initIp4(.{ 8, 8, 8, 8 }, 53),
};

pub const ResolvConf = struct {
    servers: [max_nameservers]std.net.Address = undefined,
    servers_len: u8 = 0,

    pub fn slice(self: *const ResolvConf) []const std.net.Address {
        return self.servers[0..self.servers_len];
    }

    pub fn empty(self: *const ResolvConf) bool {
        return self.servers_len == 0;
    }
};

/// Parse `/etc/resolv.conf` content (text). Returns a `ResolvConf`
/// populated from `nameserver` lines (up to `max_nameservers`).
/// Lines that fail to parse as IPv4 / IPv6 are silently skipped —
/// matches glibc's libresolv behavior.
pub fn parse(content: []const u8) ResolvConf {
    var rc: ResolvConf = .{};
    var line_iter = std.mem.splitScalar(u8, content, '\n');
    while (line_iter.next()) |raw_line| {
        var line = raw_line;
        // Strip CR (CRLF tolerance).
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        // Strip comment.
        if (std.mem.indexOfScalar(u8, line, '#')) |i| line = line[0..i];
        if (std.mem.indexOfScalar(u8, line, ';')) |i| line = line[0..i];
        line = std.mem.trim(u8, line, " \t");
        if (line.len == 0) continue;

        // Look for "nameserver <addr>".
        const directive = "nameserver";
        if (line.len <= directive.len) continue;
        if (!std.ascii.eqlIgnoreCase(line[0..directive.len], directive)) continue;
        // Next char must be whitespace.
        const sep = line[directive.len];
        if (sep != ' ' and sep != '\t') continue;

        const arg = std.mem.trim(u8, line[directive.len + 1 ..], " \t");
        if (arg.len == 0) continue;

        // Strip a possible IPv6 zone-id ("fe80::1%eth0" — we don't
        // honor zone-ids in DNS, just drop them so the parse
        // succeeds).
        const arg_stripped = blk: {
            if (std.mem.indexOfScalar(u8, arg, '%')) |i| break :blk arg[0..i];
            break :blk arg;
        };

        const addr = std.net.Address.parseIp(arg_stripped, 53) catch continue;

        if (rc.servers_len >= max_nameservers) break;
        rc.servers[rc.servers_len] = addr;
        rc.servers_len += 1;
    }
    return rc;
}

/// Best-effort load with fallback. Returns the parsed config if at
/// least one nameserver was found, else the fallback array.
///
/// **This helper uses `std.fs` and is intended for use during
/// resolver init only** — once running, the resolver should re-read
/// resolv.conf via the IO contract (see `resolver.zig`). The init-
/// time path is treated like other one-time setup operations
/// (matches how `PieceStore.init` opens files via `std.fs`).
pub fn loadFromFile(path: []const u8) ResolvConf {
    var file = std.fs.openFileAbsolute(path, .{}) catch return defaultFromFallback();
    defer file.close();

    var buf: [4096]u8 = undefined;
    const n = file.readAll(&buf) catch return defaultFromFallback();
    var rc = parse(buf[0..n]);
    if (rc.empty()) {
        rc = defaultFromFallback();
    }
    return rc;
}

fn defaultFromFallback() ResolvConf {
    var rc: ResolvConf = .{};
    for (fallback_servers) |srv| {
        if (rc.servers_len >= max_nameservers) break;
        rc.servers[rc.servers_len] = srv;
        rc.servers_len += 1;
    }
    return rc;
}

// ── Tests ────────────────────────────────────────────────

test "parse extracts a single IPv4 nameserver" {
    const text = "nameserver 1.2.3.4\n";
    const rc = parse(text);
    try std.testing.expectEqual(@as(u8, 1), rc.servers_len);
    try std.testing.expectEqual(@as(u16, 53), rc.servers[0].getPort());
    var buf: [32]u8 = undefined;
    const s = try std.fmt.bufPrint(&buf, "{f}", .{rc.servers[0]});
    try std.testing.expectEqualSlices(u8, "1.2.3.4:53", s);
}

test "parse extracts multiple nameservers in order" {
    const text =
        \\nameserver 8.8.8.8
        \\nameserver 1.1.1.1
        \\nameserver 9.9.9.9
        \\
    ;
    const rc = parse(text);
    try std.testing.expectEqual(@as(u8, 3), rc.servers_len);
    var b1: [32]u8 = undefined;
    var b2: [32]u8 = undefined;
    var b3: [32]u8 = undefined;
    try std.testing.expectEqualSlices(u8, "8.8.8.8:53", try std.fmt.bufPrint(&b1, "{f}", .{rc.servers[0]}));
    try std.testing.expectEqualSlices(u8, "1.1.1.1:53", try std.fmt.bufPrint(&b2, "{f}", .{rc.servers[1]}));
    try std.testing.expectEqualSlices(u8, "9.9.9.9:53", try std.fmt.bufPrint(&b3, "{f}", .{rc.servers[2]}));
}

test "parse accepts IPv6 nameserver" {
    const text = "nameserver 2001:4860:4860::8888\n";
    const rc = parse(text);
    try std.testing.expectEqual(@as(u8, 1), rc.servers_len);
    try std.testing.expectEqual(@as(u16, 53), rc.servers[0].getPort());
}

test "parse strips IPv6 zone id" {
    const text = "nameserver fe80::1%eth0\n";
    const rc = parse(text);
    try std.testing.expectEqual(@as(u8, 1), rc.servers_len);
}

test "parse skips comments and blank lines" {
    const text =
        \\# this is a comment
        \\
        \\nameserver 1.1.1.1
        \\; semicolon comment
        \\nameserver 1.0.0.1 # trailing
        \\
    ;
    const rc = parse(text);
    try std.testing.expectEqual(@as(u8, 2), rc.servers_len);
}

test "parse skips unrelated directives" {
    const text =
        \\domain example.com
        \\search example.com home.arpa
        \\options ndots:5 timeout:2
        \\nameserver 1.2.3.4
        \\
    ;
    const rc = parse(text);
    try std.testing.expectEqual(@as(u8, 1), rc.servers_len);
}

test "parse skips invalid IPs without failing the whole file" {
    const text =
        \\nameserver not-an-ip
        \\nameserver 999.999.999.999
        \\nameserver 1.2.3.4
        \\
    ;
    const rc = parse(text);
    try std.testing.expectEqual(@as(u8, 1), rc.servers_len);
}

test "parse caps at max_nameservers" {
    var buf: [1024]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var w = fbs.writer();
    var i: usize = 0;
    while (i < max_nameservers + 4) : (i += 1) {
        try w.print("nameserver 127.0.0.{d}\n", .{@as(u8, @intCast(i + 1))});
    }
    const rc = parse(buf[0..fbs.pos]);
    try std.testing.expectEqual(@as(u8, max_nameservers), rc.servers_len);
}

test "parse handles CRLF line endings" {
    const text = "nameserver 1.2.3.4\r\nnameserver 5.6.7.8\r\n";
    const rc = parse(text);
    try std.testing.expectEqual(@as(u8, 2), rc.servers_len);
}

test "parse rejects directive with no whitespace separator" {
    const text = "nameserver1.2.3.4\n";
    const rc = parse(text);
    try std.testing.expectEqual(@as(u8, 0), rc.servers_len);
}

test "parse handles tabs as separator" {
    const text = "nameserver\t1.2.3.4\n";
    const rc = parse(text);
    try std.testing.expectEqual(@as(u8, 1), rc.servers_len);
}

test "parse case-insensitive directive" {
    const text = "NameServer 1.2.3.4\n";
    const rc = parse(text);
    try std.testing.expectEqual(@as(u8, 1), rc.servers_len);
}

test "empty input yields empty config" {
    const rc = parse("");
    try std.testing.expect(rc.empty());
}

test "defaultFromFallback produces non-empty config" {
    const rc = defaultFromFallback();
    try std.testing.expect(!rc.empty());
    try std.testing.expectEqual(@as(usize, fallback_servers.len), rc.servers_len);
}
