const std = @import("std");
const log = std.log.scoped(.event_loop);
const DhtEngine = @import("../dht/dht.zig").DhtEngine;
const EventLoop = @import("event_loop.zig").EventLoop;
const utp_handler = @import("utp_handler.zig");

/// Process a UDP datagram as a DHT/KRPC message.
/// Called from the uTP recv handler when the first byte is 'd' (bencode dict).
pub fn handleDhtRecv(self: anytype, data: []const u8, sender: std.net.Address) void {
    const engine = self.dht_engine orelse return;
    engine.handleIncoming(data, sender);

    // Immediately drain any outbound packets queued by the DHT engine
    drainDhtSendQueue(self);
}

/// Periodic DHT tick. Called from the event loop's main tick().
pub fn dhtTick(self: anytype) void {
    const engine = self.dht_engine orelse return;
    const now = self.clock.now();
    engine.tick(now);

    // Drain outbound packets
    drainDhtSendQueue(self);

    // Collect discovered peers and feed them into the peer pipeline
    drainDhtPeerResults(self);
}

/// Drain the DHT engine's outbound send queue and send packets via
/// the shared UDP socket (reusing the uTP send path).
fn drainDhtSendQueue(self: anytype) void {
    const engine = self.dht_engine orelse return;

    const batch = engine.drainSendQueue();
    defer engine.freeSendQueueBatch(batch);

    for (batch) |pkt| {
        // Use the uTP/UDP send path (shared UDP socket)
        utp_handler.utpSendPacket(self, pkt.data[0..pkt.len], pkt.remote);
    }
}

/// Drain DHT peer results and feed discovered peers into the peer
/// connection pipeline.
fn drainDhtPeerResults(self: anytype) void {
    const engine = self.dht_engine orelse return;

    const batch = engine.drainPeerResults();
    defer engine.freePeerResultsBatch(batch);

    for (batch) |result| {
        defer self.allocator.free(result.peers);

        const tid = self.findTorrentIdByInfoHash(&result.info_hash) orelse continue;

        for (result.peers) |peer_addr| {
            // Preserve the DHT lookup target as the outbound handshake hash,
            // so v2 lookups connect to the v2 swarm even for hybrid torrents.
            _ = self.enqueuePeerCandidateWithSwarmHash(peer_addr, tid, result.info_hash, .dht) catch continue;
        }

        log.info("DHT: fed {d} peers for torrent {x}", .{
            result.peers.len,
            result.info_hash[0..4].*,
        });
    }
}
