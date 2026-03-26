const std = @import("std");
const posix = std.posix;
const Bitfield = @import("../bitfield.zig").Bitfield;
const Ring = @import("../io/ring.zig").Ring;
const peer_wire = @import("../net/peer_wire.zig");
const transport = @import("../net/transport.zig");
const storage = @import("../storage/root.zig");
const session_mod = @import("session.zig");
const blocks_mod = @import("blocks.zig");
const PieceTracker = @import("piece_tracker.zig").PieceTracker;

const pipeline_depth: u32 = 5;

const RequestPipeline = struct {
    entries: [pipeline_depth]blocks_mod.Geometry.Request = undefined,
    len: u32 = 0,

    fn push(self: *RequestPipeline, request: blocks_mod.Geometry.Request) void {
        std.debug.assert(self.len < pipeline_depth);
        self.entries[self.len] = request;
        self.len += 1;
    }

    fn matchAndRemove(self: *RequestPipeline, piece_index: u32, block_offset: u32) bool {
        for (self.entries[0..self.len], 0..) |entry, i| {
            if (entry.piece_index == piece_index and entry.piece_offset == block_offset) {
                self.len -= 1;
                if (i < self.len) {
                    self.entries[i] = self.entries[self.len];
                }
                return true;
            }
        }
        return false;
    }
};

pub const WorkerContext = struct {
    allocator: std.mem.Allocator,
    session: *const session_mod.Session,
    tracker: *PieceTracker,
    peer_address: std.net.Address,
    peer_id: [20]u8,
    status_writer: ?*std.Io.Writer = null,

    err: ?anyerror = null,
    bytes_downloaded: u64 = 0,

    pub fn run(self: *WorkerContext) void {
        self.runInner() catch |err| {
            self.err = err;
        };
    }

    fn runInner(self: *WorkerContext) !void {
        var ring = try Ring.init(16);
        defer ring.deinit();

        var store = try storage.writer.PieceStore.init(self.allocator, self.session, &ring);
        defer store.deinit();

        const fd = try transport.tcpConnect(&ring, self.peer_address);
        defer posix.close(fd);

        try peer_wire.writeHandshake(&ring, fd, self.session.metainfo.info_hash, self.peer_id);
        const remote_handshake = try peer_wire.readHandshake(&ring, fd);
        if (!std.mem.eql(u8, remote_handshake.info_hash[0..], self.session.metainfo.info_hash[0..])) {
            return error.WrongTorrentPeer;
        }

        try peer_wire.writeInterested(&ring, fd);

        var availability = try Bitfield.init(self.allocator, self.session.pieceCount());
        defer availability.deinit(self.allocator);
        var availability_known = false;

        var peer_choking = true;
        const geometry = self.session.geometry();

        while (!self.tracker.isComplete()) {
            // Wait for unchoke and bitfield before claiming
            while (peer_choking or !availability_known) {
                const message = try peer_wire.readMessageAlloc(self.allocator, &ring, fd);
                defer peer_wire.freeMessage(self.allocator, message);
                applyPeerMessage(&availability, &availability_known, &peer_choking, message);
            }

            const peer_bf: ?*const Bitfield = if (availability_known) &availability else null;
            const piece_index = self.tracker.claimPiece(peer_bf) orelse {
                // No pieces available from this peer, wait for have messages
                const message = try peer_wire.readMessageAlloc(self.allocator, &ring, fd);
                defer peer_wire.freeMessage(self.allocator, message);
                applyPeerMessage(&availability, &availability_known, &peer_choking, message);
                continue;
            };

            const downloaded = self.downloadPiece(
                &ring,
                fd,
                &store,
                &availability,
                &availability_known,
                &peer_choking,
                geometry,
                piece_index,
            ) catch |err| {
                self.tracker.releasePiece(piece_index);
                return err;
            };

            self.bytes_downloaded += downloaded;
        }
    }

    fn downloadPiece(
        self: *WorkerContext,
        ring: *Ring,
        fd: posix.fd_t,
        store: *storage.writer.PieceStore,
        availability: *Bitfield,
        availability_known: *bool,
        peer_choking: *bool,
        geometry: blocks_mod.Geometry,
        piece_index: u32,
    ) !u64 {
        const plan = try storage.verify.planPieceVerification(self.allocator, self.session, piece_index);
        defer storage.verify.freePiecePlan(self.allocator, plan);

        const piece_buffer = try self.allocator.alloc(u8, @intCast(plan.piece_length));
        defer self.allocator.free(piece_buffer);

        const block_count = try geometry.blockCount(piece_index);
        var next_to_send: u32 = 0;
        var blocks_received: u32 = 0;
        var pipeline: RequestPipeline = .{};

        // Fill initial pipeline
        while (next_to_send < block_count and pipeline.len < pipeline_depth) {
            const req = try geometry.requestForBlock(piece_index, next_to_send);
            try peer_wire.writeRequest(ring, fd, .{
                .piece_index = req.piece_index,
                .block_offset = req.piece_offset,
                .length = req.length,
            });
            pipeline.push(req);
            next_to_send += 1;
        }

        while (blocks_received < block_count) {
            const message = try peer_wire.readMessageAlloc(self.allocator, ring, fd);
            defer peer_wire.freeMessage(self.allocator, message);

            switch (message) {
                .piece => |piece| {
                    if (!pipeline.matchAndRemove(piece.piece_index, piece.block_offset)) {
                        return error.UnexpectedPieceBlock;
                    }

                    const start: usize = @intCast(piece.block_offset);
                    const end: usize = start + piece.block.len;
                    if (end > plan.piece_length) return error.UnexpectedPieceBlock;
                    @memcpy(piece_buffer[start..end], piece.block);
                    blocks_received += 1;

                    if (next_to_send < block_count and !peer_choking.*) {
                        const req = try geometry.requestForBlock(piece_index, next_to_send);
                        try peer_wire.writeRequest(ring, fd, .{
                            .piece_index = req.piece_index,
                            .block_offset = req.piece_offset,
                            .length = req.length,
                        });
                        pipeline.push(req);
                        next_to_send += 1;
                    }
                },
                .choke => {
                    peer_choking.* = true;
                    pipeline = .{};
                    next_to_send = blocks_received;
                },
                .unchoke => {
                    peer_choking.* = false;
                    while (next_to_send < block_count and pipeline.len < pipeline_depth) {
                        const req = try geometry.requestForBlock(piece_index, next_to_send);
                        try peer_wire.writeRequest(ring, fd, .{
                            .piece_index = req.piece_index,
                            .block_offset = req.piece_offset,
                            .length = req.length,
                        });
                        pipeline.push(req);
                        next_to_send += 1;
                    }
                },
                else => applyPeerMessage(availability, availability_known, peer_choking, message),
            }
        }

        if (!try storage.verify.verifyPieceBuffer(plan, piece_buffer)) {
            return error.PieceHashMismatch;
        }

        try store.writePiece(plan.spans, piece_buffer);
        self.tracker.completePiece(piece_index, plan.piece_length);

        return plan.piece_length;
    }
};

fn applyPeerMessage(
    availability: *Bitfield,
    availability_known: *bool,
    peer_choking: *bool,
    message: peer_wire.InboundMessage,
) void {
    switch (message) {
        .keep_alive, .interested, .not_interested, .request, .cancel, .port, .piece => {},
        .choke => peer_choking.* = true,
        .unchoke => peer_choking.* = false,
        .have => |piece_index| {
            availability.set(piece_index) catch {};
            availability_known.* = true;
        },
        .bitfield => |bitfield_data| {
            availability.importBitfield(bitfield_data);
            availability_known.* = true;
        },
    }
}
