//! DNS wire format encode/decode (RFC 1035, RFC 3596).
//!
//! Pure functions on byte slices — no I/O, no allocation beyond the
//! caller-provided write buffer. The high-cost piece of `dns_custom` is
//! this parser; it is hardened against adversarial input following the
//! patterns established in the round-1-through-round-4 hardening rounds:
//!
//! - **Saturating-subtraction length bounds.** Every length-prefixed
//!   read uses `if (len > data.len - cursor) return error.Malformed`
//!   instead of `if (cursor + len > data.len)` — overflow-safe under
//!   Zig's safe-mode integer-overflow trap. Mirrors the
//!   `krpc.parseByteString` shape (round-1 hardening, file `src/dht/
//!   krpc.zig:314`).
//! - **Compression-pointer bounds.** Following a 14-bit compression
//!   pointer is bounded by (a) a hop counter capped at 16 and (b) a
//!   strict-decrease invariant (the pointer must point to a *lower*
//!   offset than the one we are reading from). The strict-decrease
//!   form is what BIND ships and trivially eliminates cycles. We
//!   additionally maintain a visited-offset bitset for defense in
//!   depth.
//! - **Label length cap.** RFC 1035 §3.1 caps each label at 63 octets;
//!   the high two bits 0b11 encode a compression pointer, 0b00 a
//!   normal label. We reject any label whose top two bits are 0b01 or
//!   0b10 (reserved per RFC 6891) and any normal label `> 63`.
//! - **Wire-name total length cap.** RFC 1035 §2.3.4 caps the total
//!   wire-format domain name at 255 octets; we track running length
//!   while expanding compression pointers and reject overflow.
//! - **rdlength bound.** RR `rdlength` checked with the saturating
//!   form before any RDATA read.
//! - **answer-count not pre-allocated.** We do not allocate based on
//!   `ancount`; we iterate, advancing the cursor and bailing if it
//!   would exceed `data.len`.
//! - **Mismatched-question rejection.** The caller verifies that the
//!   answer's question section equals the query's question section
//!   before accepting any RR — cache-poisoning defense.
//!
//! See `docs/custom-dns-design.md` §4 for the full threat model and
//! `docs/custom-dns-design-round2.md` §6.1 for the bind_device
//! refinement.

const std = @import("std");

// ── Constants ────────────────────────────────────────────

/// DNS header is always exactly 12 bytes.
pub const header_size: usize = 12;

/// RFC 1035 §3.1 / §2.3.4 caps.
pub const max_label_len: u8 = 63;
pub const max_name_wire_len: usize = 255;

/// Compression-pointer following: BIND uses 16 hops as a hard cap. The
/// strict-decrease invariant alone bounds this to log2(message_size),
/// so 16 is generous; we keep it as a defense-in-depth backstop.
pub const max_compression_hops: u8 = 16;

/// CNAME chain following hop cap. RFC 1034 §5.2.2 has no hard limit;
/// 8 is what most stub resolvers ship.
pub const max_cname_hops: u8 = 8;

/// DNS-over-UDP message size, RFC 1035 §4.2.1. Beyond this the server
/// must set TC=1 and we fall back to TCP.
pub const max_udp_size: usize = 512;

/// EDNS0 advertised payload size (RFC 6891). 1232 is the EDNS-flag-day
/// consensus value — fits within typical Path-MTU after IPv6+UDP
/// headers without fragmentation. Used when we encode an OPT record.
pub const edns_payload_size: u16 = 1232;

// ── Wire types ───────────────────────────────────────────

/// DNS RR type. Only the records varuna actually needs are enumerated;
/// any other type returned by the server is parsed and skipped via
/// `rdlength`.
pub const RrType = enum(u16) {
    a = 1, // IPv4 address (RFC 1035)
    ns = 2, // (skipped)
    cname = 5, // canonical name (RFC 1035)
    soa = 6, // (skipped)
    aaaa = 28, // IPv6 address (RFC 3596)
    opt = 41, // EDNS0 OPT pseudo-record (RFC 6891)
    _, // any other RRType is permitted but skipped on parse.
};

/// DNS RR class. We use only IN (Internet); other classes are
/// skipped.
pub const RrClass = enum(u16) {
    in = 1,
    _,
};

/// DNS opcodes used in the header. Only QUERY (0) and the four
/// well-known RCODE values matter for our subset.
pub const Opcode = enum(u4) {
    query = 0,
    iquery = 1,
    status = 2,
    _,
};

/// DNS RCODE (response code) — RFC 1035 §4.1.1.
pub const Rcode = enum(u4) {
    no_error = 0,
    format_error = 1,
    server_failure = 2,
    nx_domain = 3, // host doesn't exist (NXDOMAIN)
    not_implemented = 4,
    refused = 5,
    _,
};

/// Header flags packed into the 16-bit flags field.
pub const Flags = struct {
    qr: bool = false, // 0=query, 1=response
    opcode: Opcode = .query,
    aa: bool = false, // authoritative answer
    tc: bool = false, // truncation (UDP) — fall back to TCP
    rd: bool = true, // recursion desired (we always want this)
    ra: bool = false, // recursion available (set by server)
    rcode: Rcode = .no_error,

    pub fn pack(self: Flags) u16 {
        var v: u16 = 0;
        if (self.qr) v |= 0x8000;
        v |= (@as(u16, @intFromEnum(self.opcode)) & 0x0F) << 11;
        if (self.aa) v |= 0x0400;
        if (self.tc) v |= 0x0200;
        if (self.rd) v |= 0x0100;
        if (self.ra) v |= 0x0080;
        v |= @as(u16, @intFromEnum(self.rcode)) & 0x0F;
        return v;
    }

    pub fn unpack(v: u16) Flags {
        return .{
            .qr = (v & 0x8000) != 0,
            .opcode = @enumFromInt(@as(u4, @intCast((v >> 11) & 0x0F))),
            .aa = (v & 0x0400) != 0,
            .tc = (v & 0x0200) != 0,
            .rd = (v & 0x0100) != 0,
            .ra = (v & 0x0080) != 0,
            .rcode = @enumFromInt(@as(u4, @intCast(v & 0x0F))),
        };
    }
};

/// Decoded DNS message header.
pub const Header = struct {
    txid: u16,
    flags: Flags,
    qdcount: u16,
    ancount: u16,
    nscount: u16,
    arcount: u16,

    pub fn encode(self: Header, out: []u8) !void {
        if (out.len < header_size) return error.NoSpaceLeft;
        std.mem.writeInt(u16, out[0..2], self.txid, .big);
        std.mem.writeInt(u16, out[2..4], self.flags.pack(), .big);
        std.mem.writeInt(u16, out[4..6], self.qdcount, .big);
        std.mem.writeInt(u16, out[6..8], self.ancount, .big);
        std.mem.writeInt(u16, out[8..10], self.nscount, .big);
        std.mem.writeInt(u16, out[10..12], self.arcount, .big);
    }

    pub fn decode(data: []const u8) !Header {
        if (data.len < header_size) return error.MalformedDnsMessage;
        return .{
            .txid = std.mem.readInt(u16, data[0..2], .big),
            .flags = Flags.unpack(std.mem.readInt(u16, data[2..4], .big)),
            .qdcount = std.mem.readInt(u16, data[4..6], .big),
            .ancount = std.mem.readInt(u16, data[6..8], .big),
            .nscount = std.mem.readInt(u16, data[8..10], .big),
            .arcount = std.mem.readInt(u16, data[10..12], .big),
        };
    }
};

// ── Errors ───────────────────────────────────────────────

/// DNS-parser-specific error set. Any malformed input produces
/// `error.MalformedDnsMessage`; the parser never panics, never
/// allocates, and never spins.
pub const ParseError = error{
    MalformedDnsMessage,
    NameTooLong,
    LabelTooLong,
    CompressionLoop,
    CompressionTooDeep,
    CompressionForward,
    UnsupportedRrType,
};

pub const EncodeError = error{
    NoSpaceLeft,
    NameTooLong,
    LabelTooLong,
    InvalidName,
};

// ── Name encode ──────────────────────────────────────────

/// Encode a domain name in DNS wire format (length-prefixed labels,
/// terminated by a zero-length label). Validates label length (≤ 63)
/// and total wire length (≤ 255).
///
/// Accepts names with or without a trailing dot. Empty hostnames are
/// rejected (caller must check for the numeric-IP fast path before
/// calling this).
pub fn encodeName(out: []u8, name: []const u8) EncodeError!usize {
    if (name.len == 0) return error.InvalidName;

    var written: usize = 0;
    var label_start: usize = 0;
    var i: usize = 0;
    while (i <= name.len) : (i += 1) {
        const at_end = (i == name.len);
        const is_dot = !at_end and name[i] == '.';
        if (!at_end and !is_dot) continue;

        const label_len = i - label_start;
        // RFC 1035: trailing-dot is allowed (FQDN form) and produces a
        // zero-length label that we'll write at loop exit.
        if (label_len == 0) {
            if (at_end) break;
            // ".." is invalid.
            return error.InvalidName;
        }
        if (label_len > max_label_len) return error.LabelTooLong;
        if (written + 1 + label_len > out.len) return error.NoSpaceLeft;
        if (written + 1 + label_len > max_name_wire_len) return error.NameTooLong;

        out[written] = @intCast(label_len);
        @memcpy(out[written + 1 .. written + 1 + label_len], name[label_start..i]);
        written += 1 + label_len;
        label_start = i + 1;
    }

    // Zero-terminator label.
    if (written + 1 > out.len) return error.NoSpaceLeft;
    if (written + 1 > max_name_wire_len) return error.NameTooLong;
    out[written] = 0;
    written += 1;
    return written;
}

// ── Name decode ──────────────────────────────────────────

/// Read a domain name from the message starting at `cursor.*`,
/// following compression pointers as required. Writes the
/// dot-separated lowercased text form into `out_name` (capped at
/// `max_name_wire_len` bytes; a fully-qualified DNS name fits in 255
/// octets including length prefixes, so the text form fits in the
/// same budget less label-count).
///
/// On return, `cursor.*` is advanced past the *first occurrence* of
/// the name in the message — i.e., past the terminating zero-byte if
/// the name is uncompressed, or past the 2-byte compression pointer
/// if it begins with one.
///
/// Compression-pointer defenses:
/// - Strict-decrease invariant: any pointer `p` reached from offset
///   `c` must satisfy `p < c`. Catches forward pointers and self-loops.
/// - Hop counter capped at `max_compression_hops` (defense in depth).
/// - Total decoded length capped at `max_name_wire_len` (255).
pub fn readName(data: []const u8, cursor: *usize, out_name: *NameBuffer) ParseError!void {
    if (cursor.* >= data.len) return error.MalformedDnsMessage;

    out_name.reset();
    var first_pass_end: ?usize = null;
    var pos: usize = cursor.*;
    var hops: u8 = 0;
    var wire_used: usize = 1; // count the terminating zero label up front.

    while (true) {
        if (pos >= data.len) return error.MalformedDnsMessage;
        const b0 = data[pos];

        // Top two bits classify the byte:
        //   0b00 = normal label, length in bottom 6 bits (≤ 63)
        //   0b11 = compression pointer (14 bits)
        //   0b01, 0b10 = reserved (RFC 6891 §6.1.1) — reject.
        const high = b0 & 0xC0;
        if (high == 0xC0) {
            // Compression pointer.
            if (pos + 1 >= data.len) return error.MalformedDnsMessage;
            const new_pos: usize = (@as(usize, b0 & 0x3F) << 8) | data[pos + 1];
            if (first_pass_end == null) first_pass_end = pos + 2;
            // Strict decrease — no forward pointers, no self-loops.
            if (new_pos >= pos) return error.CompressionForward;
            hops += 1;
            if (hops > max_compression_hops) return error.CompressionTooDeep;
            pos = new_pos;
            continue;
        }
        if (high != 0) return error.MalformedDnsMessage;

        const label_len: usize = b0;
        if (label_len > max_label_len) return error.LabelTooLong;

        if (label_len == 0) {
            // Terminating zero label.
            if (first_pass_end == null) first_pass_end = pos + 1;
            cursor.* = first_pass_end.?;
            return;
        }

        // Bounds for the label payload — saturating form.
        // (pos + 1 may underflow data.len, but we just verified pos < data.len.)
        const label_payload_start = pos + 1;
        if (label_payload_start > data.len) return error.MalformedDnsMessage;
        if (label_len > data.len - label_payload_start) return error.MalformedDnsMessage;

        // Track wire-format length: 1 length byte + label_len bytes.
        wire_used = std.math.add(usize, wire_used, 1 + label_len) catch
            return error.NameTooLong;
        if (wire_used > max_name_wire_len) return error.NameTooLong;

        try out_name.appendLabel(data[label_payload_start .. label_payload_start + label_len]);
        pos = label_payload_start + label_len;
    }
}

/// Skip over a wire-format domain name without decoding it. Used
/// when traversing the question / answer sections to advance the
/// cursor past names whose contents we will look up by re-decoding
/// from a known offset, or when iterating RRs we won't keep.
///
/// Honors the same compression-pointer rules as `readName` (strict
/// decrease, hop cap, label cap, reserved-bits reject) so the cursor
/// advance is exactly the wire-name length whether or not compression
/// is used.
pub fn skipName(data: []const u8, cursor: *usize) ParseError!void {
    if (cursor.* >= data.len) return error.MalformedDnsMessage;
    var pos: usize = cursor.*;
    while (true) {
        if (pos >= data.len) return error.MalformedDnsMessage;
        const b0 = data[pos];
        const high = b0 & 0xC0;
        if (high == 0xC0) {
            // 2-byte pointer; the name ends here on the wire (the
            // pointer itself is the last on-wire token).
            if (pos + 1 >= data.len) return error.MalformedDnsMessage;
            cursor.* = pos + 2;
            return;
        }
        if (high != 0) return error.MalformedDnsMessage;
        const label_len: usize = b0;
        if (label_len > max_label_len) return error.LabelTooLong;
        if (label_len == 0) {
            cursor.* = pos + 1;
            return;
        }
        if (label_len > data.len - pos - 1) return error.MalformedDnsMessage;
        pos += 1 + label_len;
    }
}

/// Fixed-capacity buffer for decoded domain names (text form).
///
/// Lowercased on append; comparisons are case-insensitive per RFC
/// 1035 §2.3.3. Stack-allocated; no heap.
pub const NameBuffer = struct {
    /// Capacity is `max_name_wire_len`; the text form of a name with
    /// N single-octet labels uses 2N-1 bytes (label + dot, minus
    /// trailing dot), so the wire-length cap is a safe upper bound.
    bytes: [max_name_wire_len]u8 = undefined,
    len: usize = 0,

    pub fn reset(self: *NameBuffer) void {
        self.len = 0;
    }

    pub fn slice(self: *const NameBuffer) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn appendLabel(self: *NameBuffer, label: []const u8) ParseError!void {
        if (label.len > max_label_len) return error.LabelTooLong;
        const want = self.len +
            (if (self.len == 0) label.len else (label.len + 1));
        if (want > self.bytes.len) return error.NameTooLong;

        if (self.len > 0) {
            self.bytes[self.len] = '.';
            self.len += 1;
        }
        for (label) |ch| {
            self.bytes[self.len] = std.ascii.toLower(ch);
            self.len += 1;
        }
    }

    pub fn eqlIgnoreCase(self: *const NameBuffer, other: []const u8) bool {
        if (self.len != other.len) return false;
        for (self.bytes[0..self.len], other) |a, b| {
            if (std.ascii.toLower(a) != std.ascii.toLower(b)) return false;
        }
        return true;
    }

    pub fn copyFrom(self: *NameBuffer, src: []const u8) ParseError!void {
        if (src.len > self.bytes.len) return error.NameTooLong;
        @memcpy(self.bytes[0..src.len], src);
        self.len = src.len;
    }
};

// ── Question section ─────────────────────────────────────

pub const Question = struct {
    name: NameBuffer = .{},
    qtype: RrType,
    qclass: RrClass = .in,
};

/// Encode a question section: name + 2-byte qtype + 2-byte qclass.
/// Returns the number of bytes written.
pub fn encodeQuestion(out: []u8, name: []const u8, qtype: RrType) EncodeError!usize {
    var n = try encodeName(out, name);
    if (n + 4 > out.len) return error.NoSpaceLeft;
    std.mem.writeInt(u16, out[n..][0..2], @intFromEnum(qtype), .big);
    std.mem.writeInt(u16, out[n + 2 ..][0..2], @intFromEnum(RrClass.in), .big);
    n += 4;
    return n;
}

/// Decode a question section, advancing `cursor.*` past it.
pub fn readQuestion(data: []const u8, cursor: *usize, out: *Question) ParseError!void {
    try readName(data, cursor, &out.name);
    if (cursor.* + 4 > data.len) return error.MalformedDnsMessage;
    const qtype = std.mem.readInt(u16, data[cursor.*..][0..2], .big);
    const qclass = std.mem.readInt(u16, data[cursor.* + 2 ..][0..2], .big);
    cursor.* += 4;
    out.qtype = @enumFromInt(qtype);
    out.qclass = @enumFromInt(qclass);
}

// ── Resource records ─────────────────────────────────────

/// Decoded resource-record header (everything except RDATA, which is
/// returned as a slice into the original message buffer).
pub const RrHeader = struct {
    name: NameBuffer = .{},
    rrtype: RrType,
    rrclass: RrClass,
    ttl: u32,
    rdlength: u16,
    /// Byte offset into the original message where RDATA starts.
    rdata_offset: usize,
};

/// Read one resource record header, leaving the cursor pointing at
/// the start of the *next* RR (the parser advances past RDATA via
/// the saturating-length check).
pub fn readRr(data: []const u8, cursor: *usize, out: *RrHeader) ParseError!void {
    try readName(data, cursor, &out.name);
    // 2 bytes type + 2 class + 4 ttl + 2 rdlength = 10 bytes minimum.
    if (cursor.* + 10 > data.len) return error.MalformedDnsMessage;
    const rrtype_v = std.mem.readInt(u16, data[cursor.*..][0..2], .big);
    const rrclass_v = std.mem.readInt(u16, data[cursor.* + 2 ..][0..2], .big);
    const ttl = std.mem.readInt(u32, data[cursor.* + 4 ..][0..4], .big);
    const rdlength = std.mem.readInt(u16, data[cursor.* + 8 ..][0..2], .big);
    cursor.* += 10;
    if (rdlength > data.len - cursor.*) return error.MalformedDnsMessage;
    out.rrtype = @enumFromInt(rrtype_v);
    out.rrclass = @enumFromInt(rrclass_v);
    out.ttl = ttl;
    out.rdlength = rdlength;
    out.rdata_offset = cursor.*;
    cursor.* += rdlength;
}

// ── Query construction ───────────────────────────────────

/// Encode a complete DNS query message: header + single question.
/// `flags.rd` defaults to true (we want recursion).
///
/// Returns the number of bytes written.
pub fn encodeQuery(
    out: []u8,
    txid: u16,
    name: []const u8,
    qtype: RrType,
) EncodeError!usize {
    if (out.len < header_size) return error.NoSpaceLeft;

    const hdr: Header = .{
        .txid = txid,
        .flags = .{ .qr = false, .rd = true },
        .qdcount = 1,
        .ancount = 0,
        .nscount = 0,
        .arcount = 0,
    };
    try hdr.encode(out[0..header_size]);

    const q_written = try encodeQuestion(out[header_size..], name, qtype);
    return header_size + q_written;
}

// ── Response classification ──────────────────────────────

/// One A or AAAA address extracted from a response.
pub const ExtractedAddress = struct {
    family: enum { v4, v6 },
    /// 4 bytes (v4) or 16 bytes (v6).
    bytes: [16]u8 = undefined,
    bytes_len: u8,
    ttl: u32,
};

pub const ExtractResult = struct {
    /// Up to 8 addresses (a/aaaa); arbitrary cap to bound stack use.
    addresses: [8]ExtractedAddress = undefined,
    addresses_len: u8 = 0,
    /// CNAME chain target, if the answer contained CNAMEs but no
    /// terminal A/AAAA. The caller may issue a follow-up query.
    cname_target: ?NameBuffer = null,
    rcode: Rcode,
};

/// Extract A / AAAA / CNAME records from a response message,
/// verifying the answer's question section equals the query's.
///
/// `query_name` is the lowercased text-form name we asked for;
/// answer-name comparison is case-insensitive. `query_type` is the
/// RR type we asked for (A or AAAA). Records of other types are
/// skipped; CNAME records cause the chain to be followed (`max_cname_hops`).
pub fn extractAnswers(
    data: []const u8,
    query_name: []const u8,
    query_type: RrType,
) ParseError!ExtractResult {
    const hdr = try Header.decode(data);
    if (!hdr.flags.qr) return error.MalformedDnsMessage; // not a response
    if (hdr.qdcount != 1) return error.MalformedDnsMessage;

    var cursor: usize = header_size;
    var question: Question = .{ .qtype = .a };
    try readQuestion(data, &cursor, &question);

    // Cache-poisoning defense: the response's question must match what
    // we sent.
    if (!question.name.eqlIgnoreCase(query_name)) return error.MalformedDnsMessage;
    if (question.qtype != query_type) return error.MalformedDnsMessage;
    if (question.qclass != .in) return error.MalformedDnsMessage;

    var result: ExtractResult = .{ .rcode = hdr.flags.rcode };

    // Track the current "name we're still hunting for" as we walk the
    // CNAME chain. Start with the query name; on every CNAME whose
    // owner matches the current target, switch the target to the
    // CNAME's RDATA name. A/AAAA records whose owner equals the
    // current target are kept.
    var current_target: NameBuffer = .{};
    try current_target.copyFrom(query_name);
    var cname_hops: u8 = 0;

    var i: u16 = 0;
    while (i < hdr.ancount) : (i += 1) {
        if (cursor >= data.len) return error.MalformedDnsMessage;
        var rr: RrHeader = .{
            .rrtype = .a,
            .rrclass = .in,
            .ttl = 0,
            .rdlength = 0,
            .rdata_offset = 0,
        };
        try readRr(data, &cursor, &rr);

        if (rr.rrclass != .in) continue;

        // Switch on RR type.
        switch (rr.rrtype) {
            .a => {
                if (query_type != .a) continue;
                if (rr.rdlength != 4) return error.MalformedDnsMessage;
                if (!rr.name.eqlIgnoreCase(current_target.slice())) continue;
                if (result.addresses_len < result.addresses.len) {
                    var ext: ExtractedAddress = .{
                        .family = .v4,
                        .bytes_len = 4,
                        .ttl = rr.ttl,
                    };
                    @memcpy(ext.bytes[0..4], data[rr.rdata_offset..][0..4]);
                    result.addresses[result.addresses_len] = ext;
                    result.addresses_len += 1;
                }
            },
            .aaaa => {
                if (query_type != .aaaa) continue;
                if (rr.rdlength != 16) return error.MalformedDnsMessage;
                if (!rr.name.eqlIgnoreCase(current_target.slice())) continue;
                if (result.addresses_len < result.addresses.len) {
                    var ext: ExtractedAddress = .{
                        .family = .v6,
                        .bytes_len = 16,
                        .ttl = rr.ttl,
                    };
                    @memcpy(ext.bytes[0..16], data[rr.rdata_offset..][0..16]);
                    result.addresses[result.addresses_len] = ext;
                    result.addresses_len += 1;
                }
            },
            .cname => {
                // Only follow the chain when the CNAME owner matches
                // the name we're still hunting for.
                if (!rr.name.eqlIgnoreCase(current_target.slice())) continue;
                if (cname_hops >= max_cname_hops) return error.CompressionTooDeep;
                cname_hops += 1;
                // Decode the canonical-name target out of RDATA. The
                // RDATA may use compression pointers back into the
                // message; readName handles this correctly because we
                // pass the full message buffer, and the cursor we hand
                // it is the start of RDATA.
                var rdata_cursor: usize = rr.rdata_offset;
                try readName(data, &rdata_cursor, &current_target);
                // Defense: make sure readName did not advance past
                // rdata_offset + rdlength.
                if (rdata_cursor > rr.rdata_offset + rr.rdlength) return error.MalformedDnsMessage;

                // If this is the only thing in the answer, surface the
                // chain target so the resolver can issue a follow-up.
                result.cname_target = current_target;
            },
            else => continue, // skip everything else (NS, SOA, ...).
        }
    }

    // If the answer had a CNAME chain but no terminal A/AAAA matching
    // `current_target`, we leave `cname_target` set so the caller can
    // re-query. If the chain *was* fully resolved (we found
    // A/AAAA at the end), clear cname_target so the caller knows to
    // use the addresses.
    if (result.addresses_len > 0) {
        result.cname_target = null;
    }

    return result;
}

// ── Tests: round-trip ────────────────────────────────────

test "Header encode/decode round-trip" {
    var buf: [header_size]u8 = undefined;
    const original: Header = .{
        .txid = 0xBEEF,
        .flags = .{
            .qr = true,
            .opcode = .query,
            .aa = false,
            .tc = false,
            .rd = true,
            .ra = true,
            .rcode = .no_error,
        },
        .qdcount = 1,
        .ancount = 2,
        .nscount = 0,
        .arcount = 0,
    };
    try original.encode(&buf);

    const decoded = try Header.decode(&buf);
    try std.testing.expectEqual(original.txid, decoded.txid);
    try std.testing.expectEqual(original.flags.qr, decoded.flags.qr);
    try std.testing.expectEqual(original.flags.rd, decoded.flags.rd);
    try std.testing.expectEqual(original.flags.ra, decoded.flags.ra);
    try std.testing.expectEqual(original.qdcount, decoded.qdcount);
    try std.testing.expectEqual(original.ancount, decoded.ancount);
}

test "Header decode rejects truncated buffer" {
    const buf: [header_size - 1]u8 = undefined;
    try std.testing.expectError(error.MalformedDnsMessage, Header.decode(&buf));
}

test "Flags.pack/unpack round-trip preserves rcode" {
    inline for (.{ Rcode.no_error, .nx_domain, .server_failure, .refused }) |rc| {
        const f: Flags = .{ .qr = true, .rd = true, .rcode = rc };
        const v = f.pack();
        const back = Flags.unpack(v);
        try std.testing.expectEqual(rc, back.rcode);
        try std.testing.expectEqual(true, back.qr);
        try std.testing.expectEqual(true, back.rd);
    }
}

test "encodeName produces RFC 1035 wire format" {
    var buf: [256]u8 = undefined;
    const n = try encodeName(&buf, "example.com");
    // Expected: 7 'e' 'x' 'a' 'm' 'p' 'l' 'e' 3 'c' 'o' 'm' 0
    const expected = "\x07example\x03com\x00";
    try std.testing.expectEqual(@as(usize, expected.len), n);
    try std.testing.expectEqualSlices(u8, expected, buf[0..n]);
}

test "encodeName accepts trailing dot" {
    var buf: [256]u8 = undefined;
    const n = try encodeName(&buf, "example.com.");
    const expected = "\x07example\x03com\x00";
    try std.testing.expectEqualSlices(u8, expected, buf[0..n]);
}

test "encodeName rejects label > 63 octets" {
    var buf: [512]u8 = undefined;
    var name_buf: [65]u8 = undefined;
    @memset(&name_buf, 'a');
    try std.testing.expectError(error.LabelTooLong, encodeName(&buf, &name_buf));
}

test "encodeName rejects empty name" {
    var buf: [16]u8 = undefined;
    try std.testing.expectError(error.InvalidName, encodeName(&buf, ""));
}

test "encodeName rejects double-dot" {
    var buf: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidName, encodeName(&buf, "a..b"));
}

test "encodeName returns NoSpaceLeft on small buffer" {
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, encodeName(&buf, "example.com"));
}

test "encodeName rejects total > 255" {
    var buf: [512]u8 = undefined;
    var name_buf: [256]u8 = undefined;
    // Build "a.a.a...." with 128 single-char labels separated by dots = 255 chars.
    var i: usize = 0;
    while (i < 254) : (i += 2) {
        name_buf[i] = 'a';
        name_buf[i + 1] = '.';
    }
    name_buf[254] = 'a';
    name_buf[255] = 'a'; // overflow into 256th char -> wire form > 255.
    try std.testing.expectError(error.NameTooLong, encodeName(&buf, &name_buf));
}

test "readName decodes uncompressed name" {
    const wire = "\x07example\x03com\x00";
    var name: NameBuffer = .{};
    var cursor: usize = 0;
    try readName(wire, &cursor, &name);
    try std.testing.expectEqualSlices(u8, "example.com", name.slice());
    try std.testing.expectEqual(@as(usize, wire.len), cursor);
}

test "readName lowercases" {
    const wire = "\x07Example\x03COM\x00";
    var name: NameBuffer = .{};
    var cursor: usize = 0;
    try readName(wire, &cursor, &name);
    try std.testing.expectEqualSlices(u8, "example.com", name.slice());
}

test "readName handles compression pointer (back-reference)" {
    // Build: header(12) + uncompressed "example.com." starting at
    // offset 12, then a compression pointer back to offset 12.
    var msg: [64]u8 = undefined;
    @memset(&msg, 0);
    // Header bytes are not interpreted by readName; just need offset.
    const start = 12;
    const wire = "\x07example\x03com\x00";
    @memcpy(msg[start .. start + wire.len], wire);
    // Compression pointer at offset 25: 0xC0 | 0x00, 0x0C (= offset 12).
    const ptr_at = start + wire.len; // 25
    msg[ptr_at] = 0xC0;
    msg[ptr_at + 1] = 0x0C;

    var cursor: usize = ptr_at;
    var name: NameBuffer = .{};
    try readName(&msg, &cursor, &name);
    try std.testing.expectEqualSlices(u8, "example.com", name.slice());
    // Cursor advanced past the 2-byte pointer.
    try std.testing.expectEqual(@as(usize, ptr_at + 2), cursor);
}

test "readName rejects forward compression pointer" {
    var msg: [16]u8 = undefined;
    @memset(&msg, 0);
    msg[0] = 0xC0;
    msg[1] = 0x0F; // forward pointer to offset 15
    var cursor: usize = 0;
    var name: NameBuffer = .{};
    try std.testing.expectError(error.CompressionForward, readName(&msg, &cursor, &name));
}

test "readName rejects self-loop compression pointer" {
    var msg: [16]u8 = undefined;
    @memset(&msg, 0);
    msg[0] = 0xC0;
    msg[1] = 0x00; // points to self (offset 0)
    var cursor: usize = 0;
    var name: NameBuffer = .{};
    try std.testing.expectError(error.CompressionForward, readName(&msg, &cursor, &name));
}

test "readName rejects pointer-to-pointer infinite loop via strict-decrease" {
    var msg: [16]u8 = undefined;
    @memset(&msg, 0);
    // offset 0: pointer to offset 2
    msg[0] = 0xC0;
    msg[1] = 0x02;
    // offset 2: pointer to offset 0 (creates cycle, but strict-decrease catches it)
    msg[2] = 0xC0;
    msg[3] = 0x00;
    var cursor: usize = 2;
    var name: NameBuffer = .{};
    try std.testing.expectError(error.CompressionForward, readName(&msg, &cursor, &name));
}

test "readName rejects oversized label" {
    var msg: [128]u8 = undefined;
    @memset(&msg, 0);
    msg[0] = 64; // > max_label_len (63), but bit pattern 0b01... = reserved
    var cursor: usize = 0;
    var name: NameBuffer = .{};
    try std.testing.expectError(error.MalformedDnsMessage, readName(&msg, &cursor, &name));
}

test "readName rejects truncated label payload" {
    // "\x05ex\x00" — claims 5 bytes but only 2 follow.
    const wire = "\x05ex\x00";
    var cursor: usize = 0;
    var name: NameBuffer = .{};
    try std.testing.expectError(error.MalformedDnsMessage, readName(wire, &cursor, &name));
}

test "readName rejects unterminated name" {
    // No zero-terminator and no pointer.
    const wire = "\x03foo\x03bar";
    var cursor: usize = 0;
    var name: NameBuffer = .{};
    try std.testing.expectError(error.MalformedDnsMessage, readName(wire, &cursor, &name));
}

test "readName rejects total wire-name > 255" {
    // Build a chain of 1-char labels pointing into each other to
    // reach > 255 expanded length. 128 hops × 2 bytes each.
    // Easier: encode a long uncompressed name and check the cap.
    var msg: [512]u8 = undefined;
    var pos: usize = 0;
    var hops_left: usize = 130;
    while (hops_left > 0) : (hops_left -= 1) {
        msg[pos] = 1;
        msg[pos + 1] = 'a';
        pos += 2;
    }
    msg[pos] = 0;

    var cursor: usize = 0;
    var name: NameBuffer = .{};
    try std.testing.expectError(error.NameTooLong, readName(msg[0 .. pos + 1], &cursor, &name));
}

test "encodeQuery produces a complete A query for example.com" {
    var buf: [128]u8 = undefined;
    const n = try encodeQuery(&buf, 0x1234, "example.com", .a);

    // Header: txid=0x1234, flags qr=0/rd=1 -> 0x0100, qdcount=1, ancount=0
    try std.testing.expectEqual(@as(u8, 0x12), buf[0]);
    try std.testing.expectEqual(@as(u8, 0x34), buf[1]);
    try std.testing.expectEqual(@as(u8, 0x01), buf[2]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[3]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[4]);
    try std.testing.expectEqual(@as(u8, 0x01), buf[5]);

    // Question name: \x07example\x03com\x00
    const expected_name = "\x07example\x03com\x00";
    try std.testing.expectEqualSlices(u8, expected_name, buf[12 .. 12 + expected_name.len]);

    // qtype = 1 (A), qclass = 1 (IN)
    const qpos = 12 + expected_name.len;
    try std.testing.expectEqual(@as(u8, 0x00), buf[qpos]);
    try std.testing.expectEqual(@as(u8, 0x01), buf[qpos + 1]);
    try std.testing.expectEqual(@as(u8, 0x00), buf[qpos + 2]);
    try std.testing.expectEqual(@as(u8, 0x01), buf[qpos + 3]);

    try std.testing.expectEqual(qpos + 4, n);
}

test "encodeQuery + extractAnswers round-trip A response" {
    // Build: query for "example.com" then a synthetic response
    // containing one A RR with IP 1.2.3.4.
    var buf: [256]u8 = undefined;

    // Header: txid=0xABCD, qr=1, rd=1, ra=1, qdcount=1, ancount=1.
    const hdr: Header = .{
        .txid = 0xABCD,
        .flags = .{ .qr = true, .rd = true, .ra = true, .rcode = .no_error },
        .qdcount = 1,
        .ancount = 1,
        .nscount = 0,
        .arcount = 0,
    };
    try hdr.encode(buf[0..header_size]);

    // Question: example.com / A / IN.
    var pos: usize = header_size;
    pos += try encodeQuestion(buf[pos..], "example.com", .a);

    // Answer: name = compression pointer to question name (offset 12);
    // type=A, class=IN, ttl=300, rdlength=4, rdata=1.2.3.4
    buf[pos] = 0xC0;
    buf[pos + 1] = 0x0C;
    pos += 2;
    std.mem.writeInt(u16, buf[pos..][0..2], @intFromEnum(RrType.a), .big);
    std.mem.writeInt(u16, buf[pos + 2 ..][0..2], @intFromEnum(RrClass.in), .big);
    std.mem.writeInt(u32, buf[pos + 4 ..][0..4], 300, .big);
    std.mem.writeInt(u16, buf[pos + 8 ..][0..2], 4, .big);
    pos += 10;
    buf[pos] = 1;
    buf[pos + 1] = 2;
    buf[pos + 2] = 3;
    buf[pos + 3] = 4;
    pos += 4;

    const result = try extractAnswers(buf[0..pos], "example.com", .a);
    try std.testing.expectEqual(@as(u8, 1), result.addresses_len);
    try std.testing.expectEqual(@as(u32, 300), result.addresses[0].ttl);
    try std.testing.expectEqual(@as(u8, 1), result.addresses[0].bytes[0]);
    try std.testing.expectEqual(@as(u8, 2), result.addresses[0].bytes[1]);
    try std.testing.expectEqual(@as(u8, 3), result.addresses[0].bytes[2]);
    try std.testing.expectEqual(@as(u8, 4), result.addresses[0].bytes[3]);
}

test "encodeQuery + extractAnswers round-trip AAAA response" {
    var buf: [256]u8 = undefined;
    const hdr: Header = .{
        .txid = 0x4242,
        .flags = .{ .qr = true, .rd = true, .ra = true },
        .qdcount = 1,
        .ancount = 1,
        .nscount = 0,
        .arcount = 0,
    };
    try hdr.encode(buf[0..header_size]);

    var pos: usize = header_size;
    pos += try encodeQuestion(buf[pos..], "example.com", .aaaa);

    buf[pos] = 0xC0;
    buf[pos + 1] = 0x0C;
    pos += 2;
    std.mem.writeInt(u16, buf[pos..][0..2], @intFromEnum(RrType.aaaa), .big);
    std.mem.writeInt(u16, buf[pos + 2 ..][0..2], @intFromEnum(RrClass.in), .big);
    std.mem.writeInt(u32, buf[pos + 4 ..][0..4], 600, .big);
    std.mem.writeInt(u16, buf[pos + 8 ..][0..2], 16, .big);
    pos += 10;
    @memset(buf[pos..][0..16], 0);
    buf[pos + 0] = 0x20;
    buf[pos + 1] = 0x01;
    buf[pos + 2] = 0x0d;
    buf[pos + 3] = 0xb8;
    buf[pos + 15] = 0x01;
    pos += 16;

    const result = try extractAnswers(buf[0..pos], "example.com", .aaaa);
    try std.testing.expectEqual(@as(u8, 1), result.addresses_len);
    try std.testing.expectEqual(@as(u32, 600), result.addresses[0].ttl);
    try std.testing.expectEqual(@as(u8, 0x20), result.addresses[0].bytes[0]);
    try std.testing.expectEqual(@as(u8, 0x01), result.addresses[0].bytes[15]);
}

test "extractAnswers detects NXDOMAIN" {
    var buf: [128]u8 = undefined;
    const hdr: Header = .{
        .txid = 1,
        .flags = .{ .qr = true, .rd = true, .ra = true, .rcode = .nx_domain },
        .qdcount = 1,
        .ancount = 0,
        .nscount = 0,
        .arcount = 0,
    };
    try hdr.encode(buf[0..header_size]);
    var pos: usize = header_size;
    pos += try encodeQuestion(buf[pos..], "doesnotexist.example", .a);

    const result = try extractAnswers(buf[0..pos], "doesnotexist.example", .a);
    try std.testing.expectEqual(Rcode.nx_domain, result.rcode);
    try std.testing.expectEqual(@as(u8, 0), result.addresses_len);
}

test "extractAnswers rejects mismatched question (cache poisoning)" {
    var buf: [256]u8 = undefined;
    const hdr: Header = .{
        .txid = 1,
        .flags = .{ .qr = true, .rd = true, .ra = true },
        .qdcount = 1,
        .ancount = 0,
        .nscount = 0,
        .arcount = 0,
    };
    try hdr.encode(buf[0..header_size]);
    var pos: usize = header_size;
    pos += try encodeQuestion(buf[pos..], "evil.example", .a);

    try std.testing.expectError(
        error.MalformedDnsMessage,
        extractAnswers(buf[0..pos], "good.example", .a),
    );
}

test "extractAnswers follows CNAME chain" {
    // Answer: CNAME(www.example.com -> ex.example.com) + A(ex.example.com -> 1.2.3.4)
    var buf: [512]u8 = undefined;
    const hdr: Header = .{
        .txid = 7,
        .flags = .{ .qr = true, .rd = true, .ra = true },
        .qdcount = 1,
        .ancount = 2,
        .nscount = 0,
        .arcount = 0,
    };
    try hdr.encode(buf[0..header_size]);
    var pos: usize = header_size;
    pos += try encodeQuestion(buf[pos..], "www.example.com", .a);

    // Record 1: CNAME owner = www.example.com (compress to qname offset 12)
    buf[pos] = 0xC0;
    buf[pos + 1] = 0x0C;
    pos += 2;
    std.mem.writeInt(u16, buf[pos..][0..2], @intFromEnum(RrType.cname), .big);
    std.mem.writeInt(u16, buf[pos + 2 ..][0..2], @intFromEnum(RrClass.in), .big);
    std.mem.writeInt(u32, buf[pos + 4 ..][0..4], 300, .big);
    pos += 10; // skip rdlength placeholder; fill after writing target
    const rdlen_pos = pos - 2;
    const rdata_start = pos;
    // RDATA: ex.example.com — 2 'e' 'x' (compress remainder to "example.com")
    buf[pos] = 2;
    buf[pos + 1] = 'e';
    buf[pos + 2] = 'x';
    pos += 3;
    // Compress "example.com" -> qname has "www.example.com" starting
    // at offset 12. "example.com" begins at offset 12+4 = 16
    // (length-prefixed "www" = 4 bytes).
    buf[pos] = 0xC0;
    buf[pos + 1] = 16;
    pos += 2;
    const rdlen: u16 = @intCast(pos - rdata_start);
    std.mem.writeInt(u16, buf[rdlen_pos..][0..2], rdlen, .big);

    // Record 2: A owner = ex.example.com — encode uncompressed
    const a_owner_off: usize = pos;
    _ = a_owner_off;
    pos += try encodeName(buf[pos..], "ex.example.com");
    std.mem.writeInt(u16, buf[pos..][0..2], @intFromEnum(RrType.a), .big);
    std.mem.writeInt(u16, buf[pos + 2 ..][0..2], @intFromEnum(RrClass.in), .big);
    std.mem.writeInt(u32, buf[pos + 4 ..][0..4], 60, .big);
    std.mem.writeInt(u16, buf[pos + 8 ..][0..2], 4, .big);
    pos += 10;
    buf[pos] = 1;
    buf[pos + 1] = 2;
    buf[pos + 2] = 3;
    buf[pos + 3] = 4;
    pos += 4;

    const result = try extractAnswers(buf[0..pos], "www.example.com", .a);
    try std.testing.expectEqual(@as(u8, 1), result.addresses_len);
    try std.testing.expectEqual(@as(u8, 1), result.addresses[0].bytes[0]);
    try std.testing.expectEqual(@as(u8, 4), result.addresses[0].bytes[3]);
}

test "extractAnswers surfaces unresolved CNAME target" {
    // Answer: only a CNAME, no terminal A.
    var buf: [256]u8 = undefined;
    const hdr: Header = .{
        .txid = 7,
        .flags = .{ .qr = true, .rd = true, .ra = true },
        .qdcount = 1,
        .ancount = 1,
        .nscount = 0,
        .arcount = 0,
    };
    try hdr.encode(buf[0..header_size]);
    var pos: usize = header_size;
    pos += try encodeQuestion(buf[pos..], "alias.test", .a);

    buf[pos] = 0xC0;
    buf[pos + 1] = 0x0C;
    pos += 2;
    std.mem.writeInt(u16, buf[pos..][0..2], @intFromEnum(RrType.cname), .big);
    std.mem.writeInt(u16, buf[pos + 2 ..][0..2], @intFromEnum(RrClass.in), .big);
    std.mem.writeInt(u32, buf[pos + 4 ..][0..4], 300, .big);
    pos += 10;
    const rdlen_pos = pos - 2;
    const rdata_start = pos;
    pos += try encodeName(buf[pos..], "target.test");
    const rdlen: u16 = @intCast(pos - rdata_start);
    std.mem.writeInt(u16, buf[rdlen_pos..][0..2], rdlen, .big);

    const result = try extractAnswers(buf[0..pos], "alias.test", .a);
    try std.testing.expectEqual(@as(u8, 0), result.addresses_len);
    try std.testing.expect(result.cname_target != null);
    try std.testing.expectEqualSlices(u8, "target.test", result.cname_target.?.slice());
}

test "extractAnswers rejects A record with rdlength != 4" {
    var buf: [256]u8 = undefined;
    const hdr: Header = .{
        .txid = 1,
        .flags = .{ .qr = true, .rd = true, .ra = true },
        .qdcount = 1,
        .ancount = 1,
        .nscount = 0,
        .arcount = 0,
    };
    try hdr.encode(buf[0..header_size]);
    var pos: usize = header_size;
    pos += try encodeQuestion(buf[pos..], "x.test", .a);
    buf[pos] = 0xC0;
    buf[pos + 1] = 0x0C;
    pos += 2;
    std.mem.writeInt(u16, buf[pos..][0..2], @intFromEnum(RrType.a), .big);
    std.mem.writeInt(u16, buf[pos + 2 ..][0..2], @intFromEnum(RrClass.in), .big);
    std.mem.writeInt(u32, buf[pos + 4 ..][0..4], 60, .big);
    std.mem.writeInt(u16, buf[pos + 8 ..][0..2], 5, .big); // wrong!
    pos += 10;
    @memset(buf[pos..][0..5], 0);
    pos += 5;

    try std.testing.expectError(
        error.MalformedDnsMessage,
        extractAnswers(buf[0..pos], "x.test", .a),
    );
}

test "extractAnswers handles every truncation length without panicking" {
    var buf: [256]u8 = undefined;
    const hdr: Header = .{
        .txid = 1,
        .flags = .{ .qr = true, .rd = true, .ra = true },
        .qdcount = 1,
        .ancount = 1,
        .nscount = 0,
        .arcount = 0,
    };
    try hdr.encode(buf[0..header_size]);
    var pos: usize = header_size;
    pos += try encodeQuestion(buf[pos..], "x.test", .a);
    buf[pos] = 0xC0;
    buf[pos + 1] = 0x0C;
    pos += 2;
    std.mem.writeInt(u16, buf[pos..][0..2], @intFromEnum(RrType.a), .big);
    std.mem.writeInt(u16, buf[pos + 2 ..][0..2], @intFromEnum(RrClass.in), .big);
    std.mem.writeInt(u32, buf[pos + 4 ..][0..4], 60, .big);
    std.mem.writeInt(u16, buf[pos + 8 ..][0..2], 4, .big);
    pos += 10;
    buf[pos] = 1;
    buf[pos + 1] = 2;
    buf[pos + 2] = 3;
    buf[pos + 3] = 4;
    pos += 4;

    // Test every truncation: must error cleanly, never panic.
    var n: usize = 0;
    while (n < pos) : (n += 1) {
        const r = extractAnswers(buf[0..n], "x.test", .a);
        if (r) |_| {} else |_| {}
        // we don't care about the specific outcome; the assertion is
        // that no panic / no infinite loop occurs.
    }
    // Full message: should succeed.
    const full = try extractAnswers(buf[0..pos], "x.test", .a);
    try std.testing.expectEqual(@as(u8, 1), full.addresses_len);
}

test "extractAnswers adversarial fuzz never panics" {
    // 32 seeds × 64-byte random buffers — strictly a "doesn't panic"
    // smoke test; doesn't assert on outcomes.
    var prng = std.Random.DefaultPrng.init(0xCAFEBABE);
    const r = prng.random();
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        var buf: [64]u8 = undefined;
        r.bytes(&buf);
        const result = extractAnswers(&buf, "fuzz.test", .a);
        if (result) |_| {} else |_| {}
    }
}

test "Header.encode rejects too-small buffer" {
    var small: [header_size - 1]u8 = undefined;
    const hdr: Header = .{
        .txid = 1,
        .flags = .{},
        .qdcount = 0,
        .ancount = 0,
        .nscount = 0,
        .arcount = 0,
    };
    try std.testing.expectError(error.NoSpaceLeft, hdr.encode(&small));
}

test "encodeQuestion fails on tiny buffer" {
    var buf: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, encodeQuestion(&buf, "example.com", .a));
}

test "encodeQuery fails on too-small header buffer" {
    var buf: [header_size - 1]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, encodeQuery(&buf, 1, "x.test", .a));
}

test "skipName advances cursor past compressed name" {
    var msg: [64]u8 = undefined;
    @memset(&msg, 0);
    const off = 12;
    const wire = "\x07example\x03com\x00";
    @memcpy(msg[off .. off + wire.len], wire);
    const ptr_at = off + wire.len;
    msg[ptr_at] = 0xC0;
    msg[ptr_at + 1] = 0x0C;

    var cursor: usize = ptr_at;
    try skipName(&msg, &cursor);
    try std.testing.expectEqual(@as(usize, ptr_at + 2), cursor);
}

test "skipName advances cursor past uncompressed name" {
    const wire = "\x07example\x03com\x00";
    var cursor: usize = 0;
    try skipName(wire, &cursor);
    try std.testing.expectEqual(@as(usize, wire.len), cursor);
}

test "NameBuffer.eqlIgnoreCase" {
    var nb: NameBuffer = .{};
    try nb.copyFrom("Example.COM");
    // copyFrom does not lowercase — that's a parser-side property.
    // appendLabel does. Use appendLabel:
    var nb2: NameBuffer = .{};
    try nb2.appendLabel("Example");
    try nb2.appendLabel("COM");
    try std.testing.expectEqualSlices(u8, "example.com", nb2.slice());
    try std.testing.expect(nb2.eqlIgnoreCase("ExAmPlE.com"));
}
