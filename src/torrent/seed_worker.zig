const std = @import("std");
const posix = std.posix;
const Ring = @import("../io/ring.zig").Ring;
const peer_wire = @import("../net/peer_wire.zig");
const storage = @import("../storage/root.zig");
const session_mod = @import("session.zig");

pub const SeedWorkerContext = struct {
    allocator: std.mem.Allocator,
    session: *const session_mod.Session,
    complete_pieces: *const storage.verify.PieceSet,
    fd: posix.fd_t,
    peer_id: [20]u8,

    err: ?anyerror = null,
    bytes_seeded: u64 = 0,

    pub fn run(self: *SeedWorkerContext) void {
        self.runInner() catch |err| {
            self.err = err;
        };
        // Close the fd when done -- we own it
        posix.close(self.fd);
    }

    fn runInner(self: *SeedWorkerContext) !void {
        var ring = try Ring.init(16);
        defer ring.deinit();

        var store = try storage.writer.PieceStore.init(self.allocator, self.session, &ring);
        defer store.deinit();

        const remote_handshake = try peer_wire.readHandshake(&ring, self.fd);
        if (!std.mem.eql(u8, remote_handshake.info_hash[0..], self.session.metainfo.info_hash[0..])) {
            return error.WrongTorrentPeer;
        }

        try peer_wire.writeHandshake(&ring, self.fd, self.session.metainfo.info_hash, self.peer_id);
        try peer_wire.writeBitfield(&ring, self.fd, self.complete_pieces.bits);

        const piece_buffer = try self.allocator.alloc(u8, self.session.layout.piece_length);
        defer self.allocator.free(piece_buffer);

        var peer_unchoked = false;
        var cached_piece_index: ?u32 = null;
        var cached_piece_length: usize = 0;

        while (true) {
            const message = peer_wire.readMessageAlloc(self.allocator, &ring, self.fd) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            defer peer_wire.freeMessage(self.allocator, message);

            switch (message) {
                .keep_alive, .not_interested, .have, .bitfield, .cancel, .port, .choke, .unchoke => {},
                .interested => {
                    if (!peer_unchoked) {
                        try peer_wire.writeUnchoke(&ring, self.fd);
                        peer_unchoked = true;
                    }
                },
                .request => |request| {
                    if (!peer_unchoked) continue;
                    if (!self.complete_pieces.has(request.piece_index)) continue;

                    if (cached_piece_index == null or cached_piece_index.? != request.piece_index) {
                        const plan = try storage.verify.planPieceVerification(self.allocator, self.session, request.piece_index);
                        defer storage.verify.freePiecePlan(self.allocator, plan);

                        try store.readPiece(plan.spans, piece_buffer[0..plan.piece_length]);
                        cached_piece_index = request.piece_index;
                        cached_piece_length = plan.piece_length;
                    }

                    const block_start: usize = @intCast(request.block_offset);
                    const block_end = block_start + @as(usize, @intCast(request.length));
                    if (block_end < block_start or block_end > cached_piece_length) continue;

                    try peer_wire.writePiece(
                        &ring,
                        self.fd,
                        request.piece_index,
                        request.block_offset,
                        piece_buffer[block_start..block_end],
                    );
                    self.bytes_seeded += request.length;
                },
                .piece => {},
            }
        }
    }
};
