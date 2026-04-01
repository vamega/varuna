const std = @import("std");
const log = std.log.scoped(.event_loop);
const DhtEngine = @import("../dht/dht.zig").DhtEngine;
const EventLoop = @import("event_loop.zig").EventLoop;
const utp_handler = @import("utp_handler.zig");

/// Process a UDP datagram as a DHT/KRPC message.
/// Called from the uTP recv handler when the first byte is 'd' (bencode dict).
pub fn handleDhtRecv(self: *EventLoop, data: []const u8, sender: std.net.Address) void {
    const engine = self.dht_engine orelse return;
    engine.handleIncoming(data, sender);

    // Immediately drain any outbound packets queued by the DHT engine
    drainDhtSendQueue(self);
}

/// Periodic DHT tick. Called from the event loop's main tick().
pub fn dhtTick(self: *EventLoop) void {
    const engine = self.dht_engine orelse return;
    const now = std.time.timestamp();
    engine.tick(now);

    // Drain outbound packets
    drainDhtSendQueue(self);

    // Collect discovered peers and feed them into the peer pipeline
    drainDhtPeerResults(self);
}

/// Drain the DHT engine's outbound send queue and send packets via
/// the shared UDP socket (reusing the uTP send path).
fn drainDhtSendQueue(self: *EventLoop) void {
    const engine = self.dht_engine orelse return;

    while (engine.send_queue.items.len > 0) {
        const pkt = engine.send_queue.orderedRemove(0);
        // Use the uTP/UDP send path (shared UDP socket)
        utp_handler.utpSendPacket(self, pkt.data[0..pkt.len], pkt.remote);
    }
}

/// Drain DHT peer results and feed discovered peers into the peer
/// connection pipeline.
fn drainDhtPeerResults(self: *EventLoop) void {
    const engine = self.dht_engine orelse return;

    while (engine.peer_results.items.len > 0) {
        const result = engine.peer_results.orderedRemove(0);
        defer self.allocator.free(result.peers);

        const tid = self.findTorrentIdByInfoHash(&result.info_hash) orelse continue;

        // Feed peers into the event loop's connection pipeline.
        // Reuse the same path as tracker-discovered peers.
        for (result.peers) |peer_addr| {
            // Check connection limits before connecting
            if (self.peer_count >= self.max_connections) break;
            if (self.half_open_count >= self.max_half_open) break;

            // Count per-torrent connections
            var torrent_peers: u32 = 0;
            for (self.peers) |*peer| {
                if (peer.state != .free and peer.torrent_id == tid) {
                    torrent_peers += 1;
                }
            }
            if (torrent_peers >= self.max_peers_per_torrent) break;

            // Deduplicate: skip if already connected to this address
            var already_connected = false;
            for (self.peers) |*peer| {
                if (peer.state != .free and addressEql(peer.address, peer_addr)) {
                    already_connected = true;
                    break;
                }
            }
            if (already_connected) continue;

            // Initiate connection via the standard peer pipeline.
            _ = self.addPeerForTorrent(peer_addr, tid) catch continue;
        }

        log.info("DHT: fed {d} peers for torrent {x}", .{
            result.peers.len,
            result.info_hash[0..4].*,
        });
    }
}

fn addressEql(a: std.net.Address, b: std.net.Address) bool {
    return a.in.sa.addr == b.in.sa.addr and a.in.sa.port == b.in.sa.port;
}
