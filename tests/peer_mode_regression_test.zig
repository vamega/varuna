const std = @import("std");
const varuna = @import("varuna");

const EventLoop = varuna.io.event_loop.EventLoop;
const Peer = varuna.io.event_loop.Peer;
const processMessage = varuna.io.protocol.processMessage;

// Regression tests for commit 3af560a (large-20m-64k stall).
//
// The peer wire protocol handlers used `peer.mode` — which records which
// side opened the TCP connection — as if it indicated "who serves pieces"
// vs "who requests pieces". Four code paths had a `peer.mode == .inbound`
// gate that silently broke the transfer when a seeder dialed the leecher
// (e.g. after the tracker handed the seeder the leecher's address).
//
// This test drives processMessage directly — no sockets, no tracker, no
// kernel timing — so it deterministically fails against the pre-fix
// source and deterministically passes against 3af560a onward.
//
// Why only one of the four bugs is covered here: the BITFIELD / HAVE /
// REQUEST handlers require additional context (session, seed handler,
// torrent complete_pieces) that the current test helpers don't provide
// ergonomically. Extending the coverage would require either extracting
// the gate decisions into pure functions or building a richer test
// fixture. Tracked as follow-up; the INTERESTED handler covered below is
// the most load-bearing of the four bugs because it directly controlled
// whether the seeder ever unchoked the leecher.

const testing = std.testing;

test "INTERESTED auto-unchokes an outbound-mode peer (regression: large-20m-64k)" {
    // Simulates the seeder's side of a seeder-initiated connection: the
    // seeder dialed out, so from its view the peer has mode=outbound —
    // even though the seeder is the one with pieces to serve. Pre-fix,
    // the auto-unchoke gate was `peer.mode == .inbound and peer.am_choking`,
    // so the seeder stayed choking and the leecher never got an UNCHOKE
    // in time for the test matrix's polling window.
    var el = try EventLoop.initBare(testing.allocator, 0);
    defer el.deinit();

    const empty_fds = [_]std.posix.fd_t{};
    _ = try el.addTorrentContext(.{
        .shared_fds = empty_fds[0..],
        .info_hash = [_]u8{0} ** 20,
        .peer_id = [_]u8{0} ** 20,
    });

    const slot: u16 = 0;
    const peer = &el.peers[slot];
    peer.* = Peer{};
    peer.fd = -1;
    peer.state = .active_recv_header;
    peer.torrent_id = 0;
    peer.mode = .outbound;
    peer.am_choking = true;
    peer.body_buf = peer.small_body_buf[0..1];
    peer.body_expected = 0;
    peer.body_offset = 0;

    peer.small_body_buf[0] = 2; // INTERESTED
    processMessage(&el, slot);

    try testing.expect(peer.peer_interested);
    // Load-bearing assertion: post-fix this flips to false; pre-fix it
    // stays true because the gate required mode=inbound.
    try testing.expect(!peer.am_choking);
}
