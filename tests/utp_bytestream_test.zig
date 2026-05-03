const std = @import("std");
const varuna = @import("varuna");
const utp = varuna.net.utp;
const UtpSocket = utp.UtpSocket;
const Header = utp.Header;
const State = utp.State;
const PacketType = utp.PacketType;
const Random = varuna.runtime.Random;
const event_loop_mod = varuna.io.event_loop;
const utp_handler = varuna.io.utp_handler;
const utp_mgr = varuna.net.utp_manager;
const SimIO = varuna.io.sim_io.SimIO;

/// File-scoped sim-seeded CSPRNG for the uTP byte-stream tests.
var bytestream_test_rng: Random = Random.simRandom(0xb71);

// ── Test: Full BT handshake over uTP byte stream ────────────────
//
// Simulates two UtpSockets (client + server) exchanging a 68-byte
// BitTorrent handshake through the uTP ordered byte stream.
//
// The flow:
//   1. Client sends SYN → Server sends SYN-ACK → Client processes ACK
//   2. Client creates DATA packet with 68-byte BT handshake
//   3. Server receives DATA, delivers payload, sends ACK
//   4. Server creates DATA packet with its 68-byte handshake response
//   5. Client receives DATA, delivers payload, sends ACK
//
// If this test fails, the uTP byte stream is broken for BT communication.

test "BT handshake over uTP byte stream" {
    const allocator = std.testing.allocator;

    // ── Step 1: Three-way handshake ──
    var client = UtpSocket{};
    client.allocator = allocator;
    defer client.deinit();

    const syn_pkt = client.connect(&bytestream_test_rng, 1_000_000);
    const syn_hdr = Header.decode(&syn_pkt).?;

    var server = UtpSocket{};
    server.allocator = allocator;
    defer server.deinit();

    const syn_ack_pkt = server.acceptSyn(syn_hdr, 1_001_000);
    const syn_ack_hdr = Header.decode(&syn_ack_pkt).?;

    // Client processes SYN-ACK → connected
    _ = client.processPacket(syn_ack_hdr, &.{}, 1_002_000);
    try std.testing.expectEqual(State.connected, client.state);
    try std.testing.expectEqual(State.connected, server.state);

    // ── Step 2: Client sends 68-byte BT handshake ──
    var bt_handshake_client: [68]u8 = undefined;
    bt_handshake_client[0] = 19; // pstrlen
    @memcpy(bt_handshake_client[1..20], "BitTorrent protocol");
    @memset(bt_handshake_client[20..28], 0); // reserved
    @memset(bt_handshake_client[28..48], 0xAB); // info_hash
    @memset(bt_handshake_client[48..68], 0xCD); // peer_id

    // Create DATA packet
    const data_hdr_bytes = client.createDataPacket(@intCast(bt_handshake_client.len), 1_003_000) orelse {
        std.debug.print("FAIL: createDataPacket returned null (window full?)\n", .{});
        std.debug.print("  cwnd={d} bytesInFlight={d} peer_wnd={d}\n", .{
            client.ledbat.window(), client.bytesInFlight(), client.peer_wnd_size,
        });
        return error.TestUnexpectedResult;
    };

    // Buffer it for retransmission
    var full_pkt: [Header.size + 68]u8 = undefined;
    @memcpy(full_pkt[0..Header.size], &data_hdr_bytes);
    @memcpy(full_pkt[Header.size..], &bt_handshake_client);
    const data_hdr = Header.decode(&data_hdr_bytes).?;
    client.bufferSentPacket(data_hdr.seq_nr, &full_pkt, 68, 1_003_000);

    // ── Step 3: Server receives DATA packet ──
    std.debug.print("\nDEBUG: data_hdr.seq_nr={d} server.ack_nr={d} expected={d}\n", .{
        data_hdr.seq_nr, server.ack_nr, server.ack_nr +% 1,
    });
    std.debug.print("DEBUG: data_hdr.connection_id={d} server.recv_id={d} server.send_id={d}\n", .{
        data_hdr.connection_id, server.recv_id, server.send_id,
    });
    std.debug.print("DEBUG: server.state={s}\n", .{@tagName(server.state)});
    const server_result = server.processPacket(data_hdr, &bt_handshake_client, 1_004_000);

    std.debug.print("DEBUG: result.data={}\n", .{server_result.data != null});

    // Data should be delivered
    try std.testing.expect(server_result.data != null);
    const received_handshake = server_result.data.?;
    try std.testing.expectEqual(@as(usize, 68), received_handshake.len);
    try std.testing.expectEqual(@as(u8, 19), received_handshake[0]);
    try std.testing.expectEqualStrings("BitTorrent protocol", received_handshake[1..20]);

    // ACK should be generated
    try std.testing.expect(server_result.response != null);

    // ── Step 4: Client processes ACK ──
    const ack_hdr = Header.decode(&server_result.response.?).?;
    _ = client.processPacket(ack_hdr, &.{}, 1_005_000);

    // ── Step 5: Server sends its 68-byte BT handshake response ──
    var bt_handshake_server: [68]u8 = undefined;
    bt_handshake_server[0] = 19;
    @memcpy(bt_handshake_server[1..20], "BitTorrent protocol");
    @memset(bt_handshake_server[20..28], 0);
    @memset(bt_handshake_server[28..48], 0xAB); // same info_hash
    @memset(bt_handshake_server[48..68], 0xEF); // different peer_id

    const server_data_hdr_bytes = server.createDataPacket(@intCast(bt_handshake_server.len), 1_006_000) orelse {
        std.debug.print("FAIL: server createDataPacket returned null\n", .{});
        std.debug.print("  cwnd={d} bytesInFlight={d} peer_wnd={d}\n", .{
            server.ledbat.window(), server.bytesInFlight(), server.peer_wnd_size,
        });
        return error.TestUnexpectedResult;
    };

    var server_full_pkt: [Header.size + 68]u8 = undefined;
    @memcpy(server_full_pkt[0..Header.size], &server_data_hdr_bytes);
    @memcpy(server_full_pkt[Header.size..], &bt_handshake_server);
    const server_data_hdr = Header.decode(&server_data_hdr_bytes).?;
    server.bufferSentPacket(server_data_hdr.seq_nr, &server_full_pkt, 68, 1_006_000);

    // ── Step 6: Client receives server's handshake ──
    std.debug.print("DEBUG step6: server_data_hdr.seq_nr={d} client.ack_nr={d} expected={d}\n", .{
        server_data_hdr.seq_nr, client.ack_nr, client.ack_nr +% 1,
    });
    std.debug.print("DEBUG step6: server_data_hdr.connection_id={d} client.recv_id={d}\n", .{
        server_data_hdr.connection_id, client.recv_id,
    });
    const client_result = client.processPacket(server_data_hdr, &bt_handshake_server, 1_007_000);
    std.debug.print("DEBUG step6: result.data={}\n", .{client_result.data != null});

    try std.testing.expect(client_result.data != null);
    const received_response = client_result.data.?;
    try std.testing.expectEqual(@as(usize, 68), received_response.len);
    try std.testing.expectEqual(@as(u8, 19), received_response[0]);
    // Verify it's the server's peer_id
    try std.testing.expectEqual(@as(u8, 0xEF), received_response[48]);

    // ACK should be generated
    try std.testing.expect(client_result.response != null);

    std.debug.print("\nuTP BT handshake exchange: PASSED\n", .{});
}

// ── Test: Multiple BT wire messages over uTP ─────────────────────
//
// After the handshake, BT wire messages (BITFIELD, INTERESTED, UNCHOKE,
// REQUEST, PIECE) flow over the uTP byte stream. This test verifies
// that multiple sequential messages can be sent and received.

test "multiple BT wire messages over uTP byte stream" {
    const allocator = std.testing.allocator;

    // Set up connected pair
    var client = UtpSocket{};
    client.allocator = allocator;
    defer client.deinit();
    var server = UtpSocket{};
    server.allocator = allocator;
    defer server.deinit();

    const syn = client.connect(&bytestream_test_rng, 1_000_000);
    const syn_hdr = Header.decode(&syn).?;
    const syn_ack = server.acceptSyn(syn_hdr, 1_001_000);
    _ = client.processPacket(Header.decode(&syn_ack).?, &.{}, 1_002_000);

    // Server sends: BITFIELD (id=5, 1 byte payload = 0x80 for 1 piece)
    const bitfield_msg = [_]u8{ 0, 0, 0, 2, 5, 0x80 }; // len=2, id=5, bitfield=0x80
    const bf_hdr_bytes = server.createDataPacket(@intCast(bitfield_msg.len), 2_000_000).?;
    const bf_hdr = Header.decode(&bf_hdr_bytes).?;
    var bf_full: [Header.size + 6]u8 = undefined;
    @memcpy(bf_full[0..Header.size], &bf_hdr_bytes);
    @memcpy(bf_full[Header.size..], &bitfield_msg);
    server.bufferSentPacket(bf_hdr.seq_nr, &bf_full, @intCast(bitfield_msg.len), 2_000_000);

    const bf_result = client.processPacket(bf_hdr, &bitfield_msg, 2_001_000);
    try std.testing.expect(bf_result.data != null);
    try std.testing.expectEqual(@as(usize, 6), bf_result.data.?.len);
    // Verify the BT message: length=2, id=5, bitfield=0x80
    try std.testing.expectEqual(@as(u8, 5), bf_result.data.?[4]);
    try std.testing.expectEqual(@as(u8, 0x80), bf_result.data.?[5]);

    // Process ACK
    if (bf_result.response) |resp| {
        _ = server.processPacket(Header.decode(&resp).?, &.{}, 2_002_000);
    }

    // Server sends: UNCHOKE (id=1, no payload)
    const unchoke_msg = [_]u8{ 0, 0, 0, 1, 1 }; // len=1, id=1
    const uc_hdr_bytes = server.createDataPacket(@intCast(unchoke_msg.len), 3_000_000).?;
    const uc_hdr = Header.decode(&uc_hdr_bytes).?;
    var uc_full: [Header.size + 5]u8 = undefined;
    @memcpy(uc_full[0..Header.size], &uc_hdr_bytes);
    @memcpy(uc_full[Header.size..], &unchoke_msg);
    server.bufferSentPacket(uc_hdr.seq_nr, &uc_full, @intCast(unchoke_msg.len), 3_000_000);

    const uc_result = client.processPacket(uc_hdr, &unchoke_msg, 3_001_000);
    try std.testing.expect(uc_result.data != null);
    try std.testing.expectEqual(@as(usize, 5), uc_result.data.?.len);
    try std.testing.expectEqual(@as(u8, 1), uc_result.data.?[4]); // UNCHOKE

    // Client sends: INTERESTED (id=2)
    const interested_msg = [_]u8{ 0, 0, 0, 1, 2 }; // len=1, id=2
    const int_hdr_bytes = client.createDataPacket(@intCast(interested_msg.len), 4_000_000).?;
    const int_hdr = Header.decode(&int_hdr_bytes).?;
    var int_full: [Header.size + 5]u8 = undefined;
    @memcpy(int_full[0..Header.size], &int_hdr_bytes);
    @memcpy(int_full[Header.size..], &interested_msg);
    client.bufferSentPacket(int_hdr.seq_nr, &int_full, @intCast(interested_msg.len), 4_000_000);

    const int_result = server.processPacket(int_hdr, &interested_msg, 4_001_000);
    try std.testing.expect(int_result.data != null);
    try std.testing.expectEqual(@as(u8, 2), int_result.data.?[4]); // INTERESTED

    std.debug.print("\nuTP multiple BT messages: PASSED\n", .{});
}

// ── Test: Large message fragmentation round-trip ─────────────────
//
// A PIECE message (16KB+ data) must be fragmented into multiple uTP
// DATA packets. This test verifies the sender fragments correctly and
// the receiver reassembles in order.

test "fragmented PIECE message over uTP" {
    const allocator = std.testing.allocator;

    var client = UtpSocket{};
    client.allocator = allocator;
    defer client.deinit();
    var server = UtpSocket{};
    server.allocator = allocator;
    defer server.deinit();

    // Connect
    const syn = client.connect(&bytestream_test_rng, 1_000_000);
    const syn_hdr = Header.decode(&syn).?;
    const syn_ack = server.acceptSyn(syn_hdr, 1_001_000);
    _ = client.processPacket(Header.decode(&syn_ack).?, &.{}, 1_002_000);

    // Server sends a simulated PIECE message header (4+1+4+4 = 13 bytes header + data)
    // For simplicity, just send 2000 bytes of data (exceeds single MTU)
    var piece_data: [2000]u8 = undefined;
    for (&piece_data, 0..) |*b, i| b.* = @truncate(i *% 137);

    // Fragment into MTU-sized chunks
    const max_payload = 1400 - Header.size;
    var offset: usize = 0;
    var packets_sent: u32 = 0;
    while (offset < piece_data.len) {
        const chunk_len = @min(piece_data.len - offset, max_payload);
        const hdr_bytes = server.createDataPacket(@intCast(chunk_len), 5_000_000 + packets_sent * 1000) orelse {
            std.debug.print("FAIL: createDataPacket null at offset={d} cwnd={d} inflight={d}\n", .{
                offset, server.ledbat.window(), server.bytesInFlight(),
            });
            return error.TestUnexpectedResult;
        };
        const hdr = Header.decode(&hdr_bytes).?;

        // Buffer for retransmission
        const buf = try allocator.alloc(u8, Header.size + chunk_len);
        defer allocator.free(buf);
        @memcpy(buf[0..Header.size], &hdr_bytes);
        @memcpy(buf[Header.size..], piece_data[offset..][0..chunk_len]);
        server.bufferSentPacket(hdr.seq_nr, buf, @intCast(chunk_len), 5_000_000 + packets_sent * 1000);

        // Client receives this chunk
        const result = client.processPacket(hdr, piece_data[offset..][0..chunk_len], 5_000_500 + packets_sent * 1000);
        try std.testing.expect(result.data != null);
        try std.testing.expectEqual(chunk_len, result.data.?.len);

        // Verify data matches
        try std.testing.expectEqualSlices(u8, piece_data[offset..][0..chunk_len], result.data.?);

        // Process ACK
        if (result.response) |resp| {
            _ = server.processPacket(Header.decode(&resp).?, &.{}, 5_001_000 + packets_sent * 1000);
        }

        offset += chunk_len;
        packets_sent += 1;
    }

    try std.testing.expect(packets_sent >= 2); // should need at least 2 packets
    std.debug.print("\nuTP fragmented PIECE ({d} bytes, {d} packets): PASSED\n", .{ piece_data.len, packets_sent });
}

test "uTP sender resumes window-limited byte stream after ACK" {
    const allocator = std.testing.allocator;
    const EL = event_loop_mod.EventLoopOf(SimIO);

    const sim_io = try SimIO.init(allocator, .{ .seed = 0x757470 });
    var el = try EL.initBareWithIO(allocator, sim_io, 0);
    defer el.deinit();
    el.clock = varuna.runtime.Clock.simAtNs(5_000_000_123);
    el.random = event_loop_mod.Random.simRandom(0x75747001);

    const mgr = try allocator.create(utp_mgr.UtpManager);
    mgr.* = utp_mgr.UtpManager.init(allocator);
    el.utp_manager = mgr;

    const remote = std.net.Address.initIp4(.{ 127, 0, 0, 1 }, 6881);
    const conn = try mgr.connect(&el.random, remote, 1_000_000);
    const sock = mgr.getSocket(conn.slot).?;

    const syn_ack = (Header{
        .packet_type = .st_state,
        .extension = .none,
        .connection_id = sock.recv_id,
        .timestamp_us = 1_001_000,
        .timestamp_diff_us = 1_000,
        .wnd_size = utp.default_recv_window,
        .seq_nr = 1,
        .ack_nr = 1,
    }).encode();
    _ = mgr.processPacket(&syn_ack, remote, 1_002_000);
    try std.testing.expectEqual(State.connected, sock.state);
    try std.testing.expectEqual(@as(u16, 0), sock.out_buf_count);

    const peer_slot: u16 = 0;
    el.peers[peer_slot] = event_loop_mod.Peer{
        .fd = -1,
        .state = .active_recv_header,
        .mode = .inbound,
        .transport = .utp,
        .address = remote,
        .utp_slot = conn.slot,
    };
    el.peer_count = 1;
    el.markActivePeer(peer_slot);

    var payload: [utp.max_payload * 4]u8 = undefined;
    for (&payload, 0..) |*byte, i| byte.* = @truncate(i);

    try utp_handler.utpSendData(&el, peer_slot, &payload);
    try std.testing.expectEqual(@as(u32, 5_000_000), sock.last_send_time_us);
    const seq_after_first_send = sock.seq_nr;
    const bytes_in_flight = sock.bytesInFlight();
    try std.testing.expect(bytes_in_flight > 0);
    try std.testing.expect(bytes_in_flight < payload.len);

    // Keep the synthetic ACK on the sender's uTP clock so RTT sampling sees
    // a small positive delta instead of a wrapped timestamp.
    const ack_now = sock.last_send_time_us +% 1_000;
    const ack = (Header{
        .packet_type = .st_state,
        .extension = .none,
        .connection_id = sock.recv_id,
        .timestamp_us = ack_now -% 500,
        .timestamp_diff_us = 1_000,
        .wnd_size = utp.default_recv_window,
        .seq_nr = 1,
        .ack_nr = seq_after_first_send -% 1,
    }).encode();
    _ = mgr.processPacket(&ack, remote, ack_now);

    try utp_handler.utpSendData(&el, peer_slot, &.{});

    try std.testing.expect(sock.seq_nr > seq_after_first_send);
}
