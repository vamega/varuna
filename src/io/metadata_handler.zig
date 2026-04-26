const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;
const log = std.log.scoped(.metadata_handler);

const types = @import("types.zig");

const ut_metadata = @import("../net/ut_metadata.zig");
const ext = @import("../net/extensions.zig");
const pw = @import("../net/peer_wire.zig");
const socket_util = @import("../net/socket.zig");

const io_interface = @import("io_interface.zig");
const real_io_mod = @import("real_io.zig");
const RealIO = real_io_mod.RealIO;

/// Async BEP 9 metadata fetch state machine for the io_uring event loop.
///
/// Downloads the info dictionary from peers using the ut_metadata extension
/// (BEP 9). Manages up to `max_slots` concurrent peer connections, each
/// running through a handshake -> extension handshake -> piece request/recv
/// state machine. Pieces are collected by a `MetadataAssembler` which
/// verifies the result against the expected info-hash.
///
/// Lifecycle:
///   1. `create()` -- heap-allocates the state machine.
///   2. `start()` -- begins connecting to the first batch of peers.
///   3. Event loop calls `handleCqe()` for each completed io_uring operation.
///   4. When all pieces are verified, `on_complete` fires with the raw bytes.
///   5. Caller calls `destroy()` to free resources.
pub const AsyncMetadataFetch = struct {
    allocator: std.mem.Allocator,
    io: *RealIO,
    info_hash: [20]u8,
    peer_id: [20]u8,
    port: u16,
    is_private: bool,

    assembler: ut_metadata.MetadataAssembler,

    peers: []std.net.Address,
    peer_count: u32,
    next_peer_idx: u32 = 0,
    peers_attempted: u32 = 0,

    slots: [max_slots]Slot = [_]Slot{.{}} ** max_slots,
    active_slots: u8 = 0,

    done: bool = false,
    result_bytes: ?[]const u8 = null,
    on_complete: ?*const fn (*AsyncMetadataFetch) void = null,
    caller_ctx: ?*anyopaque = null,

    pub const max_slots: u8 = 3;

    // recv_buf must be large enough for the BT handshake (68 bytes),
    // extension handshake messages (typically < 1 KiB), and ut_metadata
    // data messages (up to 16 KiB piece + bencoded header + BT framing).
    // 32 KiB covers all cases with room for partial reads.
    const recv_buf_size: usize = 32768;

    // send_buf must hold the largest message we send: a BT handshake (68 bytes),
    // or an extension handshake / ut_metadata request (typically < 256 bytes).
    const send_buf_size: usize = 512;

    pub const SlotState = enum {
        free,
        connecting,
        handshake_send,
        handshake_recv,
        ext_handshake_send,
        ext_handshake_recv,
        piece_request_send,
        piece_recv,
    };

    pub const Slot = struct {
        state: SlotState = .free,
        fd: posix.fd_t = -1,
        peer_idx: u32 = 0,
        ut_metadata_id: u8 = 0,
        pieces_requested: u32 = 0,
        current_piece: ?u32 = null,

        // Buffers are heap-allocated to avoid bloating the struct.
        // Allocated on slot activation, freed on slot release.
        send_buf: ?[]u8 = null,
        send_len: u32 = 0,
        recv_buf: ?[]u8 = null,
        recv_len: u32 = 0,

        // For handshake recv, we need exactly 68 bytes.
        // For message recv, we first read the 4-byte length header,
        // then the message body.
        recv_expected: u32 = 0,
        // When true, we are reading a 4-byte BT message length prefix.
        reading_msg_header: bool = false,
        // Count of non-extension messages skipped while waiting for
        // the extension handshake reply.
        msgs_skipped: u32 = 0,

        /// Caller-owned completion for the slot's in-flight io op.
        /// Only one op is in flight per slot at a time (the state
        /// machine is fully serial), so a single completion suffices.
        completion: io_interface.Completion = .{},
    };

    /// Create a heap-allocated AsyncMetadataFetch.
    ///
    /// `shared_assembly_buffer` and `shared_assembly_received`, if
    /// non-null, are externally-owned worst-case-sized slices used by
    /// the assembler in place of per-fetch heap allocs. This is the
    /// daemon's hot path: the EventLoop pre-allocates these once at
    /// init and reuses them across torrents (BEP 9 + the EventLoop's
    /// own `metadata_fetch != null` gate guarantee at most one
    /// in-flight metadata fetch at a time). When both are null, the
    /// assembler falls back to allocator-owned storage (used by the
    /// legacy direct tests in this file).
    pub fn create(
        allocator: std.mem.Allocator,
        io: *RealIO,
        info_hash: [20]u8,
        peer_id: [20]u8,
        port: u16,
        is_private: bool,
        peers: []const std.net.Address,
        on_complete: ?*const fn (*AsyncMetadataFetch) void,
        caller_ctx: ?*anyopaque,
        shared_assembly_buffer: ?[]u8,
        shared_assembly_received: ?[]bool,
    ) !*AsyncMetadataFetch {
        const owned_peers = try allocator.dupe(std.net.Address, peers);
        errdefer allocator.free(owned_peers);

        const self = try allocator.create(AsyncMetadataFetch);
        const assembler = if (shared_assembly_buffer != null and shared_assembly_received != null)
            ut_metadata.MetadataAssembler.initShared(
                info_hash,
                shared_assembly_buffer.?,
                shared_assembly_received.?,
            )
        else
            ut_metadata.MetadataAssembler.init(allocator, info_hash);

        self.* = .{
            .allocator = allocator,
            .io = io,
            .info_hash = info_hash,
            .peer_id = peer_id,
            .port = port,
            .is_private = is_private,
            .assembler = assembler,
            .peers = owned_peers,
            .peer_count = @intCast(owned_peers.len),
            .on_complete = on_complete,
            .caller_ctx = caller_ctx,
        };
        return self;
    }

    /// Begin connecting to the first batch of peers.
    pub fn start(self: *AsyncMetadataFetch) void {
        if (self.peer_count == 0) {
            log.warn("metadata fetch: no peers available", .{});
            self.finish(false);
            return;
        }

        // Fill slots with initial connections
        var started: u8 = 0;
        while (started < max_slots and self.next_peer_idx < self.peer_count) {
            self.connectPeer(started);
            started += 1;
        }

        if (started == 0) {
            self.finish(false);
        }
    }

    /// Recover the slot index for a callback firing on `slot.completion`.
    fn slotIdxFor(self: *const AsyncMetadataFetch, slot: *const Slot) u8 {
        const offset = @intFromPtr(slot) - @intFromPtr(&self.slots[0]);
        return @intCast(offset / @sizeOf(Slot));
    }

    fn metadataConnectComplete(
        userdata: ?*anyopaque,
        completion: *io_interface.Completion,
        result: io_interface.Result,
    ) io_interface.CallbackAction {
        const self: *AsyncMetadataFetch = @ptrCast(@alignCast(userdata.?));
        const slot: *Slot = @fieldParentPtr("completion", completion);
        if (self.done or slot.state == .free) return .disarm;
        const slot_idx = self.slotIdxFor(slot);
        const ok = switch (result) {
            .connect => |r| if (r) |_| true else |_| false,
            else => false,
        };
        self.onConnectComplete(slot, slot_idx, if (ok) 0 else -1);
        return .disarm;
    }

    fn metadataSendComplete(
        userdata: ?*anyopaque,
        completion: *io_interface.Completion,
        result: io_interface.Result,
    ) io_interface.CallbackAction {
        const self: *AsyncMetadataFetch = @ptrCast(@alignCast(userdata.?));
        const slot: *Slot = @fieldParentPtr("completion", completion);
        if (self.done or slot.state == .free) return .disarm;
        const slot_idx = self.slotIdxFor(slot);
        const res: i32 = switch (result) {
            .send => |r| if (r) |n|
                std.math.cast(i32, n) orelse std.math.maxInt(i32)
            else |_|
                -1,
            else => -1,
        };
        self.onSendComplete(slot, slot_idx, res);
        return .disarm;
    }

    fn metadataRecvComplete(
        userdata: ?*anyopaque,
        completion: *io_interface.Completion,
        result: io_interface.Result,
    ) io_interface.CallbackAction {
        const self: *AsyncMetadataFetch = @ptrCast(@alignCast(userdata.?));
        const slot: *Slot = @fieldParentPtr("completion", completion);
        if (self.done or slot.state == .free) return .disarm;
        const slot_idx = self.slotIdxFor(slot);
        const res: i32 = switch (result) {
            .recv => |r| if (r) |n|
                std.math.cast(i32, n) orelse std.math.maxInt(i32)
            else |_|
                -1,
            else => -1,
        };
        self.onRecvComplete(slot, slot_idx, res);
        return .disarm;
    }

    // ── Connection ─────────────────────────────────────────

    fn connectPeer(self: *AsyncMetadataFetch, slot_idx: u8) void {
        if (self.next_peer_idx >= self.peer_count) {
            return;
        }

        const peer_idx = self.next_peer_idx;
        self.next_peer_idx += 1;
        self.peers_attempted += 1;

        const addr = self.peers[peer_idx];
        const family = addr.any.family;

        const fd = posix.socket(
            family,
            posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK,
            posix.IPPROTO.TCP,
        ) catch {
            log.debug("metadata: failed to create socket for peer {d}", .{peer_idx});
            self.tryNextPeer(slot_idx);
            return;
        };

        socket_util.configurePeerSocket(fd);

        const slot = &self.slots[slot_idx];
        slot.* = Slot{
            .state = .connecting,
            .fd = fd,
            .peer_idx = peer_idx,
        };

        // Allocate buffers
        slot.send_buf = self.allocator.alloc(u8, send_buf_size) catch {
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        };
        slot.recv_buf = self.allocator.alloc(u8, recv_buf_size) catch {
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        };

        self.active_slots += 1;

        self.io.connect(
            .{ .fd = fd, .addr = self.peers[peer_idx] },
            &slot.completion,
            self,
            metadataConnectComplete,
        ) catch {
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        };
    }

    // ── CQE handlers ──────────────────────────────────────

    fn onConnectComplete(self: *AsyncMetadataFetch, slot: *Slot, slot_idx: u8, res: i32) void {
        if (res < 0) {
            log.debug("metadata: connect failed for peer {d} (errno={d})", .{ slot.peer_idx, -res });
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        }

        // Build BT handshake into send_buf
        const send_buf = slot.send_buf orelse {
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        };

        send_buf[0] = pw.protocol_length;
        @memcpy(send_buf[1 .. 1 + pw.protocol_string.len], pw.protocol_string);
        @memset(send_buf[20..28], 0);
        // BEP 10: set extension protocol bit in reserved bytes
        send_buf[20 + ext.reserved_byte] |= ext.reserved_mask;
        @memcpy(send_buf[28..48], &self.info_hash);
        @memcpy(send_buf[48..68], &self.peer_id);
        slot.send_len = 68;
        slot.state = .handshake_send;

        self.submitSend(slot, slot_idx);
    }

    fn onSendComplete(self: *AsyncMetadataFetch, slot: *Slot, slot_idx: u8, res: i32) void {
        if (res <= 0) {
            log.debug("metadata: send failed for peer {d} (res={d})", .{ slot.peer_idx, res });
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        }

        // Handle partial sends
        const bytes_sent: u32 = @intCast(res);
        if (bytes_sent < slot.send_len) {
            // Shift remaining data to front of buffer
            const send_buf = slot.send_buf orelse {
                self.releaseSlot(slot_idx);
                self.tryNextPeer(slot_idx);
                return;
            };
            const remaining = slot.send_len - bytes_sent;
            std.mem.copyForwards(u8, send_buf[0..remaining], send_buf[bytes_sent..slot.send_len]);
            slot.send_len = remaining;
            self.submitSend(slot, slot_idx);
            return;
        }

        // Send complete -- advance state
        switch (slot.state) {
            .handshake_send => {
                // Start receiving peer's handshake (68 bytes)
                slot.state = .handshake_recv;
                slot.recv_len = 0;
                slot.recv_expected = 68;
                slot.reading_msg_header = false;
                self.submitRecv(slot, slot_idx);
            },
            .ext_handshake_send => {
                // Start receiving extension handshake reply
                slot.state = .ext_handshake_recv;
                slot.recv_len = 0;
                slot.recv_expected = 4; // BT message length header
                slot.reading_msg_header = true;
                slot.msgs_skipped = 0;
                self.submitRecv(slot, slot_idx);
            },
            .piece_request_send => {
                // Wait for piece data response
                slot.state = .piece_recv;
                slot.recv_len = 0;
                slot.recv_expected = 4; // BT message length header
                slot.reading_msg_header = true;
                slot.msgs_skipped = 0;
                self.submitRecv(slot, slot_idx);
            },
            else => {
                self.releaseSlot(slot_idx);
                self.tryNextPeer(slot_idx);
            },
        }
    }

    fn onRecvComplete(self: *AsyncMetadataFetch, slot: *Slot, slot_idx: u8, res: i32) void {
        if (res <= 0) {
            log.debug("metadata: recv failed/eof for peer {d} (res={d})", .{ slot.peer_idx, res });
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        }

        const bytes_received: u32 = @intCast(res);
        slot.recv_len += bytes_received;

        // Check if we have received enough data
        if (slot.recv_len < slot.recv_expected) {
            // Need more data
            self.submitRecv(slot, slot_idx);
            return;
        }

        // We have enough data -- process based on state
        switch (slot.state) {
            .handshake_recv => self.processHandshake(slot, slot_idx),
            .ext_handshake_recv => self.processExtMessage(slot, slot_idx, true),
            .piece_recv => self.processExtMessage(slot, slot_idx, false),
            else => {
                self.releaseSlot(slot_idx);
                self.tryNextPeer(slot_idx);
            },
        }
    }

    // ── Protocol processing ───────────────────────────────

    fn processHandshake(self: *AsyncMetadataFetch, slot: *Slot, slot_idx: u8) void {
        const recv_buf = slot.recv_buf orelse {
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        };

        // Validate BT handshake
        if (recv_buf[0] != pw.protocol_length or
            !std.mem.eql(u8, recv_buf[1..20], pw.protocol_string))
        {
            log.debug("metadata: invalid handshake from peer {d}", .{slot.peer_idx});
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        }

        // Check BEP 10 support
        var reserved: [8]u8 = undefined;
        @memcpy(&reserved, recv_buf[20..28]);
        if (!ext.supportsExtensions(reserved)) {
            log.debug("metadata: peer {d} does not support BEP 10", .{slot.peer_idx});
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        }

        // Send extension handshake
        const ext_payload = ext.encodeExtensionHandshake(self.allocator, self.port, self.is_private) catch {
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        };
        defer self.allocator.free(ext_payload);

        // Frame it: 4-byte length + msg_id(20) + sub_id(0) + payload
        const send_buf = slot.send_buf orelse {
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        };

        const msg_len: u32 = @intCast(2 + ext_payload.len); // msg_id + sub_id + payload
        const frame_len: u32 = 4 + msg_len;
        if (frame_len > send_buf_size) {
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        }

        std.mem.writeInt(u32, send_buf[0..4], msg_len, .big);
        send_buf[4] = ext.msg_id;
        send_buf[5] = ext.handshake_sub_id;
        @memcpy(send_buf[6 .. 6 + ext_payload.len], ext_payload);

        slot.send_len = frame_len;
        slot.state = .ext_handshake_send;
        self.submitSend(slot, slot_idx);
    }

    /// Process a BT message received during ext_handshake_recv or piece_recv.
    /// Handles the length-prefix framing: first reads 4-byte header, then body.
    fn processExtMessage(self: *AsyncMetadataFetch, slot: *Slot, slot_idx: u8, want_ext_hs: bool) void {
        const recv_buf = slot.recv_buf orelse {
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        };

        if (slot.reading_msg_header) {
            // We have 4 bytes: parse message length
            const msg_len = std.mem.readInt(u32, recv_buf[0..4], .big);

            if (msg_len == 0) {
                // Keep-alive -- read next message header
                slot.recv_len = 0;
                slot.recv_expected = 4;
                slot.msgs_skipped += 1;
                if (slot.msgs_skipped > 50) {
                    log.debug("metadata: too many non-matching messages from peer {d}", .{slot.peer_idx});
                    self.releaseSlot(slot_idx);
                    self.tryNextPeer(slot_idx);
                    return;
                }
                self.submitRecv(slot, slot_idx);
                return;
            }

            if (msg_len > pw.max_message_length) {
                log.debug("metadata: message too large from peer {d}: {d}", .{ slot.peer_idx, msg_len });
                self.releaseSlot(slot_idx);
                self.tryNextPeer(slot_idx);
                return;
            }

            // Check that message body fits in our recv buffer (after the 4-byte header)
            if (msg_len > recv_buf_size - 4) {
                log.debug("metadata: message too large for buffer from peer {d}: {d}", .{ slot.peer_idx, msg_len });
                self.releaseSlot(slot_idx);
                self.tryNextPeer(slot_idx);
                return;
            }

            // Now read the message body (starting after the 4-byte header we already have)
            slot.reading_msg_header = false;
            slot.recv_len = 4; // keep the header bytes
            slot.recv_expected = 4 + msg_len;
            self.submitRecv(slot, slot_idx);
            return;
        }

        // We have the full message body at recv_buf[4..recv_expected]
        const msg_body = recv_buf[4..slot.recv_expected];

        if (msg_body.len == 0) {
            // Empty message after length -- skip
            self.resetForNextMessage(slot, slot_idx);
            return;
        }

        const msg_id = msg_body[0];

        if (msg_id != ext.msg_id or msg_body.len < 2) {
            // Not an extension message -- skip and read next
            slot.msgs_skipped += 1;
            if (slot.msgs_skipped > 50) {
                log.debug("metadata: too many non-extension messages from peer {d}", .{slot.peer_idx});
                self.releaseSlot(slot_idx);
                self.tryNextPeer(slot_idx);
                return;
            }
            self.resetForNextMessage(slot, slot_idx);
            return;
        }

        const sub_id = msg_body[1];
        const ext_payload = msg_body[2..];

        if (want_ext_hs) {
            // Looking for extension handshake (sub_id = 0)
            if (sub_id != ext.handshake_sub_id) {
                slot.msgs_skipped += 1;
                if (slot.msgs_skipped > 50) {
                    self.releaseSlot(slot_idx);
                    self.tryNextPeer(slot_idx);
                    return;
                }
                self.resetForNextMessage(slot, slot_idx);
                return;
            }
            self.processExtHandshake(slot, slot_idx, ext_payload);
        } else {
            // Looking for ut_metadata response (sub_id = our local ut_metadata id)
            if (sub_id != ext.local_ut_metadata_id) {
                slot.msgs_skipped += 1;
                if (slot.msgs_skipped > 50) {
                    self.releaseSlot(slot_idx);
                    self.tryNextPeer(slot_idx);
                    return;
                }
                self.resetForNextMessage(slot, slot_idx);
                return;
            }
            self.processPieceResponse(slot, slot_idx, ext_payload);
        }
    }

    fn processExtHandshake(self: *AsyncMetadataFetch, slot: *Slot, slot_idx: u8, payload: []const u8) void {
        const result = ext.decodeExtensionHandshake(payload) catch {
            log.debug("metadata: invalid extension handshake from peer {d}", .{slot.peer_idx});
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        };

        slot.ut_metadata_id = result.extensions.ut_metadata;
        if (slot.ut_metadata_id == 0) {
            log.debug("metadata: peer {d} does not support ut_metadata", .{slot.peer_idx});
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        }

        if (result.metadata_size == 0) {
            log.debug("metadata: peer {d} did not report metadata_size", .{slot.peer_idx});
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        }

        // Set metadata size on assembler
        self.assembler.setSize(result.metadata_size) catch {
            log.debug("metadata: invalid metadata size from peer {d}: {d}", .{ slot.peer_idx, result.metadata_size });
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        };

        log.debug("metadata: peer {d} has ut_metadata={d}, size={d}", .{
            slot.peer_idx, slot.ut_metadata_id, result.metadata_size,
        });

        // Request first needed piece
        self.requestNextPiece(slot, slot_idx);
    }

    fn processPieceResponse(self: *AsyncMetadataFetch, slot: *Slot, slot_idx: u8, payload: []const u8) void {
        const meta_msg = ut_metadata.decode(self.allocator, payload) catch {
            log.debug("metadata: invalid ut_metadata message from peer {d}", .{slot.peer_idx});
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        };

        switch (meta_msg.msg_type) {
            .data => {
                const expected_piece = slot.current_piece orelse {
                    self.releaseSlot(slot_idx);
                    self.tryNextPeer(slot_idx);
                    return;
                };

                if (meta_msg.piece != expected_piece) {
                    // Wrong piece -- skip and keep waiting
                    slot.msgs_skipped += 1;
                    if (slot.msgs_skipped > 50) {
                        self.releaseSlot(slot_idx);
                        self.tryNextPeer(slot_idx);
                        return;
                    }
                    self.resetForNextMessage(slot, slot_idx);
                    return;
                }

                const piece_data = payload[meta_msg.data_offset..];
                _ = self.assembler.addPiece(meta_msg.piece, piece_data) catch |err| {
                    log.debug("metadata: failed to add piece {d} from peer {d}: {s}", .{
                        meta_msg.piece, slot.peer_idx, @errorName(err),
                    });
                    self.releaseSlot(slot_idx);
                    self.tryNextPeer(slot_idx);
                    return;
                };

                slot.pieces_requested += 1;
                log.debug("metadata: got piece {d}/{d} from peer {d}", .{
                    self.assembler.pieces_received,
                    self.assembler.piece_count,
                    slot.peer_idx,
                });

                // Check if metadata is complete
                if (self.assembler.isComplete()) {
                    self.verifyAndComplete(slot_idx);
                    return;
                }

                // Request next piece from this peer
                self.requestNextPiece(slot, slot_idx);
            },
            .reject => {
                log.debug("metadata: peer {d} rejected piece {d}", .{ slot.peer_idx, meta_msg.piece });
                self.releaseSlot(slot_idx);
                self.tryNextPeer(slot_idx);
            },
            .request => {
                // Peer requesting from us -- reject and continue waiting
                self.sendReject(slot, slot_idx, meta_msg.piece);
                self.resetForNextMessage(slot, slot_idx);
            },
        }
    }

    // ── Piece requesting ──────────────────────────────────

    fn requestNextPiece(self: *AsyncMetadataFetch, slot: *Slot, slot_idx: u8) void {
        const piece_idx = self.assembler.nextNeeded() orelse {
            // All pieces received (or being handled by other slots)
            if (self.assembler.isComplete()) {
                self.verifyAndComplete(slot_idx);
            } else {
                // Other slots are handling the remaining pieces.
                // Release this slot and let it try the next peer if needed.
                self.releaseSlot(slot_idx);
            }
            return;
        };

        slot.current_piece = piece_idx;

        // Encode the ut_metadata request
        const req_payload = ut_metadata.encodeRequest(self.allocator, piece_idx) catch {
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        };
        defer self.allocator.free(req_payload);

        // Frame it: 4-byte length + msg_id(20) + sub_id + payload
        const send_buf = slot.send_buf orelse {
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        };

        const msg_len: u32 = @intCast(2 + req_payload.len);
        const frame_len: u32 = 4 + msg_len;
        if (frame_len > send_buf_size) {
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        }

        std.mem.writeInt(u32, send_buf[0..4], msg_len, .big);
        send_buf[4] = ext.msg_id;
        send_buf[5] = slot.ut_metadata_id;
        @memcpy(send_buf[6 .. 6 + req_payload.len], req_payload);

        slot.send_len = frame_len;
        slot.state = .piece_request_send;
        self.submitSend(slot, slot_idx);
    }

    fn sendReject(_: *AsyncMetadataFetch, _: *Slot, _: u8, _: u32) void {
        // We cannot send a reject without interrupting the current recv flow.
        // Silently ignore; the peer will time out eventually.
    }

    // ── Verification and completion ───────────────────────

    fn verifyAndComplete(self: *AsyncMetadataFetch, slot_idx: u8) void {
        const info_bytes = self.assembler.verify() catch {
            log.warn("metadata: hash verification failed, resetting", .{});
            self.assembler.reset();
            // Try to continue with remaining peers
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        };

        log.info("metadata downloaded: {d} bytes, {d} pieces from {d} peers", .{
            self.assembler.total_size,
            self.assembler.piece_count,
            self.peers_attempted,
        });

        self.result_bytes = info_bytes;

        // Release all slots
        for (0..max_slots) |i| {
            if (self.slots[i].state != .free) {
                self.releaseSlot(@intCast(i));
            }
        }

        self.finish(true);
    }

    fn finish(self: *AsyncMetadataFetch, success: bool) void {
        if (self.done) return;
        self.done = true;

        if (!success) {
            self.result_bytes = null;
        }

        if (self.on_complete) |cb| {
            cb(self);
        }
    }

    // ── Slot management ───────────────────────────────────

    fn releaseSlot(self: *AsyncMetadataFetch, slot_idx: u8) void {
        const slot = &self.slots[slot_idx];
        if (slot.state == .free) return;

        if (slot.fd >= 0) {
            posix.close(slot.fd);
        }
        if (slot.send_buf) |buf| self.allocator.free(buf);
        if (slot.recv_buf) |buf| self.allocator.free(buf);

        slot.* = Slot{};

        if (self.active_slots > 0) self.active_slots -= 1;
    }

    fn tryNextPeer(self: *AsyncMetadataFetch, slot_idx: u8) void {
        if (self.done) return;

        if (self.next_peer_idx < self.peer_count) {
            self.connectPeer(slot_idx);
        } else if (self.active_slots == 0) {
            // All peers exhausted and no active connections
            log.warn("metadata: all peers exhausted, metadata incomplete", .{});
            self.finish(false);
        }
        // else: other slots are still active, wait for them
    }

    fn resetForNextMessage(self: *AsyncMetadataFetch, slot: *Slot, slot_idx: u8) void {
        slot.recv_len = 0;
        slot.recv_expected = 4;
        slot.reading_msg_header = true;
        self.submitRecv(slot, slot_idx);
    }

    // ── io_uring SQE submission ───────────────────────────

    fn submitSend(self: *AsyncMetadataFetch, slot: *Slot, slot_idx: u8) void {
        const send_buf = slot.send_buf orelse {
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        };

        self.io.send(
            .{ .fd = slot.fd, .buf = send_buf[0..slot.send_len] },
            &slot.completion,
            self,
            metadataSendComplete,
        ) catch {
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        };
    }

    fn submitRecv(self: *AsyncMetadataFetch, slot: *Slot, slot_idx: u8) void {
        const recv_buf = slot.recv_buf orelse {
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        };

        self.io.recv(
            .{ .fd = slot.fd, .buf = recv_buf[slot.recv_len..slot.recv_expected] },
            &slot.completion,
            self,
            metadataRecvComplete,
        ) catch {
            self.releaseSlot(slot_idx);
            self.tryNextPeer(slot_idx);
            return;
        };
    }

    // ── Cleanup ───────────────────────────────────────────

    pub fn destroy(self: *AsyncMetadataFetch) void {
        // Close any open fds and free slot buffers
        for (0..max_slots) |i| {
            if (self.slots[i].state != .free) {
                self.releaseSlot(@intCast(i));
            }
        }
        self.assembler.deinit();
        self.allocator.free(self.peers);
        self.allocator.destroy(self);
    }
};

// ── Tests ─────────────────────────────────────────────

test "AsyncMetadataFetch SlotState defaults" {
    const slot = AsyncMetadataFetch.Slot{};
    try std.testing.expectEqual(AsyncMetadataFetch.SlotState.free, slot.state);
    try std.testing.expectEqual(@as(posix.fd_t, -1), slot.fd);
    try std.testing.expectEqual(@as(u8, 0), slot.ut_metadata_id);
    try std.testing.expect(slot.send_buf == null);
    try std.testing.expect(slot.recv_buf == null);
}

test "AsyncMetadataFetch create and destroy with no peers" {
    // We need a real io_uring for the create call but won't submit anything
    var io = try RealIO.init(.{ .entries = 4 });
    defer io.deinit();

    const peers = [_]std.net.Address{};
    const mf = try AsyncMetadataFetch.create(
        std.testing.allocator,
        &io,
        [_]u8{0xAA} ** 20,
        [_]u8{0xBB} ** 20,
        6881,
        false,
        &peers,
        null,
        null,
        null,
        null,
    );
    mf.destroy();
}

test "AsyncMetadataFetch create and destroy with peers" {
    var io = try RealIO.init(.{ .entries = 4 });
    defer io.deinit();

    const peers = [_]std.net.Address{
        std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881),
        std.net.Address.initIp4(.{ 127, 0, 0, 2 }, 6882),
    };
    const mf = try AsyncMetadataFetch.create(
        std.testing.allocator,
        &io,
        [_]u8{0xAA} ** 20,
        [_]u8{0xBB} ** 20,
        6881,
        false,
        &peers,
        null,
        null,
        null,
        null,
    );
    // Verify peer count
    try std.testing.expectEqual(@as(u32, 2), mf.peer_count);
    mf.destroy();
}

test "AsyncMetadataFetch start with no peers calls finish" {
    var io = try RealIO.init(.{ .entries = 4 });
    defer io.deinit();

    const TestCtx = struct {
        var completed: bool = false;
        fn onComplete(_: *AsyncMetadataFetch) void {
            completed = true;
        }
    };
    TestCtx.completed = false;

    const peers = [_]std.net.Address{};
    const mf = try AsyncMetadataFetch.create(
        std.testing.allocator,
        &io,
        [_]u8{0xAA} ** 20,
        [_]u8{0xBB} ** 20,
        6881,
        false,
        &peers,
        &TestCtx.onComplete,
        null,
        null,
        null,
    );
    defer mf.destroy();

    mf.start();

    try std.testing.expect(TestCtx.completed);
    try std.testing.expect(mf.done);
    try std.testing.expect(mf.result_bytes == null);
}

test "AsyncMetadataFetch max_slots is 3" {
    try std.testing.expectEqual(@as(u8, 3), AsyncMetadataFetch.max_slots);
}

// Stage 4 zero-alloc shared-buffer integration tests live in
// tests/metadata_fetch_shared_test.zig (the `net` and `io` source-side
// tests aren't yet wired into mod_tests, but the dedicated test step
// `test-metadata-fetch-shared` runs them as part of `zig build test`).
