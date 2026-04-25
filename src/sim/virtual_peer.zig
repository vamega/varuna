const std = @import("std");
const posix = std.posix;
const pw = @import("../net/peer_wire.zig");

/// A synthetic BitTorrent peer that communicates over an AF_UNIX socketpair.
///
/// The test controls one fd directly (blocking reads/writes); the EventLoop
/// owns the other fd via io_uring. Because AF_UNIX socketpairs share kernel
/// socket buffers, all io_uring SEND/RECV ops on the EventLoop side work
/// identically to TCP — no network stack required.
///
/// Typical test setup:
///   const pair = try VirtualPeer.init();
///   const slot = try el.addConnectedPeer(pair.el_fd, tid);
///   // spawn seeder thread that calls pair.vp.recvHandshake(), sendHandshake() …
///   // tick EventLoop in main thread until transfer completes
pub const VirtualPeer = struct {
    fd: posix.fd_t, // test side: blocking reads and writes

    pub const Request = struct {
        index: u32,
        begin: u32,
        length: u32,
    };

    /// Create a socketpair. `el_fd` must be passed to EventLoop.addConnectedPeer;
    /// the EventLoop will close it when the peer slot is freed. Call `vp.deinit()`
    /// to close the test-side fd when done.
    pub fn init() !struct { vp: VirtualPeer, el_fd: posix.fd_t } {
        var fds: [2]posix.fd_t = undefined;
        const rc = std.c.socketpair(posix.AF.UNIX, posix.SOCK.STREAM | posix.SOCK.CLOEXEC, 0, &fds);
        if (rc != 0) return error.SystemResources;
        // The EventLoop side must be non-blocking so io_uring operates on it normally.
        const flags = try posix.fcntl(fds[1], posix.F.GETFL, 0);
        const nonblock: usize = @as(u32, @bitCast(posix.O{ .NONBLOCK = true }));
        _ = try posix.fcntl(fds[1], posix.F.SETFL, flags | nonblock);
        return .{ .vp = .{ .fd = fds[0] }, .el_fd = fds[1] };
    }

    pub fn deinit(self: *VirtualPeer) void {
        if (self.fd >= 0) posix.close(self.fd);
    }

    /// Send all bytes in `data` to the EventLoop (blocking until fully written).
    pub fn sendAll(self: *VirtualPeer, data: []const u8) !void {
        var sent: usize = 0;
        while (sent < data.len) {
            const n = try posix.write(self.fd, data[sent..]);
            if (n == 0) return error.EndOfStream;
            sent += n;
        }
    }

    /// Receive exactly `buf.len` bytes from the EventLoop (blocking).
    pub fn recvExact(self: *VirtualPeer, buf: []u8) !void {
        var received: usize = 0;
        while (received < buf.len) {
            const n = try posix.read(self.fd, buf[received..]);
            if (n == 0) return error.EndOfStream;
            received += n;
        }
    }

    /// Receive the 68-byte BitTorrent handshake sent by the EventLoop.
    pub fn recvHandshake(self: *VirtualPeer) ![68]u8 {
        var buf: [68]u8 = undefined;
        try self.recvExact(&buf);
        return buf;
    }

    /// Send a BitTorrent handshake to the EventLoop.
    /// Extension bits are all zero, so the EventLoop skips the BEP 10 extension
    /// handshake exchange and goes directly to INTERESTED.
    pub fn sendHandshake(self: *VirtualPeer, info_hash: [20]u8, peer_id: [20]u8) !void {
        const hs = pw.serializeHandshake(info_hash, peer_id);
        try self.sendAll(&hs);
    }

    /// Send a BITFIELD message to the EventLoop.
    /// `piece_count` is the total number of pieces; `have_all` marks all set.
    /// Supports up to 8192 pieces (1024-byte bitfield) — sufficient for tests.
    pub fn sendBitfield(self: *VirtualPeer, piece_count: u32, have_all: bool) !void {
        const byte_len = (piece_count + 7) / 8;
        if (byte_len > 1024) return error.TooManyPieces;

        var buf: [5 + 1024]u8 = undefined;
        std.mem.writeInt(u32, buf[0..4], 1 + byte_len, .big);
        buf[4] = 5; // BITFIELD
        if (have_all) {
            @memset(buf[5 .. 5 + byte_len], 0xFF);
            // Clear spare bits in the last byte (BEP 3 requirement)
            const spare: u32 = byte_len * 8 - piece_count;
            if (spare > 0 and spare < 8) {
                buf[5 + byte_len - 1] &= ~(@as(u8, 0xFF) >> @as(u3, @intCast(8 - spare)));
            }
        } else {
            @memset(buf[5 .. 5 + byte_len], 0x00);
        }
        try self.sendAll(buf[0 .. 5 + byte_len]);
    }

    /// Send an UNCHOKE message (id=1, length=1) to the EventLoop.
    pub fn sendUnchoke(self: *VirtualPeer) !void {
        const msg = [_]u8{ 0, 0, 0, 1, 1 };
        try self.sendAll(&msg);
    }

    /// Send a PIECE message (id=7) to the EventLoop.
    pub fn sendPiece(self: *VirtualPeer, index: u32, begin: u32, data: []const u8) !void {
        const msg_len: u32 = @intCast(1 + 4 + 4 + data.len); // id + index + begin + block
        var hdr: [13]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], msg_len, .big);
        hdr[4] = 7; // PIECE
        std.mem.writeInt(u32, hdr[5..9], index, .big);
        std.mem.writeInt(u32, hdr[9..13], begin, .big);
        try self.sendAll(&hdr);
        try self.sendAll(data);
    }

    /// Drain messages from the EventLoop until a REQUEST (id=6) arrives.
    /// All other messages (keep-alives, INTERESTED, etc.) are discarded.
    pub fn waitForRequest(self: *VirtualPeer) !Request {
        while (true) {
            var len_buf: [4]u8 = undefined;
            try self.recvExact(&len_buf);
            const msg_len = std.mem.readInt(u32, &len_buf, .big);
            if (msg_len == 0) continue; // keep-alive

            var id_buf: [1]u8 = undefined;
            try self.recvExact(&id_buf);
            const msg_id = id_buf[0];
            const body_len = msg_len - 1;

            if (msg_id == 6 and body_len == 12) {
                var payload: [12]u8 = undefined;
                try self.recvExact(&payload);
                return .{
                    .index = std.mem.readInt(u32, payload[0..4], .big),
                    .begin = std.mem.readInt(u32, payload[4..8], .big),
                    .length = std.mem.readInt(u32, payload[8..12], .big),
                };
            }

            // Drain body of any other message
            var remaining = body_len;
            var drain: [256]u8 = undefined;
            while (remaining > 0) {
                const chunk = @min(remaining, drain.len);
                try self.recvExact(drain[0..chunk]);
                remaining -= chunk;
            }
        }
    }
};
