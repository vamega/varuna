const std = @import("std");
const log = std.log.scoped(.dht);
const address = @import("../net/address.zig");
const node_id = @import("node_id.zig");
const NodeId = node_id.NodeId;
const NodeInfo = node_id.NodeInfo;
const routing_table = @import("routing_table.zig");
const RoutingTable = routing_table.RoutingTable;
const krpc = @import("krpc.zig");
const token = @import("token.zig");
const TokenManager = token.TokenManager;
const lookup = @import("lookup.zig");
const Lookup = lookup.Lookup;
const bootstrap = @import("bootstrap.zig");
const Random = @import("../runtime/random.zig").Random;

/// Maximum number of concurrent lookups.
const max_lookups: usize = 16;

/// Maximum registered auto-search hashes. This is dynamic storage, not
/// the old fixed 16-hash slate; the cap is a defensive ceiling so an
/// unbounded number of public torrents cannot grow DHT memory forever.
const max_registered_searches: usize = 4096;

/// Maximum pending outbound queries.
const max_pending: usize = 256;

/// Query timeout in seconds.
const query_timeout_secs: i64 = 15;

/// DHT tick interval (seconds). The event loop calls dhtTick at this rate.
pub const tick_interval_secs: i64 = 5;

/// Announce refresh interval (seconds).
const announce_refresh_secs: i64 = 30 * 60;

/// Node save interval (seconds).
const save_interval_secs: i64 = 30 * 60;

/// Pending outbound query (awaiting response).
const PendingQuery = struct {
    transaction_id: u16,
    target_id: NodeId, // node we queried
    target_addr: std.net.Address,
    sent_at: i64,
    lookup_idx: ?usize = null, // index into active_lookups
    method: krpc.Method,
};

const SearchRegistration = struct {
    hash: [20]u8,
    done: bool = false,
};

/// An outbound packet queued for sending via io_uring.
pub const OutboundPacket = struct {
    data: [1500]u8 = undefined,
    len: usize = 0,
    remote: std.net.Address,
};

/// Peer-store for `announce_peer` per BEP 5 §"Peers".
///
/// Acts as a tiny ephemeral peer tracker: peers tell us "I have this
/// info-hash on this port" via `announce_peer`, and later `get_peers`
/// queries return the list back in `values` / `values6`. Without this,
/// our DHT would lie ("yes, I'll remember") but never serve any
/// announced peer back — every `get_peers` would fall through to
/// closest-nodes only.
///
/// Per BEP 5 the peer is reachable for ~30 minutes; the announcer is
/// expected to refresh every ~30 minutes, so any unrefreshed entry is
/// safely evicted at TTL. Per-info-hash capacity is bounded to defend
/// against memory exhaustion from a single hash flooded with announces;
/// at-cap eviction is FIFO (oldest entry replaced first).
const PeerStore = struct {
    /// BEP 5 default expiry. Sender re-announces every ~30 minutes.
    pub const ttl_secs: i64 = 30 * 60;
    /// Bounded per-info-hash capacity. libtorrent and rakshasa cap
    /// somewhere between 30 and 100; we use 100 as a defensive ceiling
    /// so a single hash cannot dominate memory.
    pub const max_peers_per_hash: usize = 100;

    const Entry = struct {
        address: std.net.Address,
        expires_at: i64,
    };

    const PeerList = std.ArrayListUnmanaged(Entry);

    map: std.AutoHashMap([20]u8, PeerList),

    pub fn init(allocator: std.mem.Allocator) PeerStore {
        return .{ .map = std.AutoHashMap([20]u8, PeerList).init(allocator) };
    }

    pub fn deinit(self: *PeerStore, allocator: std.mem.Allocator) void {
        var it = self.map.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        self.map.deinit();
    }

    /// Record an announce for `info_hash` from `peer_addr`.
    ///
    /// If `peer_addr` is already in the list for this hash, refresh its
    /// expiry. Otherwise append. When the list is at capacity, evict
    /// the oldest entry (FIFO) and replace with the new one.
    ///
    /// The `peer_addr` parameter is named to avoid shadowing the
    /// outer-module `const address = @import("../net/address.zig")`.
    pub fn announce(
        self: *PeerStore,
        allocator: std.mem.Allocator,
        info_hash: [20]u8,
        peer_addr: std.net.Address,
        now: i64,
    ) void {
        const gop = self.map.getOrPut(info_hash) catch return;
        if (!gop.found_existing) {
            gop.value_ptr.* = .empty;
        }
        var list = gop.value_ptr;

        // Refresh existing entry: same family, same address.
        for (list.items) |*e| {
            if (addressesEqual(e.address, peer_addr)) {
                e.expires_at = now + ttl_secs;
                return;
            }
        }

        // New entry. FIFO eviction at capacity.
        if (list.items.len >= max_peers_per_hash) {
            // Drop the oldest entry; later items shift down. ArrayList
            // does not expose a dedicated "pop_front" primitive, so we
            // do it explicitly. The list is bounded to <=100, so
            // O(n) shift is fine.
            const tail = list.items[1..];
            std.mem.copyForwards(Entry, list.items[0 .. list.items.len - 1], tail);
            list.items.len -= 1;
        }
        list.append(allocator, .{
            .address = peer_addr,
            .expires_at = now + ttl_secs,
        }) catch return;
    }

    /// Pack non-expired peers for `info_hash` into the caller-supplied
    /// IPv4 and IPv6 buffers and return the populated counts.
    /// Capped at the buffer lengths.
    pub fn encodeValues(
        self: *PeerStore,
        info_hash: [20]u8,
        v4_buf: *[max_peers_per_hash][6]u8,
        v6_buf: *[max_peers_per_hash][18]u8,
        now: i64,
    ) struct { v4: usize, v6: usize } {
        const list = self.map.getPtr(info_hash) orelse return .{ .v4 = 0, .v6 = 0 };
        var v4: usize = 0;
        var v6: usize = 0;
        for (list.items) |e| {
            if (e.expires_at <= now) continue;
            switch (e.address.any.family) {
                std.posix.AF.INET => {
                    if (v4 >= v4_buf.len) continue;
                    const addr_bytes: [4]u8 = @bitCast(e.address.in.sa.addr);
                    @memcpy(v4_buf[v4][0..4], &addr_bytes);
                    std.mem.writeInt(u16, v4_buf[v4][4..6], e.address.getPort(), .big);
                    v4 += 1;
                },
                std.posix.AF.INET6 => {
                    if (v6 >= v6_buf.len) continue;
                    @memcpy(v6_buf[v6][0..16], &e.address.in6.sa.addr);
                    std.mem.writeInt(u16, v6_buf[v6][16..18], e.address.getPort(), .big);
                    v6 += 1;
                },
                else => continue,
            }
        }
        return .{ .v4 = v4, .v6 = v6 };
    }

    /// Drop expired entries everywhere. Empty per-hash lists are
    /// removed entirely so memory does not accumulate after a churn
    /// of one-shot announces.
    pub fn sweep(self: *PeerStore, allocator: std.mem.Allocator, now: i64) void {
        // Two-pass: first prune expired entries from each list (in
        // place, swap-remove), then collect-and-remove now-empty lists.
        // Iterators don't allow deletion during traversal, so we pre-
        // collect keys to remove.
        var stale_keys: [16][20]u8 = undefined;
        var stale_count: usize = 0;

        var it = self.map.iterator();
        while (it.next()) |kv| {
            var list = kv.value_ptr;
            var i: usize = 0;
            while (i < list.items.len) {
                if (list.items[i].expires_at <= now) {
                    _ = list.swapRemove(i);
                } else {
                    i += 1;
                }
            }
            if (list.items.len == 0) {
                if (stale_count < stale_keys.len) {
                    stale_keys[stale_count] = kv.key_ptr.*;
                    stale_count += 1;
                }
                // If the prune batch is full this iteration, the
                // remaining empty lists get reaped on the next sweep —
                // not a leak, just deferred work.
            }
        }
        for (stale_keys[0..stale_count]) |k| {
            if (self.map.fetchRemove(k)) |kv| {
                var list = kv.value;
                list.deinit(allocator);
            }
        }
    }

    /// Number of unique info-hashes currently tracked (for tests).
    pub fn hashCount(self: *const PeerStore) usize {
        return self.map.count();
    }

    /// Number of peers stored for an info-hash (for tests).
    pub fn peerCount(self: *PeerStore, info_hash: [20]u8) usize {
        const list = self.map.getPtr(info_hash) orelse return 0;
        return list.items.len;
    }
};

/// Compare two `std.net.Address` values for equality of the on-wire
/// peer identity (family + IP + port). Mirrors `address.addressEql`'s
/// shape but is restricted to v4/v6 and includes the port.
fn addressesEqual(a: std.net.Address, b: std.net.Address) bool {
    if (a.any.family != b.any.family) return false;
    if (a.getPort() != b.getPort()) return false;
    return switch (a.any.family) {
        std.posix.AF.INET => a.in.sa.addr == b.in.sa.addr,
        std.posix.AF.INET6 => std.mem.eql(u8, &a.in6.sa.addr, &b.in6.sa.addr),
        else => false,
    };
}

/// DHT engine (BEP 5). Manages the routing table, processes incoming
/// KRPC messages, drives iterative lookups, and produces outbound packets
/// for the event loop to send via io_uring SENDMSG.
pub const DhtEngine = struct {
    allocator: std.mem.Allocator,
    /// Daemon-wide CSPRNG. Borrowed (not owned) — typically points
    /// into the shared `EventLoop.random`. Used for node-ID
    /// generation (bucket refresh, lookup target seeding) and token
    /// rotation. Same source for production and sim.
    random: *Random,
    own_id: NodeId,
    table: RoutingTable,
    tokens: TokenManager,
    next_txn_id: u16 = 1,
    pending: [max_pending]?PendingQuery = [_]?PendingQuery{null} ** max_pending,
    active_lookups: [max_lookups]?Lookup = [_]?Lookup{null} ** max_lookups,
    /// Outbound packet queue. The event loop drains this via dhtDrainSendQueue.
    send_queue: std.ArrayList(OutboundPacket),
    /// Peer results from completed get_peers lookups.
    /// The event loop picks these up and feeds them into the peer pipeline.
    peer_results: std.ArrayList(PeerResult),
    /// Peers announced to us via `announce_peer` (BEP 5). Returned in
    /// `values` / `values6` of subsequent `get_peers` responses.
    peer_store: PeerStore,
    /// Listen port for announce_peer (the daemon's peer listen port).
    listen_port: u16 = 6881,
    /// Bootstrapping state.
    bootstrapped: bool = false,
    bootstrap_pending: bool = false,
    /// Auto-search: info hashes to search for once bootstrapped.
    /// get_peers will be called for each once the routing table has nodes.
    pending_searches: std.ArrayListUnmanaged(SearchRegistration),
    last_requery_time: i64 = 0,
    /// Timing.
    last_refresh_check: i64 = 0,
    last_save_time: i64 = 0,
    /// Whether DHT is enabled (disabled for private-only sessions).
    enabled: bool = true,

    pub const PeerResult = struct {
        info_hash: [20]u8,
        peers: []std.net.Address,
    };

    /// Export all nodes from the routing table for persistence.
    /// Caller owns the returned slice.
    pub fn exportNodes(self: *const DhtEngine, allocator: std.mem.Allocator) ![]NodeInfo {
        var nodes = std.ArrayList(NodeInfo).empty;
        errdefer nodes.deinit(allocator);
        for (&self.table.buckets) |*bucket| {
            for (bucket.getNodes()) |node| {
                try nodes.append(allocator, node);
            }
        }
        return nodes.toOwnedSlice(allocator);
    }

    /// Seed the routing table from previously persisted nodes.
    pub fn loadPersistedNodes(self: *DhtEngine, nodes: []const NodeInfo) void {
        for (nodes) |node| {
            _ = self.table.addNode(node, node.last_seen);
        }
        // If we loaded enough nodes, skip the slow bootstrap process
        if (self.table.nodeCount() >= 8) {
            self.bootstrapped = true;
        }
    }

    pub fn init(allocator: std.mem.Allocator, random: *Random, own_id: NodeId) DhtEngine {
        return .{
            .allocator = allocator,
            .random = random,
            .own_id = own_id,
            .table = RoutingTable.init(own_id),
            .tokens = TokenManager.init(random),
            .send_queue = std.ArrayList(OutboundPacket).empty,
            .peer_results = std.ArrayList(PeerResult).empty,
            .peer_store = PeerStore.init(allocator),
            .pending_searches = .empty,
        };
    }

    /// Heap-allocate and initialize a DhtEngine without placing a large
    /// (~1 MB) struct value on the caller's stack. DhtEngine contains:
    ///   - RoutingTable: 160 KBuckets × 8 NodeInfos = ~183 KB
    ///   - pending[256]?PendingQuery = ~39 KB
    ///   - active_lookups[16]?Lookup  = ~688 KB
    /// Assigning these as struct literals would create large stack temporaries.
    /// Instead we initialize each field individually via pointer dereference,
    /// and use explicit loops for the large arrays so Zig writes directly
    /// into the heap allocation.
    pub fn create(allocator: std.mem.Allocator, random: *Random, own_id: NodeId) !*DhtEngine {
        const self = try allocator.create(DhtEngine);
        self.allocator = allocator;
        self.random = random;
        self.own_id = own_id;
        // Initialize the routing table in place (160 KBuckets).
        self.table.own_id = own_id;
        for (&self.table.buckets) |*b| {
            b.count = 0;
            b.last_changed = 0;
            // nodes[] intentionally left undefined (count=0, so never read).
        }
        self.tokens = TokenManager.init(random);
        self.next_txn_id = 1;
        // Initialize nullable arrays via explicit loops to avoid ~38 KB / ~688 KB
        // stack temporaries that would arise from array-literal assignment.
        for (&self.pending) |*p| p.* = null;
        for (&self.active_lookups) |*l| l.* = null;
        self.send_queue = std.ArrayList(OutboundPacket).empty;
        self.peer_results = std.ArrayList(PeerResult).empty;
        self.peer_store = PeerStore.init(allocator);
        self.listen_port = 6881;
        self.bootstrapped = false;
        self.bootstrap_pending = false;
        self.pending_searches = .empty;
        self.last_requery_time = 0;
        self.last_refresh_check = 0;
        self.last_save_time = 0;
        self.enabled = true;
        return self;
    }

    pub fn deinit(self: *DhtEngine) void {
        for (self.peer_results.items) |result| {
            self.allocator.free(result.peers);
        }
        self.peer_results.deinit(self.allocator);
        self.send_queue.deinit(self.allocator);
        self.pending_searches.deinit(self.allocator);
        self.peer_store.deinit(self.allocator);
    }

    /// Process an incoming UDP datagram that starts with 'd' (KRPC).
    /// Called from the event loop's UDP recv handler.
    pub fn handleIncoming(self: *DhtEngine, data: []const u8, sender: std.net.Address) void {
        if (!self.enabled) return;
        if (data.len < 2 or data[0] != 'd') return;

        const msg = krpc.parse(data) catch {
            log.debug("malformed KRPC from {f}", .{sender});
            return;
        };

        switch (msg) {
            .query => |q| self.handleQuery(q, sender),
            .response => |r| self.handleResponse(r, sender),
            .@"error" => |e| self.handleError(e, sender),
        }
    }

    /// Periodic tick. Called every ~5 seconds from the event loop.
    pub fn tick(self: *DhtEngine, now: i64) void {
        if (!self.enabled) return;

        // Rotate token secrets
        self.tokens.maybeRotate(self.random, now);

        // Sweep expired peer-store entries so memory stays bounded
        // even when no `get_peers` query triggers the lazy sweep.
        self.peer_store.sweep(self.allocator, now);

        // Check for query timeouts
        self.checkTimeouts(now);

        // Drive active lookups forward
        self.driveLookups(now);

        // Bootstrap if needed.
        // If bootstrap_pending but no active lookups remain (they all completed or
        // timed out), reset bootstrap_pending so we retry on the next tick.
        if (self.bootstrap_pending) {
            const has_active = for (self.active_lookups) |lk| {
                if (lk != null) break true;
            } else false;
            if (!has_active) self.bootstrap_pending = false;
        }
        if (!self.bootstrapped and !self.bootstrap_pending) {
            if (self.table.nodeCount() < routing_table.K) {
                self.startBootstrap(now);
            } else {
                self.bootstrapped = true;
            }
        }

        // Bucket refresh
        if (now - self.last_refresh_check >= tick_interval_secs) {
            self.last_refresh_check = now;
            if (self.table.needsRefresh(now)) |bucket_idx| {
                self.refreshBucket(bucket_idx, now);
            }
        }

        // Start pending searches once bootstrapped, and re-query every 5 minutes
        const requery_interval: i64 = 5 * 60;
        if (self.bootstrapped and self.pending_searches.items.len > 0) {
            const should_requery = (now - self.last_requery_time >= requery_interval);
            for (self.pending_searches.items) |*search| {
                // Start new searches immediately; requery old ones on the interval
                if (!search.done or should_requery) {
                    self.getPeers(search.hash) catch |err| {
                        log.debug("getPeers for {x} failed: {s}", .{ search.hash[0..4].*, @errorName(err) });
                        continue;
                    };
                    search.done = true;
                }
            }
            if (should_requery) self.last_requery_time = now;
        }
    }

    /// Register an info_hash for peer search. The DHT engine will start
    /// get_peers lookups automatically once bootstrapped, and re-query
    /// periodically. Call this before or after the engine is bootstrapped.
    ///
    /// BEP 52: for hybrid torrents, pass the v2 info_hash truncated to its
    /// first 20 bytes as `info_hash_v2_truncated`. Both hashes are
    /// registered as independent searches so that v1-only and v2-only
    /// peers both find us via the DHT. Pure-v1 callers pass `null`.
    pub fn requestPeers(
        self: *DhtEngine,
        info_hash: [20]u8,
        info_hash_v2_truncated: ?[20]u8,
    ) void {
        self.registerSearch(info_hash);
        if (info_hash_v2_truncated) |v2| self.registerSearch(v2);
    }

    /// Force an immediate requery for an already-registered info hash.
    /// Used when a torrent is integrated into the event loop after the
    /// initial get_peers results were dropped (torrent wasn't registered yet).
    ///
    /// BEP 52: pass the truncated v2 hash for hybrid torrents so both
    /// hashes are requeried. See `requestPeers` for the v2 truncation rule.
    pub fn forceRequery(
        self: *DhtEngine,
        info_hash: [20]u8,
        info_hash_v2_truncated: ?[20]u8,
    ) void {
        self.requerySearch(info_hash);
        if (info_hash_v2_truncated) |v2| self.requerySearch(v2);
    }

    /// Append a single hash to the pending-search slate. Idempotent.
    fn registerSearch(self: *DhtEngine, hash: [20]u8) void {
        for (self.pending_searches.items) |search| {
            if (std.mem.eql(u8, &search.hash, &hash)) return;
        }
        if (self.pending_searches.items.len >= max_registered_searches) {
            log.warn("DHT search registry full at {d} hashes; dropping search for {x}", .{
                max_registered_searches,
                hash[0..4].*,
            });
            return;
        }
        self.pending_searches.append(self.allocator, .{
            .hash = hash,
            .done = false,
        }) catch |err| {
            log.warn("DHT search registry allocation failed for {x}: {s}", .{
                hash[0..4].*,
                @errorName(err),
            });
        };
    }

    /// Mark a previously-registered hash as needing immediate requery, or
    /// register it fresh if absent.
    fn requerySearch(self: *DhtEngine, hash: [20]u8) void {
        for (self.pending_searches.items) |*search| {
            if (std.mem.eql(u8, &search.hash, &hash)) {
                search.done = false; // triggers immediate search on next tick
                return;
            }
        }
        self.registerSearch(hash);
    }

    /// Start a get_peers lookup for a torrent info-hash.
    /// Discovered peers will appear in peer_results.
    pub fn getPeers(self: *DhtEngine, info_hash: [20]u8) !void {
        if (!self.enabled) return error.DhtDisabled;

        // Skip if a lookup for this hash is already active
        for (0..max_lookups) |i| {
            if (self.active_lookups[i]) |*lk| {
                if (std.mem.eql(u8, &lk.target, &info_hash)) return;
            }
        }

        // Find a free lookup slot
        const idx = for (0..max_lookups) |i| {
            if (self.active_lookups[i] == null) break i;
        } else return error.TooManyLookups;

        var lk = Lookup.init(info_hash, .get_peers);
        lk.seed(&self.table);

        if (lk.candidate_count == 0) return error.NoNodes;

        self.active_lookups[idx] = lk;
        self.sendLookupQueries(idx);
    }

    /// Announce to the DHT that we have a torrent on the given port.
    /// Performs a get_peers lookup first to collect tokens, then
    /// sends announce_peer to the K closest nodes.
    ///
    /// BEP 52: for hybrid torrents, pass the v2 info_hash truncated to its
    /// first 20 bytes as `info_hash_v2_truncated`. Both hashes are
    /// announced so v1-only and v2-only peers can find us. Pure-v1
    /// callers pass `null`.
    ///
    /// If a v2 lookup cannot be started (e.g. no nodes for that hash yet),
    /// we still try the v1 announce so the v1 swarm benefits — and vice
    /// versa. The function only surfaces an error when both attempts fail.
    pub fn announcePeer(
        self: *DhtEngine,
        info_hash: [20]u8,
        info_hash_v2_truncated: ?[20]u8,
        port: u16,
    ) !void {
        if (!self.enabled) return error.DhtDisabled;

        // For now, just start a get_peers lookup. When it completes,
        // we'll send announce_peer messages using the collected tokens.
        // This is handled in completeLookup().
        self.listen_port = port;

        const v1_err: ?anyerror = if (self.getPeers(info_hash)) |_| null else |e| e;
        const v2_err: ?anyerror = if (info_hash_v2_truncated) |v2|
            (if (self.getPeers(v2)) |_| null else |e| e)
        else
            null;

        // If both attempts errored, surface one (prefer v1).
        if (v1_err) |e1| {
            if (info_hash_v2_truncated == null) return e1;
            if (v2_err != null) return e1;
        } else if (v2_err) |e2| {
            // v1 succeeded, v2 failed — log but don't fail the call.
            log.debug("DHT announce v2 failed: {s}", .{@errorName(e2)});
        }
    }

    /// Drain the outbound send queue. Returns packets for the event loop to send.
    pub fn drainSendQueue(self: *DhtEngine) []OutboundPacket {
        const items = self.send_queue.items;
        if (items.len == 0) return &.{};
        // Move items out
        const result = self.allocator.alloc(OutboundPacket, items.len) catch return &.{};
        @memcpy(result, items);
        self.send_queue.clearRetainingCapacity();
        return result;
    }

    /// Drain peer results. Returns discovered peers for the event loop.
    pub fn drainPeerResults(self: *DhtEngine) []PeerResult {
        const items = self.peer_results.items;
        if (items.len == 0) return &.{};
        const result = self.allocator.alloc(PeerResult, items.len) catch return &.{};
        @memcpy(result, items);
        self.peer_results.clearRetainingCapacity();
        return result;
    }

    /// Number of nodes in the routing table.
    pub fn nodeCount(self: *const DhtEngine) usize {
        return self.table.nodeCount();
    }

    /// Number of auto-search hashes registered for periodic get_peers.
    pub fn registeredSearchCount(self: *const DhtEngine) usize {
        return self.pending_searches.items.len;
    }

    // ── Query handling ──────────────────────────────────

    fn handleQuery(self: *DhtEngine, q: krpc.Query, sender: std.net.Address) void {
        const now = std.time.timestamp();

        // Add the querying node to our routing table
        _ = self.table.addNode(.{
            .id = q.sender_id,
            .address = sender,
            .ever_responded = false, // they queried us, not responded
        }, now);

        switch (q.method) {
            .ping => self.respondPing(q.transaction_id, sender),
            .find_node => self.respondFindNode(q, sender),
            .get_peers => self.respondGetPeers(q, sender),
            .announce_peer => self.respondAnnouncePeer(q, sender),
        }
    }

    fn respondPing(self: *DhtEngine, txn_id: []const u8, sender: std.net.Address) void {
        var buf: [512]u8 = undefined;
        const len = krpc.encodePingResponse(&buf, txn_id, self.own_id) catch return;
        self.queueSend(buf[0..len], sender);
    }

    fn respondFindNode(self: *DhtEngine, q: krpc.Query, sender: std.net.Address) void {
        const target = q.target orelse return;

        var closest_buf: [routing_table.K]NodeInfo = undefined;
        const count = self.table.findClosest(target, routing_table.K, &closest_buf);

        // Split closest nodes by address family. Per BEP 32 a dual-stack
        // DHT echoes IPv4 nodes in `nodes` (26 bytes each: 20-byte id +
        // 4-byte addr + 2-byte port) and IPv6 nodes in `nodes6` (38
        // bytes each: 20 + 16 + 2). Either field is omitted when empty.
        var nodes_buf: [routing_table.K * 26]u8 = undefined;
        var nodes_len: usize = 0;
        var nodes6_buf: [routing_table.K * 38]u8 = undefined;
        var nodes6_len: usize = 0;
        for (0..count) |i| {
            switch (closest_buf[i].address.any.family) {
                std.posix.AF.INET => {
                    const compact = node_id.encodeCompactNode(closest_buf[i]);
                    @memcpy(nodes_buf[nodes_len..][0..26], &compact);
                    nodes_len += 26;
                },
                std.posix.AF.INET6 => {
                    const compact = node_id.encodeCompactNode6(closest_buf[i]);
                    @memcpy(nodes6_buf[nodes6_len..][0..38], &compact);
                    nodes6_len += 38;
                },
                else => continue,
            }
        }

        var buf: [1500]u8 = undefined;
        const len = krpc.encodeFindNodeResponseDual(
            &buf,
            q.transaction_id,
            self.own_id,
            if (nodes_len > 0) nodes_buf[0..nodes_len] else null,
            if (nodes6_len > 0) nodes6_buf[0..nodes6_len] else null,
        ) catch return;
        self.queueSend(buf[0..len], sender);
    }

    fn respondGetPeers(self: *DhtEngine, q: krpc.Query, sender: std.net.Address) void {
        const info_hash = q.target orelse return;

        // Generate token for this querier
        const ip_bytes = addressTokenBytes(sender);
        const peer_token = self.tokens.generateToken(ip_bytes.slice());

        // Per BEP 5 the response carries either `values` (announced peers
        // we know about) or a fallback list of closest nodes — and BEP 32
        // splits the latter into `nodes` (IPv4) and `nodes6` (IPv6). Look
        // up announced peers in our peer-store and emit them in the
        // appropriate `values` / `values6` fields, then always include
        // the closest known nodes so well-behaved clients can continue
        // iterating if they want more breadth.
        const now = std.time.timestamp();
        // Sweep expired peers lazily on each lookup so the announce table
        // does not accumulate entries past their BEP 5 TTL.
        self.peer_store.sweep(self.allocator, now);

        var values_v4_buf: [PeerStore.max_peers_per_hash][6]u8 = undefined;
        var values_v6_buf: [PeerStore.max_peers_per_hash][18]u8 = undefined;
        const values_counts = self.peer_store.encodeValues(
            info_hash,
            &values_v4_buf,
            &values_v6_buf,
            now,
        );

        var closest_buf: [routing_table.K]NodeInfo = undefined;
        const count = self.table.findClosest(info_hash, routing_table.K, &closest_buf);

        var nodes_buf: [routing_table.K * 26]u8 = undefined;
        var nodes_len: usize = 0;
        var nodes6_buf: [routing_table.K * 38]u8 = undefined;
        var nodes6_len: usize = 0;
        for (0..count) |i| {
            switch (closest_buf[i].address.any.family) {
                std.posix.AF.INET => {
                    const compact = node_id.encodeCompactNode(closest_buf[i]);
                    @memcpy(nodes_buf[nodes_len..][0..26], &compact);
                    nodes_len += 26;
                },
                std.posix.AF.INET6 => {
                    const compact = node_id.encodeCompactNode6(closest_buf[i]);
                    @memcpy(nodes6_buf[nodes6_len..][0..38], &compact);
                    nodes6_len += 38;
                },
                else => continue,
            }
        }

        var buf: [1500]u8 = undefined;
        const len = krpc.encodeGetPeersResponseFull(
            &buf,
            q.transaction_id,
            self.own_id,
            &peer_token,
            if (nodes_len > 0) nodes_buf[0..nodes_len] else null,
            if (nodes6_len > 0) nodes6_buf[0..nodes6_len] else null,
            if (values_counts.v4 > 0) values_v4_buf[0..values_counts.v4] else null,
            if (values_counts.v6 > 0) values_v6_buf[0..values_counts.v6] else null,
        ) catch return;
        self.queueSend(buf[0..len], sender);
    }

    fn respondAnnouncePeer(self: *DhtEngine, q: krpc.Query, sender: std.net.Address) void {
        // Validate token
        const announce_token = q.token orelse {
            self.sendError(q.transaction_id, @intFromEnum(krpc.ErrorCode.protocol), "missing token", sender);
            return;
        };

        const ip_bytes = addressTokenBytes(sender);
        if (!self.tokens.validateToken(announce_token, ip_bytes.slice())) {
            self.sendError(q.transaction_id, @intFromEnum(krpc.ErrorCode.protocol), "invalid token", sender);
            return;
        }

        // The info_hash is required in announce_peer (BEP 5). Without
        // it we have nothing to key the announcement under.
        const info_hash = q.target orelse {
            self.sendError(q.transaction_id, @intFromEnum(krpc.ErrorCode.protocol), "missing info_hash", sender);
            return;
        };

        // Per BEP 5, `implied_port=1` means "use the source port of this
        // datagram instead of the announced port" — protects clients
        // behind NAT that don't know their externally-visible port.
        // Otherwise use `port` from the query.
        var peer_addr = sender;
        if (!q.implied_port) {
            const announced_port = q.port orelse {
                self.sendError(q.transaction_id, @intFromEnum(krpc.ErrorCode.protocol), "missing port", sender);
                return;
            };
            peer_addr.setPort(announced_port);
        }

        const now = std.time.timestamp();
        self.peer_store.announce(self.allocator, info_hash, peer_addr, now);

        // BEP 5: a successful announce_peer is acknowledged by a `ping`-
        // shaped response containing the responder's id.
        var buf: [512]u8 = undefined;
        const len = krpc.encodePingResponse(&buf, q.transaction_id, self.own_id) catch return;
        self.queueSend(buf[0..len], sender);

        log.debug("accepted announce_peer from {f} for hash {x}", .{ peer_addr, info_hash[0..4].* });
    }

    fn sendError(self: *DhtEngine, txn_id: []const u8, code: u32, message: []const u8, sender: std.net.Address) void {
        var buf: [512]u8 = undefined;
        const len = krpc.encodeError(&buf, txn_id, code, message) catch return;
        self.queueSend(buf[0..len], sender);
    }

    // ── Response handling ───────────────────────────────

    fn handleResponse(self: *DhtEngine, r: krpc.Response, sender: std.net.Address) void {
        const now = std.time.timestamp();

        // Find and remove the pending query
        const pending = self.findAndRemovePending(r.transaction_id, sender) orelse {
            log.debug("response for unknown txn from {f}", .{sender});
            return;
        };

        // Mark node as good in routing table
        self.table.markResponded(r.sender_id, now);

        // Add/update the responding node
        _ = self.table.addNode(.{
            .id = r.sender_id,
            .address = sender,
            .ever_responded = true,
        }, now);

        // If this was part of a bootstrap, check if we're done
        if (self.bootstrap_pending and self.table.nodeCount() >= routing_table.K) {
            self.bootstrapped = true;
            self.bootstrap_pending = false;
            log.info("DHT bootstrap complete: {d} nodes", .{self.table.nodeCount()});
        }

        // If this was part of a lookup, feed the response
        if (pending.lookup_idx) |idx| {
            if (self.active_lookups[idx]) |*lk| {
                // Decode compact IPv4 nodes (26 bytes each: 20 ID + 4 IP + 2 port)
                var new_nodes_buf: [routing_table.K * 2]NodeInfo = undefined;
                var new_node_count: usize = 0;
                if (r.nodes) |nodes_data| {
                    if (nodes_data.len % 26 == 0) {
                        const count = nodes_data.len / 26;
                        for (0..@min(count, routing_table.K)) |i| {
                            if (new_node_count >= new_nodes_buf.len) break;
                            new_nodes_buf[new_node_count] = node_id.decodeCompactNode(
                                nodes_data[i * 26 ..][0..26],
                            );
                            new_node_count += 1;
                        }
                    }
                }
                // Decode compact IPv6 nodes (BEP 32, 38 bytes each: 20 ID + 16 IP + 2 port)
                if (r.nodes6) |nodes_data| {
                    if (nodes_data.len % 38 == 0) {
                        const count = nodes_data.len / 38;
                        for (0..@min(count, routing_table.K)) |i| {
                            if (new_node_count >= new_nodes_buf.len) break;
                            new_nodes_buf[new_node_count] = node_id.decodeCompactNode6(
                                nodes_data[i * 38 ..][0..38],
                            );
                            new_node_count += 1;
                        }
                    }
                }

                // Add discovered nodes to routing table too
                for (new_nodes_buf[0..new_node_count]) |info| {
                    _ = self.table.addNode(info, now);
                }

                // Parse compact peers from "values" (IPv4, 6 bytes each) and
                // "values6" (IPv6, 18 bytes each, BEP 32).
                var peer_addrs: [50]std.net.Address = undefined;
                var peer_count: usize = 0;

                // IPv4 peers: 4-byte IP + 2-byte port. The element-length
                // prefix is bounded to MTU-sized values to defend against
                // adversarial digit floods that would overflow `dlen` in
                // safe-mode (panic) or wrap in release-mode (UB).
                if (r.values_raw) |raw| {
                    parseCompactPeers(raw, .v4, &peer_addrs, &peer_count);
                }

                // IPv6 peers (BEP 32): 16-byte IP + 2-byte port.
                if (r.values6_raw) |raw| {
                    parseCompactPeers(raw, .v6, &peer_addrs, &peer_count);
                }

                lk.handleResponse(
                    r.sender_id,
                    if (new_node_count > 0) new_nodes_buf[0..new_node_count] else null,
                    if (peer_count > 0) peer_addrs[0..peer_count] else null,
                    r.token,
                );
            }
        }
    }

    fn handleError(self: *DhtEngine, e: krpc.Error, sender: std.net.Address) void {
        _ = self;
        log.debug("KRPC error from {f}: [{d}] {s}", .{ sender, e.code, e.message });
    }

    // ── Lookup driving ──────────────────────────────────

    fn driveLookups(self: *DhtEngine, now: i64) void {
        for (0..max_lookups) |i| {
            if (self.active_lookups[i]) |*lk| {
                if (lk.isDone()) {
                    self.completeLookup(i, now);
                    continue;
                }
                self.sendLookupQueries(i);
            }
        }
    }

    fn sendLookupQueries(self: *DhtEngine, lookup_idx: usize) void {
        const lk = &(self.active_lookups[lookup_idx] orelse return);
        var buf: [lookup.alpha]NodeInfo = undefined;
        const count = lk.nextToQuery(&buf);

        for (0..count) |i| {
            const info = buf[i];
            const txn_id = self.allocTxnId();

            // Send query
            var pkt_buf: [1024]u8 = undefined;
            const len = switch (lk.kind) {
                .find_node => krpc.encodeFindNodeQuery(&pkt_buf, txn_id, self.own_id, lk.target) catch continue,
                .get_peers => krpc.encodeGetPeersQuery(&pkt_buf, txn_id, self.own_id, lk.target) catch continue,
            };

            self.queueSend(pkt_buf[0..len], info.address);
            if (!self.addPending(.{
                .transaction_id = txn_id,
                .target_id = info.id,
                .target_addr = info.address,
                .sent_at = std.time.timestamp(),
                .lookup_idx = lookup_idx,
                .method = if (lk.kind == .find_node) .find_node else .get_peers,
            })) {
                lk.markPending(info.id);
                break;
            }
        }
    }

    /// Like sendLookupQueries but sends to ALL candidates (up to K=8),
    /// not just alpha=3. Used during bootstrap to maximize initial discovery.
    fn sendLookupQueriesAll(self: *DhtEngine, lookup_idx: usize) void {
        const lk = &(self.active_lookups[lookup_idx] orelse return);

        // Query all candidates, not just alpha
        var buf: [routing_table.K]NodeInfo = undefined;
        const count = lk.nextToQueryN(&buf);

        for (0..count) |i| {
            const info = buf[i];
            const txn_id = self.allocTxnId();

            var pkt_buf: [1024]u8 = undefined;
            const len = switch (lk.kind) {
                .find_node => krpc.encodeFindNodeQuery(&pkt_buf, txn_id, self.own_id, lk.target) catch continue,
                .get_peers => krpc.encodeGetPeersQuery(&pkt_buf, txn_id, self.own_id, lk.target) catch continue,
            };

            self.queueSend(pkt_buf[0..len], info.address);
            if (!self.addPending(.{
                .transaction_id = txn_id,
                .target_id = info.id,
                .target_addr = info.address,
                .sent_at = std.time.timestamp(),
                .lookup_idx = lookup_idx,
                .method = if (lk.kind == .find_node) .find_node else .get_peers,
            })) {
                lk.markPending(info.id);
                break;
            }
        }
    }

    fn completeLookup(self: *DhtEngine, idx: usize, now: i64) void {
        const lk = self.active_lookups[idx] orelse return;

        if (lk.kind == .get_peers) {
            const peers = lk.getPeers();
            if (peers.len > 0) {
                // Copy peers and emit result
                const peers_copy = self.allocator.alloc(std.net.Address, peers.len) catch {
                    self.active_lookups[idx] = null;
                    return;
                };
                @memcpy(peers_copy, peers);
                self.peer_results.append(self.allocator, .{
                    .info_hash = lk.target,
                    .peers = peers_copy,
                }) catch {
                    self.allocator.free(peers_copy);
                };
            }

            // Send announce_peer to the closest responded nodes
            var closest: [lookup.K]NodeInfo = undefined;
            const closest_count = lk.getClosestResponded(&closest);
            for (0..closest_count) |i| {
                const tok = lk.getToken(closest[i].id) orelse continue;
                var buf: [1024]u8 = undefined;
                const len = krpc.encodeAnnouncePeerQuery(
                    &buf,
                    self.allocTxnId(),
                    self.own_id,
                    lk.target,
                    self.listen_port,
                    tok,
                    true, // implied_port
                ) catch continue;
                self.queueSend(buf[0..len], closest[i].address);
            }

            log.info("get_peers for {x}: {d} peers, {d} nodes queried", .{
                lk.target[0..4].*,
                peers.len,
                lk.candidate_count,
            });
        }

        _ = now;
        self.active_lookups[idx] = null;
    }

    // ── Bootstrap ───────────────────────────────────────

    fn startBootstrap(self: *DhtEngine, now: i64) void {
        self.bootstrap_pending = true;
        _ = now;

        // Strategy: launch multiple parallel find_node lookups to populate
        // the routing table as fast as possible.
        // 1. Find our own ID (populates nearby buckets)
        // 2. Find a random ID (populates distant buckets)
        // This doubles the discovery rate vs a single lookup.

        const targets = [_][20]u8{
            self.own_id,
            node_id.generateRandom(self.random), // random target for breadth
        };

        for (targets) |target| {
            const idx = for (0..max_lookups) |i| {
                if (self.active_lookups[i] == null) break i;
            } else break;

            var lk = Lookup.init(target, .find_node);
            lk.seed(&self.table);

            if (lk.candidate_count > 0) {
                self.active_lookups[idx] = lk;
                // Send to ALL candidates during bootstrap (not just alpha=3)
                // to maximize the number of nodes discovered in parallel.
                self.sendLookupQueriesAll(idx);
            }
        }
    }

    /// Add bootstrap nodes to the routing table. Called by the event loop
    /// after resolving bootstrap hostnames (blocking DNS on startup is OK).
    pub fn addBootstrapNodes(self: *DhtEngine, addrs: []const std.net.Address) void {
        const now = std.time.timestamp();
        for (addrs) |addr| {
            // Send a ping to each bootstrap node
            const txn_id = self.allocTxnId();
            var buf: [512]u8 = undefined;
            const len = krpc.encodePingQuery(&buf, txn_id, self.own_id) catch continue;
            self.queueSend(buf[0..len], addr);
            _ = self.addPending(.{
                .transaction_id = txn_id,
                .target_id = [_]u8{0} ** 20, // unknown ID
                .target_addr = addr,
                .sent_at = now,
                .lookup_idx = null,
                .method = .ping,
            });
        }
    }

    // ── Bucket refresh ──────────────────────────────────

    fn refreshBucket(self: *DhtEngine, bucket_idx: u8, now: i64) void {
        _ = now;
        // Generate a random ID in the bucket range and do a find_node
        const target = node_id.randomIdInBucket(self.random, self.own_id, bucket_idx);

        const idx = for (0..max_lookups) |i| {
            if (self.active_lookups[i] == null) break i;
        } else return;

        var lk = Lookup.init(target, .find_node);
        lk.seed(&self.table);

        if (lk.candidate_count > 0) {
            self.active_lookups[idx] = lk;
            self.sendLookupQueries(idx);
        }
    }

    // ── Timeout handling ────────────────────────────────

    fn checkTimeouts(self: *DhtEngine, now: i64) void {
        for (&self.pending) |*slot| {
            if (slot.*) |pending| {
                if (now - pending.sent_at >= query_timeout_secs) {
                    // Mark as failed in routing table
                    self.table.markFailed(pending.target_id);

                    // Notify lookup if applicable
                    if (pending.lookup_idx) |idx| {
                        if (self.active_lookups[idx]) |*lk| {
                            lk.markFailed(pending.target_id);
                        }
                    }

                    slot.* = null;
                }
            }
        }
    }

    // ── Internal helpers ────────────────────────────────

    fn queueSend(self: *DhtEngine, data: []const u8, remote: std.net.Address) void {
        var pkt = OutboundPacket{ .remote = remote };
        const len = @min(data.len, pkt.data.len);
        @memcpy(pkt.data[0..len], data[0..len]);
        pkt.len = len;
        self.send_queue.append(self.allocator, pkt) catch {
            log.warn("DHT send queue full, dropping packet", .{});
        };
    }

    fn allocTxnId(self: *DhtEngine) u16 {
        const id = self.next_txn_id;
        self.next_txn_id +%= 1;
        if (self.next_txn_id == 0) self.next_txn_id = 1;
        return id;
    }

    fn addPending(self: *DhtEngine, query: PendingQuery) bool {
        for (&self.pending) |*slot| {
            if (slot.* == null) {
                slot.* = query;
                return true;
            }
        }
        log.warn("DHT pending query table full", .{});
        return false;
    }

    fn findAndRemovePending(self: *DhtEngine, txn_id_bytes: []const u8, sender: std.net.Address) ?PendingQuery {
        if (txn_id_bytes.len != 2) return null;
        const txn_id = std.mem.readInt(u16, txn_id_bytes[0..2], .big);

        for (&self.pending) |*slot| {
            if (slot.*) |pending| {
                if (pending.transaction_id == txn_id and address.addressEql(&pending.target_addr, &sender)) {
                    const result = pending;
                    slot.* = null;
                    return result;
                }
            }
        }
        return null;
    }
};

const AddressTokenBytes = struct {
    bytes: [16]u8 = [_]u8{0} ** 16,
    len: u8 = 0,

    fn slice(self: *const AddressTokenBytes) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Return the stable on-wire address bytes used for announce tokens.
/// IPv4 binds 4 bytes. IPv6 binds all 16 bytes so two peers sharing a
/// /32 cannot replay each other's get_peers token.
fn addressTokenBytes(addr: std.net.Address) AddressTokenBytes {
    var result = AddressTokenBytes{};
    switch (addr.any.family) {
        std.posix.AF.INET => {
            const addr_bytes: [4]u8 = @bitCast(addr.in.sa.addr);
            @memcpy(result.bytes[0..4], &addr_bytes);
            result.len = 4;
        },
        std.posix.AF.INET6 => {
            @memcpy(result.bytes[0..16], &addr.in6.sa.addr);
            result.len = 16;
        },
        else => {},
    }
    return result;
}

const PeerWire = enum { v4, v6 };

/// Parse a bencoded list of compact peer entries (`l<n:...><n:...>e`)
/// into a fixed-size address buffer. Each entry's length prefix is
/// bounded to defend against adversarial digit floods:
///   * Without bounds, `dlen = dlen * 10 + d` and `vpos += dlen`
///     overflow `usize` on inputs like `999999999999999999999:...`,
///     panicking in safe mode or producing UB in release mode.
///   * With the cap, malformed entries are skipped and parsing
///     advances safely.
///
/// Entries with the wrong length (≠6 for IPv4, ≠18 for IPv6) are
/// skipped per BEP 5; the loop continues until `e` or `peer_addrs` is
/// full. SAFETY-only: we promise no panic, no UB, no out-of-bounds
/// writes; we do not promise to recover every conceivable encoding.
fn parseCompactPeers(
    raw: []const u8,
    wire: PeerWire,
    peer_addrs: *[50]std.net.Address,
    peer_count: *usize,
) void {
    if (raw.len == 0 or raw[0] != 'l') return;
    var vpos: usize = 1; // skip 'l'

    // Each entry's length prefix: ASCII decimal of `entry_len`, capped
    // at a small bound. Full UDP MTU is ≤1500; no legitimate compact
    // peer entry exceeds 18 bytes, so 5-digit bound is far more than
    // enough.
    const max_len_digits: usize = 5;

    while (vpos < raw.len and raw[vpos] != 'e') {
        if (peer_count.* >= peer_addrs.len) break;

        const digit_start = vpos;
        while (vpos < raw.len and
            raw[vpos] >= '0' and raw[vpos] <= '9' and
            (vpos - digit_start) < max_len_digits) : (vpos += 1)
        {}

        // Either we hit a non-digit (need ':'), exceeded the digit cap,
        // or ran off the buffer. Anything but a ':' here is malformed.
        if (vpos >= raw.len or raw[vpos] != ':') return;
        if (vpos == digit_start) return; // empty length prefix
        vpos += 1;

        // Parse the bounded digit run; cannot overflow usize because
        // <= 5 digits fits easily.
        var dlen: usize = 0;
        for (raw[digit_start .. vpos - 1]) |d| {
            dlen = dlen * 10 + (d - '0');
        }

        // The remaining body must fit; `dlen <= 99999 < raw.len + small`
        // already, but we still verify against the actual remainder
        // (saturating-subtraction form, overflow-safe).
        if (dlen > raw.len - vpos) return;

        switch (wire) {
            .v4 => if (dlen == 6) {
                const ip = std.mem.readInt(u32, raw[vpos..][0..4], .big);
                const port = std.mem.readInt(u16, raw[vpos + 4 ..][0..2], .big);
                peer_addrs[peer_count.*] = std.net.Address.initIp4(
                    @bitCast(std.mem.nativeToBig(u32, ip)),
                    port,
                );
                peer_count.* += 1;
            },
            .v6 => if (dlen == 18) {
                const ip6: [16]u8 = raw[vpos..][0..16].*;
                const port = std.mem.readInt(u16, raw[vpos + 16 ..][0..2], .big);
                peer_addrs[peer_count.*] = std.net.Address.initIp6(ip6, port, 0, 0);
                peer_count.* += 1;
            },
        }
        // Advance past the entry body regardless of whether we kept it
        // (BEP 5 lists may contain entries we don't recognize). `dlen`
        // is bounded above and `dlen <= raw.len - vpos` is checked.
        vpos += dlen;
    }
}

// ── Tests ──────────────────────────────────────────────

test "DhtEngine init and deinit" {
    const allocator = std.testing.allocator;
    var rng = Random.simRandom(0x300);
    const own_id = node_id.generateRandom(&rng);
    var engine = DhtEngine.init(allocator, &rng, own_id);
    defer engine.deinit();

    try std.testing.expectEqual(own_id, engine.own_id);
    try std.testing.expectEqual(@as(usize, 0), engine.nodeCount());
}

test "DhtEngine handles ping query" {
    const allocator = std.testing.allocator;
    var rng = Random.simRandom(0x301);
    const own_id = node_id.generateRandom(&rng);
    var engine = DhtEngine.init(allocator, &rng, own_id);
    defer engine.deinit();

    // Build a ping query
    var query_buf: [512]u8 = undefined;
    var sender_id: NodeId = undefined;
    @memset(&sender_id, 0x42);
    const len = try krpc.encodePingQuery(&query_buf, 0x1234, sender_id);

    const sender_addr = std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 6881);

    engine.handleIncoming(query_buf[0..len], sender_addr);

    // Should have queued a response
    try std.testing.expectEqual(@as(usize, 1), engine.send_queue.items.len);

    // Node should be in routing table
    try std.testing.expectEqual(@as(usize, 1), engine.nodeCount());
}

test "DhtEngine handles find_node query" {
    const allocator = std.testing.allocator;
    var rng = Random.simRandom(0x302);
    const own_id = node_id.generateRandom(&rng);
    var engine = DhtEngine.init(allocator, &rng, own_id);
    defer engine.deinit();

    // Add some nodes to the table first
    const now: i64 = 1000000;
    for (0..5) |i| {
        _ = engine.table.addNode(.{
            .id = node_id.generateRandom(&rng),
            .address = std.net.Address.initIp4(.{ 10, 0, 0, @intCast(i + 1) }, 6881),
        }, now);
    }

    var query_buf: [512]u8 = undefined;
    var sender_id: NodeId = undefined;
    @memset(&sender_id, 0x42);
    const target = node_id.generateRandom(&rng);
    const len = try krpc.encodeFindNodeQuery(&query_buf, 0x1234, sender_id, target);

    const sender_addr = std.net.Address.initIp4(.{ 10, 0, 0, 99 }, 6881);

    engine.handleIncoming(query_buf[0..len], sender_addr);

    // Should have queued a response with nodes
    try std.testing.expectEqual(@as(usize, 1), engine.send_queue.items.len);
}

test "DhtEngine disabled ignores messages" {
    const allocator = std.testing.allocator;
    var rng = Random.simRandom(0x303);
    var engine = DhtEngine.init(allocator, &rng, node_id.generateRandom(&rng));
    defer engine.deinit();
    engine.enabled = false;

    var query_buf: [512]u8 = undefined;
    var sender_id: NodeId = undefined;
    @memset(&sender_id, 0x42);
    const len = try krpc.encodePingQuery(&query_buf, 0x1234, sender_id);

    engine.handleIncoming(query_buf[0..len], std.net.Address.initIp4(.{ 10, 0, 0, 1 }, 6881));

    try std.testing.expectEqual(@as(usize, 0), engine.send_queue.items.len);
}

test "DhtEngine tick rotates tokens" {
    const allocator = std.testing.allocator;
    var rng = Random.simRandom(0x304);
    var engine = DhtEngine.init(allocator, &rng, node_id.generateRandom(&rng));
    defer engine.deinit();

    const ip = [_]u8{ 10, 0, 0, 1 };
    const token_before = engine.tokens.generateToken(&ip);

    // Tick past rotation interval
    const now = std.time.timestamp() + TokenManager.rotation_interval_secs + 1;
    engine.tick(now);

    // Token should still validate (within rotation window)
    try std.testing.expect(engine.tokens.validateToken(&token_before, &ip));
}

test "DhtEngine requestPeers registers both v1 and v2 hashes for hybrid torrents" {
    const allocator = std.testing.allocator;
    var rng = Random.simRandom(0x305);
    var engine = DhtEngine.init(allocator, &rng, node_id.generateRandom(&rng));
    defer engine.deinit();

    const v1_hash: [20]u8 = [_]u8{0xAA} ** 20;
    const v2_truncated: [20]u8 = [_]u8{0xBB} ** 20;

    engine.requestPeers(v1_hash, v2_truncated);
    try std.testing.expectEqual(@as(usize, 2), engine.registeredSearchCount());
    try std.testing.expectEqualSlices(u8, &v1_hash, &engine.pending_searches.items[0].hash);
    try std.testing.expectEqualSlices(u8, &v2_truncated, &engine.pending_searches.items[1].hash);

    // Re-registering is idempotent.
    engine.requestPeers(v1_hash, v2_truncated);
    try std.testing.expectEqual(@as(usize, 2), engine.registeredSearchCount());
}

test "DhtEngine requestPeers v1-only (null v2) registers only one hash" {
    const allocator = std.testing.allocator;
    var rng = Random.simRandom(0x306);
    var engine = DhtEngine.init(allocator, &rng, node_id.generateRandom(&rng));
    defer engine.deinit();

    const v1_hash: [20]u8 = [_]u8{0xAA} ** 20;
    engine.requestPeers(v1_hash, null);
    try std.testing.expectEqual(@as(usize, 1), engine.registeredSearchCount());
    try std.testing.expectEqualSlices(u8, &v1_hash, &engine.pending_searches.items[0].hash);
}

test "DhtEngine forceRequery toggles search-done flag for both hashes" {
    const allocator = std.testing.allocator;
    var rng = Random.simRandom(0x307);
    var engine = DhtEngine.init(allocator, &rng, node_id.generateRandom(&rng));
    defer engine.deinit();

    const v1_hash: [20]u8 = [_]u8{0xAA} ** 20;
    const v2_truncated: [20]u8 = [_]u8{0xBB} ** 20;

    engine.requestPeers(v1_hash, v2_truncated);
    // Pretend both have already been queried at least once.
    engine.pending_searches.items[0].done = true;
    engine.pending_searches.items[1].done = true;

    engine.forceRequery(v1_hash, v2_truncated);
    try std.testing.expect(!engine.pending_searches.items[0].done);
    try std.testing.expect(!engine.pending_searches.items[1].done);
}

test "DhtEngine announcePeer fans out to v1 and v2 hashes" {
    const allocator = std.testing.allocator;
    var rng = Random.simRandom(0x308);
    var engine = DhtEngine.init(allocator, &rng, node_id.generateRandom(&rng));
    defer engine.deinit();

    // Seed routing table so both lookups have candidates.
    const now: i64 = 1_000_000;
    for (0..10) |i| {
        _ = engine.table.addNode(.{
            .id = node_id.generateRandom(&rng),
            .address = std.net.Address.initIp4(.{ 10, 0, 0, @intCast(i + 1) }, 6881),
        }, now);
    }

    const v1_hash: [20]u8 = [_]u8{0xAA} ** 20;
    const v2_truncated: [20]u8 = [_]u8{0xBB} ** 20;
    try engine.announcePeer(v1_hash, v2_truncated, 6881);

    // Two active lookups should now be running, one for each hash.
    var v1_seen = false;
    var v2_seen = false;
    for (engine.active_lookups) |lk| {
        if (lk) |l| {
            if (std.mem.eql(u8, &l.target, &v1_hash)) v1_seen = true;
            if (std.mem.eql(u8, &l.target, &v2_truncated)) v2_seen = true;
        }
    }
    try std.testing.expect(v1_seen);
    try std.testing.expect(v2_seen);
    try std.testing.expectEqual(@as(u16, 6881), engine.listen_port);
}

test "DhtEngine get_peers starts lookup" {
    const allocator = std.testing.allocator;
    var rng = Random.simRandom(0x309);
    var engine = DhtEngine.init(allocator, &rng, node_id.generateRandom(&rng));
    defer engine.deinit();

    // Add nodes so lookup has candidates
    const now: i64 = 1000000;
    for (0..10) |i| {
        _ = engine.table.addNode(.{
            .id = node_id.generateRandom(&rng),
            .address = std.net.Address.initIp4(.{ 10, 0, 0, @intCast(i + 1) }, 6881),
        }, now);
    }

    var info_hash: [20]u8 = undefined;
    @memset(&info_hash, 0xAA);
    try engine.getPeers(info_hash);

    // Should have an active lookup and queued some packets
    var has_lookup = false;
    for (engine.active_lookups) |lk| {
        if (lk != null) {
            has_lookup = true;
            break;
        }
    }
    try std.testing.expect(has_lookup);
    try std.testing.expect(engine.send_queue.items.len > 0);
}
