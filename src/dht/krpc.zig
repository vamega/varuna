const std = @import("std");
const bencode = @import("../torrent/bencode.zig");
const bencode_encode = @import("../torrent/bencode_encode.zig");
const node_id = @import("node_id.zig");
const NodeId = node_id.NodeId;

/// KRPC message types (BEP 5).
pub const MessageType = enum { query, response, @"error" };

/// KRPC query methods.
pub const Method = enum {
    ping,
    find_node,
    get_peers,
    announce_peer,

    pub fn toString(self: Method) []const u8 {
        return switch (self) {
            .ping => "ping",
            .find_node => "find_node",
            .get_peers => "get_peers",
            .announce_peer => "announce_peer",
        };
    }

    pub fn fromString(s: []const u8) ?Method {
        if (std.mem.eql(u8, s, "ping")) return .ping;
        if (std.mem.eql(u8, s, "find_node")) return .find_node;
        if (std.mem.eql(u8, s, "get_peers")) return .get_peers;
        if (std.mem.eql(u8, s, "announce_peer")) return .announce_peer;
        return null;
    }
};

/// KRPC error codes (BEP 5).
pub const ErrorCode = enum(u32) {
    generic = 201,
    server = 202,
    protocol = 203,
    method_unknown = 204,
};

/// Parsed KRPC query.
pub const Query = struct {
    transaction_id: []const u8,
    method: Method,
    /// Querier's node ID (from "a" -> "id").
    sender_id: NodeId,
    /// Target for find_node / info_hash for get_peers/announce_peer.
    target: ?NodeId = null,
    /// Port for announce_peer.
    port: ?u16 = null,
    /// Token for announce_peer.
    token: ?[]const u8 = null,
    /// implied_port flag for announce_peer (BEP 5).
    implied_port: bool = false,
};

/// Parsed KRPC response.
pub const Response = struct {
    transaction_id: []const u8,
    sender_id: NodeId,
    /// Compact nodes info for IPv4 nodes (from "nodes" key, 26 bytes per entry).
    nodes: ?[]const u8 = null,
    /// Compact nodes info for IPv6 nodes (from "nodes6" key, BEP 32, 38 bytes per entry).
    nodes6: ?[]const u8 = null,
    /// Token (from get_peers response).
    token: ?[]const u8 = null,
    /// Raw bytes of the bencoded IPv4 "values" list (slice into original packet).
    /// Use this to extract compact peers without allocation.
    values_raw: ?[]const u8 = null,
    /// Raw bytes of the bencoded IPv6 "values6" list (BEP 32, 18 bytes per entry).
    values6_raw: ?[]const u8 = null,
};

/// Parsed KRPC error.
pub const Error = struct {
    transaction_id: []const u8,
    code: u32,
    message: []const u8,
};

/// A parsed KRPC message.
pub const Message = union(enum) {
    query: Query,
    response: Response,
    @"error": Error,
};

/// Parse a KRPC message from a raw bencode-encoded UDP datagram.
/// The returned slices reference the input data -- caller must keep
/// `data` alive while using the result.
pub fn parse(data: []const u8) !Message {
    // Manual parse: we don't need a full bencode.parse (which allocates).
    // Instead, do a zero-allocation parse by finding the key fields.
    // For simplicity, use the allocating parser with a throwaway allocator
    // is not ideal. Instead, parse manually using the raw bytes.
    //
    // Actually, for correctness and maintainability, we use a simple
    // approach: scan for the known keys in the top-level dictionary.
    // KRPC messages are small (< 1500 bytes UDP), so this is fine.

    if (data.len < 2 or data[0] != 'd') return error.InvalidKrpc;

    // Find "t" (transaction ID), "y" (type), "q" (method), "a"/"r"/"e" (body)
    var txn_id: ?[]const u8 = null;
    var msg_type: ?u8 = null;
    var method_str: ?[]const u8 = null;

    // Body dict position for extraction
    var a_dict_raw: ?[]const u8 = null;
    var r_dict_raw: ?[]const u8 = null;
    var e_list_raw: ?[]const u8 = null;

    var pos: usize = 1; // skip 'd'
    while (pos < data.len and data[pos] != 'e') {
        // Parse key (byte string)
        const key = parseByteString(data, &pos) orelse return error.InvalidKrpc;
        // Parse value
        if (std.mem.eql(u8, key, "t")) {
            txn_id = parseByteString(data, &pos) orelse return error.InvalidKrpc;
        } else if (std.mem.eql(u8, key, "y")) {
            const y = parseByteString(data, &pos) orelse return error.InvalidKrpc;
            if (y.len != 1) return error.InvalidKrpc;
            msg_type = y[0];
        } else if (std.mem.eql(u8, key, "q")) {
            method_str = parseByteString(data, &pos) orelse return error.InvalidKrpc;
        } else if (std.mem.eql(u8, key, "a")) {
            const start = pos;
            skipValue(data, &pos) orelse return error.InvalidKrpc;
            a_dict_raw = data[start..pos];
        } else if (std.mem.eql(u8, key, "r")) {
            const start = pos;
            skipValue(data, &pos) orelse return error.InvalidKrpc;
            r_dict_raw = data[start..pos];
        } else if (std.mem.eql(u8, key, "e")) {
            const start = pos;
            skipValue(data, &pos) orelse return error.InvalidKrpc;
            e_list_raw = data[start..pos];
        } else {
            // Skip unknown key's value
            skipValue(data, &pos) orelse return error.InvalidKrpc;
        }
    }

    const tid = txn_id orelse return error.InvalidKrpc;
    const mt = msg_type orelse return error.InvalidKrpc;

    switch (mt) {
        'q' => {
            const method = Method.fromString(method_str orelse return error.InvalidKrpc) orelse return error.InvalidKrpc;
            const a_raw = a_dict_raw orelse return error.InvalidKrpc;
            return .{ .query = try parseQuery(tid, method, a_raw) };
        },
        'r' => {
            const r_raw = r_dict_raw orelse return error.InvalidKrpc;
            return .{ .response = try parseResponse(tid, r_raw) };
        },
        'e' => {
            const e_raw = e_list_raw orelse return error.InvalidKrpc;
            return .{ .@"error" = try parseError(tid, e_raw) };
        },
        else => return error.InvalidKrpc,
    }
}

fn parseQuery(tid: []const u8, method: Method, a_raw: []const u8) !Query {
    var query = Query{
        .transaction_id = tid,
        .method = method,
        .sender_id = undefined,
    };

    if (a_raw.len < 2 or a_raw[0] != 'd') return error.InvalidKrpc;
    var pos: usize = 1;
    while (pos < a_raw.len and a_raw[pos] != 'e') {
        const key = parseByteString(a_raw, &pos) orelse return error.InvalidKrpc;
        if (std.mem.eql(u8, key, "id")) {
            const id = parseByteString(a_raw, &pos) orelse return error.InvalidKrpc;
            if (id.len != 20) return error.InvalidKrpc;
            @memcpy(&query.sender_id, id);
        } else if (std.mem.eql(u8, key, "target")) {
            const target = parseByteString(a_raw, &pos) orelse return error.InvalidKrpc;
            if (target.len != 20) return error.InvalidKrpc;
            var t: NodeId = undefined;
            @memcpy(&t, target);
            query.target = t;
        } else if (std.mem.eql(u8, key, "info_hash")) {
            const ih = parseByteString(a_raw, &pos) orelse return error.InvalidKrpc;
            if (ih.len != 20) return error.InvalidKrpc;
            var t: NodeId = undefined;
            @memcpy(&t, ih);
            query.target = t;
        } else if (std.mem.eql(u8, key, "port")) {
            const port_val = parseInteger(a_raw, &pos) orelse return error.InvalidKrpc;
            query.port = @intCast(@min(@max(port_val, 0), 65535));
        } else if (std.mem.eql(u8, key, "token")) {
            query.token = parseByteString(a_raw, &pos) orelse return error.InvalidKrpc;
        } else if (std.mem.eql(u8, key, "implied_port")) {
            const val = parseInteger(a_raw, &pos) orelse return error.InvalidKrpc;
            query.implied_port = val == 1;
        } else {
            skipValue(a_raw, &pos) orelse return error.InvalidKrpc;
        }
    }
    return query;
}

fn parseResponse(tid: []const u8, r_raw: []const u8) !Response {
    var resp = Response{
        .transaction_id = tid,
        .sender_id = undefined,
    };

    if (r_raw.len < 2 or r_raw[0] != 'd') return error.InvalidKrpc;
    var pos: usize = 1;
    while (pos < r_raw.len and r_raw[pos] != 'e') {
        const key = parseByteString(r_raw, &pos) orelse return error.InvalidKrpc;
        if (std.mem.eql(u8, key, "id")) {
            const id = parseByteString(r_raw, &pos) orelse return error.InvalidKrpc;
            if (id.len != 20) return error.InvalidKrpc;
            @memcpy(&resp.sender_id, id);
        } else if (std.mem.eql(u8, key, "nodes")) {
            resp.nodes = parseByteString(r_raw, &pos) orelse return error.InvalidKrpc;
        } else if (std.mem.eql(u8, key, "nodes6")) {
            // BEP 32: compact IPv6 node info (38 bytes each: 20 ID + 16 IP + 2 port)
            resp.nodes6 = parseByteString(r_raw, &pos) orelse return error.InvalidKrpc;
        } else if (std.mem.eql(u8, key, "token")) {
            resp.token = parseByteString(r_raw, &pos) orelse return error.InvalidKrpc;
        } else if (std.mem.eql(u8, key, "values")) {
            // "values" is a list of compact IPv4 peer strings (6 bytes each: 4B IP + 2B port)
            if (pos >= r_raw.len or r_raw[pos] != 'l') {
                skipValue(r_raw, &pos) orelse return error.InvalidKrpc;
                continue;
            }
            // Store the raw bencoded list so the caller can iterate without allocation.
            const list_start = pos;
            skipValue(r_raw, &pos) orelse return error.InvalidKrpc;
            resp.values_raw = r_raw[list_start..pos];
        } else if (std.mem.eql(u8, key, "values6")) {
            // BEP 32: list of compact IPv6 peer strings (18 bytes each: 16B IP + 2B port)
            if (pos >= r_raw.len or r_raw[pos] != 'l') {
                skipValue(r_raw, &pos) orelse return error.InvalidKrpc;
                continue;
            }
            const list_start = pos;
            skipValue(r_raw, &pos) orelse return error.InvalidKrpc;
            resp.values6_raw = r_raw[list_start..pos];
        } else {
            skipValue(r_raw, &pos) orelse return error.InvalidKrpc;
        }
    }
    return resp;
}

fn parseError(tid: []const u8, e_raw: []const u8) !Error {
    // Error is a list: [code, message]
    if (e_raw.len < 2 or e_raw[0] != 'l') return error.InvalidKrpc;
    var pos: usize = 1;
    const code = parseInteger(e_raw, &pos) orelse return error.InvalidKrpc;
    const msg = parseByteString(e_raw, &pos) orelse return error.InvalidKrpc;
    // Clamp to the documented u32 range. Without the upper bound the
    // `@intCast(i64 -> u32)` panicked on adversarial responses with
    // `code` larger than `maxInt(u32)`.
    const clamped: i64 = @max(@min(code, std.math.maxInt(u32)), 0);
    return .{
        .transaction_id = tid,
        .code = @intCast(clamped),
        .message = msg,
    };
}

// ── Zero-allocation bencode helpers ─────────────────────

fn parseByteString(data: []const u8, pos: *usize) ?[]const u8 {
    const start = pos.*;
    if (start >= data.len) return null;
    if (!std.ascii.isDigit(data[start])) return null;

    var i = start;
    // Bound the digit-prefix scan: a usize fits in at most 20 base-10
    // digits, so a length prefix longer than that cannot represent a
    // valid offset into a UDP datagram. Capping the scan also makes
    // `parseUnsigned` below trivially overflow-free.
    const max_len_digits: usize = 20;
    while (i < data.len and std.ascii.isDigit(data[i]) and (i - start) < max_len_digits) : (i += 1) {}
    if (i >= data.len or data[i] != ':') return null;

    const len = std.fmt.parseUnsigned(usize, data[start..i], 10) catch return null;
    i += 1; // skip ':'
    // Saturating-subtraction form: `len > data.len - i` is overflow-safe
    // because `i <= data.len` is invariant after the `data[i] != ':'`
    // guard above. The naive `i + len > data.len` form panicked under
    // adversarial inputs where `len` was near `maxInt(usize)` (Zig's
    // safe-mode integer-overflow trap).
    if (len > data.len - i) return null;
    pos.* = i + len;
    return data[i .. i + len];
}

fn parseInteger(data: []const u8, pos: *usize) ?i64 {
    if (pos.* >= data.len or data[pos.*] != 'i') return null;
    pos.* += 1;
    const start = pos.*;
    // i64 has at most 20 digits; allow 1 leading '-' for the negative
    // case (so 21 total). A digit run longer than that cannot represent
    // a valid i64 — bound the scan so we can't be made to spin on
    // adversarial multi-KB digit floods (each KRPC packet is bounded
    // by UDP MTU anyway, but the bound is also a clarity win).
    const max_int_chars: usize = 21;
    while (pos.* < data.len and data[pos.*] != 'e' and (pos.* - start) < max_int_chars) : (pos.* += 1) {}
    if (pos.* >= data.len or data[pos.*] != 'e') return null;
    const digits = data[start..pos.*];
    pos.* += 1; // skip 'e'
    return std.fmt.parseInt(i64, digits, 10) catch null;
}

fn skipValue(data: []const u8, pos: *usize) ?void {
    if (pos.* >= data.len) return null;
    switch (data[pos.*]) {
        'i' => {
            // Integer: i<digits>e
            pos.* += 1;
            while (pos.* < data.len and data[pos.*] != 'e') : (pos.* += 1) {}
            if (pos.* >= data.len) return null;
            pos.* += 1; // skip 'e'
        },
        'l' => {
            // List: l<values>e
            pos.* += 1;
            while (pos.* < data.len and data[pos.*] != 'e') {
                skipValue(data, pos) orelse return null;
            }
            if (pos.* >= data.len) return null;
            pos.* += 1; // skip 'e'
        },
        'd' => {
            // Dict: d<key><value>e
            pos.* += 1;
            while (pos.* < data.len and data[pos.*] != 'e') {
                _ = parseByteString(data, pos) orelse return null;
                skipValue(data, pos) orelse return null;
            }
            if (pos.* >= data.len) return null;
            pos.* += 1; // skip 'e'
        },
        '0'...'9' => {
            // Byte string
            _ = parseByteString(data, pos) orelse return null;
        },
        else => return null,
    }
}

// ── Encoding ────────────────────────────────────────────
//
// All encoders take a caller-supplied `buf: []u8` and return either
// `!usize` (the number of bytes written) or `error.NoSpaceLeft` if
// the buffer is too small. Every byte written is bounds-checked
// through the `Writer` helper below — no encoder ever writes past
// `buf.len`. This is hardened against the unsoundness that previously
// existed where `writeByteString`/`writeInteger` wrote directly into
// the slice without checking, panicking in Debug and triggering UB
// in Release.

const EncodeError = error{NoSpaceLeft};

/// Tiny bounds-checked write cursor over a caller-owned slice.
/// Centralizes the "every byte goes through a length check" invariant
/// for the encoder side. Composes well: pure data appends and bencode
/// envelope helpers (`byteString`, `integer`, `dictBegin`, `listBegin`,
/// `containerEnd`) share the same overflow-safe path.
const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    fn writeByte(self: *Writer, b: u8) EncodeError!void {
        // Fast path: pos is bounded by buf.len; +1 cannot overflow if
        // we check *before* incrementing.
        if (self.pos >= self.buf.len) return error.NoSpaceLeft;
        self.buf[self.pos] = b;
        self.pos += 1;
    }

    fn writeAll(self: *Writer, data: []const u8) EncodeError!void {
        // Saturating-subtraction form avoids any chance of `pos+len`
        // overflowing usize on adversarial-large `data.len`.
        // (`buf.len - pos` is safe because `pos <= buf.len` is an
        // invariant of every operation in this struct.)
        std.debug.assert(self.pos <= self.buf.len);
        if (data.len > self.buf.len - self.pos) return error.NoSpaceLeft;
        @memcpy(self.buf[self.pos..][0..data.len], data);
        self.pos += data.len;
    }

    fn byteString(self: *Writer, data: []const u8) EncodeError!void {
        // Ascii decimal length is at most 20 chars (u64 max in base 10).
        var len_buf: [20]u8 = undefined;
        const len_str = std.fmt.bufPrint(&len_buf, "{d}", .{data.len}) catch unreachable;
        try self.writeAll(len_str);
        try self.writeByte(':');
        try self.writeAll(data);
    }

    fn integer(self: *Writer, value: i64) EncodeError!void {
        try self.writeByte('i');
        var num_buf: [20]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "{d}", .{value}) catch unreachable;
        try self.writeAll(num_str);
        try self.writeByte('e');
    }

    fn dictBegin(self: *Writer) EncodeError!void {
        try self.writeByte('d');
    }

    fn listBegin(self: *Writer) EncodeError!void {
        try self.writeByte('l');
    }

    fn containerEnd(self: *Writer) EncodeError!void {
        try self.writeByte('e');
    }
};

/// Encode a ping query.
pub fn encodePingQuery(buf: []u8, txn_id: u16, our_id: NodeId) EncodeError!usize {
    return encodeQuery(buf, txn_id, .ping, our_id, null, null, null, false);
}

/// Encode a find_node query.
pub fn encodeFindNodeQuery(buf: []u8, txn_id: u16, our_id: NodeId, target: NodeId) EncodeError!usize {
    return encodeQuery(buf, txn_id, .find_node, our_id, &target, null, null, false);
}

/// Encode a get_peers query.
pub fn encodeGetPeersQuery(buf: []u8, txn_id: u16, our_id: NodeId, info_hash: [20]u8) EncodeError!usize {
    return encodeQuery(buf, txn_id, .get_peers, our_id, &info_hash, null, null, false);
}

/// Encode an announce_peer query.
pub fn encodeAnnouncePeerQuery(
    buf: []u8,
    txn_id: u16,
    our_id: NodeId,
    info_hash: [20]u8,
    port: u16,
    token: []const u8,
    implied_port: bool,
) EncodeError!usize {
    return encodeQuery(buf, txn_id, .announce_peer, our_id, &info_hash, port, token, implied_port);
}

fn encodeQuery(
    buf: []u8,
    txn_id: u16,
    method: Method,
    our_id: NodeId,
    target_or_hash: ?*const [20]u8,
    port: ?u16,
    token: ?[]const u8,
    implied_port: bool,
) EncodeError!usize {
    var w = Writer{ .buf = buf };

    try w.dictBegin();

    // "a" dict
    try w.byteString("a");
    try w.dictBegin();

    // "id"
    try w.byteString("id");
    try w.byteString(&our_id);

    switch (method) {
        .announce_peer => {
            if (implied_port) {
                try w.byteString("implied_port");
                try w.integer(1);
            }
            if (target_or_hash) |th| {
                try w.byteString("info_hash");
                try w.byteString(th);
            }
            if (port) |p| {
                try w.byteString("port");
                try w.integer(@intCast(p));
            }
            if (token) |t| {
                try w.byteString("token");
                try w.byteString(t);
            }
        },
        .get_peers => {
            if (target_or_hash) |th| {
                try w.byteString("info_hash");
                try w.byteString(th);
            }
        },
        .find_node => {
            if (target_or_hash) |th| {
                try w.byteString("target");
                try w.byteString(th);
            }
        },
        .ping => {},
    }

    try w.containerEnd(); // end "a" dict

    // "q"
    try w.byteString("q");
    try w.byteString(method.toString());

    // "t"
    try w.byteString("t");
    var tid_bytes: [2]u8 = undefined;
    std.mem.writeInt(u16, &tid_bytes, txn_id, .big);
    try w.byteString(&tid_bytes);

    // "y"
    try w.byteString("y");
    try w.byteString("q");

    try w.containerEnd(); // end top dict

    return w.pos;
}

/// Encode a ping/find_node response.
pub fn encodePingResponse(buf: []u8, txn_id: []const u8, our_id: NodeId) EncodeError!usize {
    return encodeResponse(buf, txn_id, our_id, null, null, null);
}

/// Encode a find_node response with compact nodes.
pub fn encodeFindNodeResponse(buf: []u8, txn_id: []const u8, our_id: NodeId, nodes: []const u8) EncodeError!usize {
    return encodeResponse(buf, txn_id, our_id, nodes, null, null);
}

/// Encode a get_peers response with peers (values).
pub fn encodeGetPeersResponseValues(
    buf: []u8,
    txn_id: []const u8,
    our_id: NodeId,
    token: []const u8,
    values: []const [6]u8,
) EncodeError!usize {
    var w = Writer{ .buf = buf };
    try w.dictBegin();

    // "r" dict
    try w.byteString("r");
    try w.dictBegin();

    try w.byteString("id");
    try w.byteString(&our_id);

    try w.byteString("token");
    try w.byteString(token);

    try w.byteString("values");
    try w.listBegin();
    for (values) |v| {
        try w.byteString(&v);
    }
    try w.containerEnd();

    try w.containerEnd(); // end "r" dict

    // "t"
    try w.byteString("t");
    try w.byteString(txn_id);

    // "y"
    try w.byteString("y");
    try w.byteString("r");

    try w.containerEnd();

    return w.pos;
}

/// Encode a get_peers response with nodes (no peers found).
pub fn encodeGetPeersResponseNodes(
    buf: []u8,
    txn_id: []const u8,
    our_id: NodeId,
    token: []const u8,
    nodes: []const u8,
) EncodeError!usize {
    var w = Writer{ .buf = buf };
    try w.dictBegin();

    // "r" dict
    try w.byteString("r");
    try w.dictBegin();

    try w.byteString("id");
    try w.byteString(&our_id);

    try w.byteString("nodes");
    try w.byteString(nodes);

    try w.byteString("token");
    try w.byteString(token);

    try w.containerEnd(); // end "r" dict

    // "t"
    try w.byteString("t");
    try w.byteString(txn_id);

    // "y"
    try w.byteString("y");
    try w.byteString("r");

    try w.containerEnd();

    return w.pos;
}

fn encodeResponse(
    buf: []u8,
    txn_id: []const u8,
    our_id: NodeId,
    nodes: ?[]const u8,
    token: ?[]const u8,
    values: ?[]const [6]u8,
) EncodeError!usize {
    var w = Writer{ .buf = buf };
    try w.dictBegin();

    // "r" dict
    try w.byteString("r");
    try w.dictBegin();

    try w.byteString("id");
    try w.byteString(&our_id);

    if (nodes) |n| {
        try w.byteString("nodes");
        try w.byteString(n);
    }

    if (token) |t| {
        try w.byteString("token");
        try w.byteString(t);
    }

    if (values) |vals| {
        try w.byteString("values");
        try w.listBegin();
        for (vals) |v| {
            try w.byteString(&v);
        }
        try w.containerEnd();
    }

    try w.containerEnd(); // end "r" dict

    // "t"
    try w.byteString("t");
    try w.byteString(txn_id);

    // "y"
    try w.byteString("y");
    try w.byteString("r");

    try w.containerEnd();

    return w.pos;
}

/// Encode a KRPC error response.
pub fn encodeError(buf: []u8, txn_id: []const u8, code: u32, message: []const u8) EncodeError!usize {
    var w = Writer{ .buf = buf };
    try w.dictBegin();

    // "e" list [code, message]
    try w.byteString("e");
    try w.listBegin();
    try w.integer(@intCast(code));
    try w.byteString(message);
    try w.containerEnd();

    // "t"
    try w.byteString("t");
    try w.byteString(txn_id);

    // "y"
    try w.byteString("y");
    try w.byteString("e");

    try w.containerEnd();

    return w.pos;
}

// ── Tests ──────────────────────────────────────────────

test "encode and parse ping query roundtrip" {
    var buf: [512]u8 = undefined;
    var our_id: NodeId = undefined;
    @memset(&our_id, 0xAA);

    const len = try encodePingQuery(&buf, 0x1234, our_id);
    const msg = try parse(buf[0..len]);

    switch (msg) {
        .query => |q| {
            try std.testing.expectEqual(Method.ping, q.method);
            try std.testing.expectEqual(our_id, q.sender_id);
            try std.testing.expectEqual(@as(usize, 2), q.transaction_id.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "encode and parse find_node query roundtrip" {
    var buf: [512]u8 = undefined;
    var our_id: NodeId = undefined;
    @memset(&our_id, 0xBB);
    var target: NodeId = undefined;
    @memset(&target, 0xCC);

    const len = try encodeFindNodeQuery(&buf, 0x5678, our_id, target);
    const msg = try parse(buf[0..len]);

    switch (msg) {
        .query => |q| {
            try std.testing.expectEqual(Method.find_node, q.method);
            try std.testing.expectEqual(our_id, q.sender_id);
            try std.testing.expectEqual(target, q.target.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "encode and parse get_peers query roundtrip" {
    var buf: [512]u8 = undefined;
    var our_id: NodeId = undefined;
    @memset(&our_id, 0x11);
    var info_hash: [20]u8 = undefined;
    @memset(&info_hash, 0x22);

    const len = try encodeGetPeersQuery(&buf, 0xABCD, our_id, info_hash);
    const msg = try parse(buf[0..len]);

    switch (msg) {
        .query => |q| {
            try std.testing.expectEqual(Method.get_peers, q.method);
            try std.testing.expectEqual(our_id, q.sender_id);
            try std.testing.expectEqual(info_hash, q.target.?);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "encode and parse ping response roundtrip" {
    var buf: [512]u8 = undefined;
    var our_id: NodeId = undefined;
    @memset(&our_id, 0xDD);

    const tid = "ab";
    const len = try encodePingResponse(&buf, tid, our_id);
    const msg = try parse(buf[0..len]);

    switch (msg) {
        .response => |r| {
            try std.testing.expectEqual(our_id, r.sender_id);
            try std.testing.expectEqualStrings("ab", r.transaction_id);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "encode and parse error roundtrip" {
    var buf: [512]u8 = undefined;
    const tid = "zz";
    const len = try encodeError(&buf, tid, 201, "Generic Error");
    const msg = try parse(buf[0..len]);

    switch (msg) {
        .@"error" => |e| {
            try std.testing.expectEqual(@as(u32, 201), e.code);
            try std.testing.expectEqualStrings("Generic Error", e.message);
            try std.testing.expectEqualStrings("zz", e.transaction_id);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "encode and parse find_node response roundtrip" {
    var buf: [512]u8 = undefined;
    var our_id: NodeId = undefined;
    @memset(&our_id, 0xEE);

    // Create compact nodes data (2 nodes = 52 bytes)
    var nodes_data: [52]u8 = undefined;
    @memset(&nodes_data, 0x42);

    const tid = "xy";
    const len = try encodeFindNodeResponse(&buf, tid, our_id, &nodes_data);
    const msg = try parse(buf[0..len]);

    switch (msg) {
        .response => |r| {
            try std.testing.expectEqual(our_id, r.sender_id);
            try std.testing.expect(r.nodes != null);
            try std.testing.expectEqual(@as(usize, 52), r.nodes.?.len);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "parse rejects non-dict input" {
    const result = parse("i42e");
    try std.testing.expectError(error.InvalidKrpc, result);
}

test "parse rejects truncated input" {
    const result = parse("d");
    try std.testing.expectError(error.InvalidKrpc, result);
}
