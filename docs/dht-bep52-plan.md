# DHT (BEP 5) and BEP 52 (BitTorrent v2 / Hybrid Torrents) Implementation Plan

This document is a planning and follow-up document, not a statement of current implementation status.

DHT and most BEP 52 runtime support are already implemented in the tree. What remains here is primarily:
- architectural context for how those systems were designed
- follow-up work that was intentionally deferred
- the remaining BitTorrent v2 / hybrid torrent creation work

Before assuming an item in this document is still pending, check [STATUS.md](../STATUS.md) and the current code under `src/dht/`, `src/torrent/`, `src/storage/`, `src/net/`, and `src/tracker/`.

Links: [STATUS.md](../STATUS.md) | [DECISIONS.md](../DECISIONS.md) | [future-features.md](future-features.md) | [io-uring-syscalls.md](io-uring-syscalls.md)

---

## Part 1: DHT (BEP 5)

### 1.1 Overview

The Distributed Hash Table provides trackerless peer discovery. Nodes in the DHT store contact information for peers downloading particular torrents. Each node has a 160-bit node ID and maintains a routing table of other nodes organized into k-buckets based on XOR distance from its own ID.

DHT is required for public torrents and magnet link resolution. Per BEP 27, DHT MUST be disabled for private torrents (the `private` flag is already parsed in `src/torrent/metainfo.zig`).

### 1.2 Module Layout

```
src/dht/
  root.zig              -- public API: DhtNode.init/deinit/start/stop/getPeers/announcePeer
  node_id.zig           -- 160-bit node ID generation, XOR distance, ordering
  routing_table.zig     -- k-bucket routing table
  krpc.zig              -- KRPC message encode/decode (bencode over UDP)
  queries.zig           -- ping, find_node, get_peers, announce_peer state machines
  token.zig             -- token generation/validation for announce_peer security
  bootstrap.zig         -- bootstrap node list, initial table population
  persistence.zig       -- routing table save/load (SQLite)
```

### 1.3 Node ID Generation (`src/dht/node_id.zig`)

**Data type:**
```zig
pub const NodeId = [20]u8;  // 160-bit identifier

pub const NodeInfo = struct {
    id: NodeId,
    address: std.net.Address,  // IPv4 or IPv6
    last_seen: i64,            // unix timestamp
    ever_responded: bool,      // "good" node qualifier
    failed_queries: u8,        // consecutive failures
};
```

**ID generation:** Generate a random 20-byte ID on first run. Persist it in the resume SQLite database so the node ID is stable across restarts (required by BEP 5 -- changing ID frequently causes routing table churn across the network).

**XOR distance:**
```zig
pub fn xorDistance(a: NodeId, b: NodeId) NodeId {
    var result: NodeId = undefined;
    for (0..20) |i| result[i] = a[i] ^ b[i];
    return result;
}

pub fn distanceBucket(a: NodeId, b: NodeId) u8 {
    // Returns the index of the highest set bit in xorDistance(a, b).
    // Range 0..159. Determines which k-bucket the node belongs in.
}
```

### 1.4 Routing Table (`src/dht/routing_table.zig`)

**Structure:** 160 k-buckets, each holding up to K=8 nodes. Bucket `i` stores nodes whose XOR distance from our node ID has its highest bit at position `i`.

```zig
pub const K = 8;

pub const KBucket = struct {
    nodes: std.BoundedArray(NodeInfo, K),
    last_changed: i64,          // for refresh timing

    pub fn isFull(self: *const KBucket) bool;
    pub fn addOrUpdate(self: *KBucket, node: NodeInfo) AddResult;
    pub fn findLeastRecentlyGood(self: *KBucket) ?*NodeInfo;
};

pub const RoutingTable = struct {
    own_id: NodeId,
    buckets: [160]KBucket,

    pub fn addNode(self: *RoutingTable, node: NodeInfo) void;
    pub fn findClosest(self: *RoutingTable, target: NodeId, count: u8) []NodeInfo;
    pub fn needsRefresh(self: *RoutingTable) ?u8;  // returns bucket index
    pub fn nodeCount(self: *RoutingTable) usize;
};
```

**Node classification (BEP 5 section 2):**
- Good: responded to our query in last 15 minutes, or ever responded and queried us in last 15 minutes.
- Questionable: not seen in 15 minutes.
- Bad: failed to respond to multiple consecutive queries.

**Eviction policy:** When a bucket is full and a new node arrives, ping the least-recently-seen node. If it responds, discard the new node. If it fails, replace it. This ensures long-lived nodes are preferred (BEP 5 requirement).

**Bucket splitting:** Not needed for a basic implementation. The standard 160-bucket approach is simpler and sufficient. Bucket splitting is an optimization from the Kademlia paper that BEP 5 does not require.

**Refresh:** Buckets not changed in 15 minutes should be refreshed by performing a `find_node` for a random ID in that bucket's range. A background timer (driven by the event loop timeout mechanism) triggers this.

### 1.5 KRPC Protocol Layer (`src/dht/krpc.zig`)

KRPC messages are bencoded dictionaries sent as UDP datagrams. Every message has a `t` (transaction ID), `y` (type: q/r/e), and type-specific keys.

**Message types:**
```zig
pub const MessageType = enum { query, response, @"error" };

pub const Message = union(enum) {
    query: Query,
    response: Response,
    @"error": Error,
};

pub const Query = struct {
    transaction_id: []const u8,
    method: Method,
    args: bencode.Value,      // the "a" dict
};

pub const Response = struct {
    transaction_id: []const u8,
    values: bencode.Value,    // the "r" dict
};

pub const Error = struct {
    transaction_id: []const u8,
    code: u32,
    message: []const u8,
};

pub const Method = enum {
    ping,
    find_node,
    get_peers,
    announce_peer,
};
```

**Encoding/decoding:** Reuse `src/torrent/bencode.zig` (parse) and `src/torrent/bencode_encode.zig` (encode). KRPC is standard bencode -- no new parser needed. Add a thin wrapper in `krpc.zig` that constructs and destructures the specific dictionary shapes for each query/response type.

**Transaction IDs:** 2-byte random IDs. Maintain a `HashMap(u16, PendingQuery)` to match responses to outstanding queries. Entries expire after 15 seconds (configurable timeout).

**Compact node info:** BEP 5 encodes node info as 26 bytes (20-byte node ID + 6-byte compact IPv4 address). For IPv6 (BEP 32), it is 38 bytes (20 + 18). Add encode/decode helpers:
```zig
pub fn encodeCompactNode(node: NodeInfo) [26]u8;
pub fn decodeCompactNode(data: *const [26]u8) NodeInfo;
pub fn encodeCompactNodes(nodes: []const NodeInfo, allocator: Allocator) ![]u8;
pub fn decodeCompactNodes(data: []const u8) ![]NodeInfo;
```

### 1.6 Query Types (`src/dht/queries.zig`)

Each query type is implemented as a request builder + response parser pair.

**ping:** Simplest query. Confirms a node is alive. Used for eviction checks and keepalive.
- Query args: `{"id": <our_node_id>}`
- Response: `{"id": <their_node_id>}`

**find_node:** Core of the iterative lookup. Finds nodes close to a target ID.
- Query args: `{"id": <our_id>, "target": <target_20_bytes>}`
- Response: `{"id": <their_id>, "nodes": <compact_node_info>}`

**get_peers:** The primary DHT operation for BitTorrent. Asks for peers downloading a specific info-hash.
- Query args: `{"id": <our_id>, "info_hash": <20_byte_hash>}`
- Response (has peers): `{"id": <their_id>, "token": <opaque>, "values": [<compact_peer>, ...]}`
- Response (no peers): `{"id": <their_id>, "token": <opaque>, "nodes": <compact_node_info>}`
- The `token` must be saved and sent back in `announce_peer`.

**announce_peer:** Tells a node we are downloading (or have) a torrent.
- Query args: `{"id": <our_id>, "info_hash": <hash>, "port": <port>, "token": <saved_token>}`
- Optional `implied_port`: if 1, the responding node uses the UDP source port instead of the `port` field. This helps peers behind NAT.

**Iterative lookup algorithm:**
1. Start with the K closest nodes from our routing table for the target.
2. Send `find_node` or `get_peers` to the alpha (3) closest unqueried nodes in parallel.
3. As responses arrive, add newly discovered closer nodes to the candidate set.
4. Repeat until no closer nodes are discovered or all K closest nodes have been queried.
5. For `get_peers`, collect peers from `values` fields encountered during the walk.

This should be implemented as a `Lookup` state machine:
```zig
pub const Lookup = struct {
    target: NodeId,
    candidates: BoundedPriorityQueue(NodeInfo, 16), // sorted by XOR distance
    queried: HashSet(NodeId),
    best_peers: ArrayList(std.net.Address),  // for get_peers
    tokens: HashMap(NodeId, []const u8),     // for announce_peer follow-up
    alpha: u8 = 3,
    state: enum { in_progress, done },

    pub fn start(self: *Lookup, table: *RoutingTable) void;
    pub fn handleResponse(self: *Lookup, from: NodeId, nodes: []NodeInfo, peers: ?[]std.net.Address) void;
    pub fn nextToQuery(self: *Lookup) ?[]NodeInfo;
    pub fn isDone(self: *Lookup) bool;
};
```

### 1.7 io_uring Integration

DHT uses a single UDP socket (typically port 6881 or the same port as the peer listen socket). This socket is shared between DHT and potentially uTP (which also uses UDP). The existing uTP handler in `src/io/utp_handler.zig` already demonstrates the pattern: `IORING_OP_RECVMSG` for receiving datagrams and `IORING_OP_SENDMSG` for sending.

**Integration approach:**

1. **Shared UDP socket:** The event loop already creates a UDP socket for uTP (`udp_fd` in `EventLoop`). DHT and uTP share this socket. Incoming datagrams are demultiplexed by examining the first bytes:
   - uTP packets start with version nibble `0x01` in the first byte (type+ver field).
   - DHT/KRPC packets start with `d` (0x64) because they are bencoded dictionaries.
   This disambiguation is trivial and reliable.

2. **New OpType variants:** Add `dht_recv` and `dht_send` to the `OpType` enum in `src/io/event_loop.zig`. Or, more practically, reuse the existing `utp_recv` completion path and demux there:

   ```zig
   // In handleUtpRecv (renamed to handleUdpRecv):
   if (buf[0] == 'd') {
       self.dht_node.handleIncoming(buf[0..n], sender_addr);
   } else {
       // existing uTP path
   }
   ```

3. **Send path:** `DhtNode` queues outbound KRPC messages. The event loop drains this queue and submits `IORING_OP_SENDMSG` SQEs, similar to `submitUtpSend` in `src/io/utp_handler.zig`. Use a bounded send queue (64 entries) to avoid SQE exhaustion.

4. **Timers:** DHT needs several periodic timers:
   - Transaction timeout: 15 seconds per outstanding query.
   - Bucket refresh: every 15 minutes for stale buckets.
   - Token rotation: every 5-10 minutes.
   - Announce refresh: re-announce active torrents every ~30 minutes.

   Use the event loop's existing `IORING_OP_TIMEOUT` mechanism (already used for peer timeouts). Add a single periodic DHT timer that fires every ~5 seconds and checks all time-based conditions.

**Ring entry count:** The current ring is initialized with 16 entries for the blocking convenience API in `src/io/ring.zig`. The event loop ring is larger (256+ entries). DHT operations go through the event loop ring, which has sufficient capacity. No ring size change needed.

### 1.8 Token Management (`src/dht/token.zig`)

Tokens prevent third parties from announcing on behalf of others. When responding to `get_peers`, we generate a token tied to the querier's IP address. When they later `announce_peer`, they must present a valid token.

**Implementation:**
```zig
pub const TokenManager = struct {
    secret: [16]u8,        // current secret
    prev_secret: [16]u8,   // previous secret (for rotation overlap)
    last_rotation: i64,    // unix timestamp

    pub fn init() TokenManager;
    pub fn generateToken(self: *TokenManager, ip: []const u8) [8]u8;
    pub fn validateToken(self: *TokenManager, token: []const u8, ip: []const u8) bool;
    pub fn maybeRotate(self: *TokenManager, now: i64) void;
};
```

Token = HMAC-truncated(secret, querier_ip). Accept tokens generated with either the current or previous secret (handles the rotation window). Rotate every 5 minutes. Use `std.crypto.auth.siphash.SipHash64` or SHA-256 truncated for the HMAC.

### 1.9 Bootstrap and Initial Population (`src/dht/bootstrap.zig`)

**Bootstrap nodes:** Hard-code well-known bootstrap nodes:
- `router.bittorrent.com:6881`
- `dht.transmissionbt.com:6881`
- `router.utorrent.com:6881`
- `dht.libtorrent.org:25401`

**Bootstrap procedure:**
1. Load persisted routing table from SQLite (if exists).
2. If the table has fewer than K good nodes, resolve and ping bootstrap nodes.
3. Perform a `find_node` lookup for our own node ID (populates nearby buckets).
4. Perform 3-5 `find_node` lookups for random IDs (populates distant buckets).

**DNS resolution for bootstrap:** DNS resolution is a blocking operation. Per the io_uring policy, use `std.net.Address.resolveIp` on a background thread (same pattern as SQLite -- spawn a short-lived thread for the blocking work). Alternatively, resolve once at startup before the event loop starts, which is acceptable for one-time setup.

### 1.10 Routing Table Persistence (`src/dht/persistence.zig`)

Store the routing table in the existing SQLite resume database (`src/storage/resume.zig`). Add two new tables:

```sql
CREATE TABLE IF NOT EXISTS dht_config (
    key TEXT PRIMARY KEY,
    value BLOB NOT NULL
);

CREATE TABLE IF NOT EXISTS dht_nodes (
    node_id BLOB NOT NULL,
    ip TEXT NOT NULL,
    port INTEGER NOT NULL,
    last_seen INTEGER NOT NULL,
    PRIMARY KEY (node_id)
);
```

- `dht_config` stores the node ID (`key='node_id'`) and any other DHT settings.
- `dht_nodes` stores up to ~300 good nodes (top nodes from each non-empty bucket). Persisted on graceful shutdown and periodically (every 30 minutes).
- Runs on the existing SQLite background thread -- not on the event loop.

### 1.11 Interaction with Existing Peer Discovery

The existing codebase has three peer discovery mechanisms:
1. **HTTP tracker** (`src/tracker/announce.zig`, `src/io/http_executor.zig`)
2. **UDP tracker** (`src/tracker/udp.zig`)
3. **PEX** (`src/net/extensions.zig` -- BEP 10 ut_pex)

DHT becomes the fourth source. Integration point is `TorrentSession` (`src/daemon/torrent_session.zig`):

```zig
// In TorrentSession, after starting tracker announces:
if (!self.is_private) {
    self.dht_lookup = try dht_node.getPeers(self.info_hash);
}
```

Peers discovered via DHT feed into the same `EventLoop` peer connection pipeline as tracker-returned peers. The `peer_policy.zig` module already handles deduplication and connection limits -- DHT-sourced peers go through the same path.

**announce_peer timing:** After completing a download (or starting a seed), call `dht_node.announcePeer(info_hash, port)`. This performs an iterative `get_peers` lookup, collects tokens from the K closest nodes, then sends `announce_peer` to each.

**Private torrent guard:** Check `metainfo.isPrivate()` before any DHT operation. This check already exists conceptually in the extension handshake code (PEX is omitted for private torrents). Apply the same pattern.

### 1.12 DHT Phasing

**Phase 1 -- Core protocol (read-only DHT participation):**
- `node_id.zig`, `routing_table.zig`, `krpc.zig`, `token.zig`
- Parse and respond to incoming queries (ping, find_node, get_peers)
- Bootstrap from hard-coded nodes
- Unit tests for all encode/decode paths, routing table operations, XOR distance

**Phase 2 -- Active lookups:**
- `queries.zig` iterative lookup state machine
- `get_peers` for active torrents
- Wire DHT peers into `TorrentSession` peer pipeline
- Integration test: find peers for a well-seeded public torrent via DHT

**Phase 3 -- Announce and persistence:**
- `announce_peer` after download completion
- `persistence.zig` SQLite save/load
- Bucket refresh timer
- `bootstrap.zig` full bootstrap procedure with persisted table

**Phase 4 -- Production hardening:**
- Rate limiting outbound queries (avoid being flagged as abusive)
- Handle KRPC errors gracefully
- IPv6 support (BEP 32: dual-stack DHT)
- Fuzz tests for incoming KRPC messages (untrusted UDP input)

### 1.13 Testing Strategy

- **Unit tests** in each module's `test` blocks: XOR distance correctness, k-bucket insertion/eviction, KRPC encode/decode round-trips, token generate/validate, compact node info encode/decode.
- **Fuzz tests** for `krpc.zig` (add to existing fuzz test suite alongside bencode, multipart, tracker response fuzz tests). KRPC messages come from untrusted UDP sources.
- **Integration test**: Start two `DhtNode` instances on localhost, have one announce and the other look up. Verify peer discovery works end-to-end.
- **Benchmark**: Routing table `findClosest` with 1000+ nodes. KRPC encode/decode throughput.

---

## Part 2: BEP 52 (BitTorrent v2 / Hybrid Torrents)

### 2.1 Overview

BEP 52 introduces BitTorrent v2, which changes piece hashing from a flat SHA-1 list to per-file Merkle trees using SHA-256. It also introduces a new info-hash format (32 bytes, SHA-256 of the info dict) and a hybrid mode that embeds both v1 and v2 metadata in a single `.torrent` file for backward compatibility.

Key differences from v1:
- Pieces are aligned to file boundaries (no cross-file pieces).
- Each file has its own Merkle hash tree (SHA-256, leaf size = piece size).
- The info dict contains a `file tree` instead of `files` or `length`+`name`.
- The info-hash is SHA-256 (32 bytes) instead of SHA-1 (20 bytes).
- Hybrid torrents contain both `pieces` (v1 SHA-1 hashes) and `file tree` (v2 Merkle roots).

### 2.2 Module Layout

```
src/torrent/
  metainfo.zig           -- extend to parse v2 and hybrid metadata
  info_hash.zig          -- extend to compute v2 info-hash (SHA-256)
  merkle.zig             -- NEW: Merkle tree construction and verification
  file_tree.zig          -- NEW: v2 file tree parsing
```

Changes also needed in:
```
src/storage/verify.zig   -- add SHA-256 piece verification path
src/storage/writer.zig   -- handle file-aligned pieces
src/torrent/layout.zig   -- file-aligned piece mapping
src/torrent/session.zig  -- dual info-hash support
src/daemon/torrent_session.zig  -- v2 info-hash in stats, tracker announces
src/tracker/announce.zig -- announce with v2 info-hash
src/net/peer_wire.zig    -- v2 handshake (different info-hash in handshake)
```

### 2.3 Torrent Version Detection

Add a version enum and detection logic:

```zig
pub const TorrentVersion = enum {
    v1,       // traditional: has "pieces" but no "file tree"
    v2,       // pure v2: has "file tree" but no "pieces"
    hybrid,   // both v1 and v2 metadata present
};

pub fn detectVersion(info_dict: bencode.DictEntries) TorrentVersion {
    const has_pieces = bencode.dictGet(info_dict, "pieces") != null;
    const has_file_tree = bencode.dictGet(info_dict, "file tree") != null;
    if (has_pieces and has_file_tree) return .hybrid;
    if (has_file_tree) return .v2;
    return .v1;
}
```

### 2.4 Metainfo Extension (`src/torrent/metainfo.zig`)

The current `Metainfo` struct stores only v1 fields. Extend it:

```zig
pub const Metainfo = struct {
    // Existing v1 fields (unchanged)
    info_hash: [20]u8,            // v1 SHA-1 info-hash
    announce: ?[]const u8,
    announce_list: []const []const u8,
    comment: ?[]const u8,
    created_by: ?[]const u8,
    name: []const u8,
    piece_length: u32,
    pieces: []const u8,           // v1 piece hashes (may be empty for pure v2)
    private: bool,
    files: []File,

    // New v2 fields
    version: TorrentVersion = .v1,
    info_hash_v2: ?[32]u8 = null, // v2 SHA-256 info-hash (null for pure v1)
    file_tree: ?[]V2File = null,  // v2 per-file metadata

    pub const V2File = struct {
        path: []const []const u8,
        length: u64,
        pieces_root: [32]u8,      // SHA-256 Merkle root for this file
    };
};
```

**Parsing changes:** The `parse` function currently assumes v1 format. Add a branch after detecting version:
- v1 (current path): unchanged.
- v2: parse `file tree` dict, extract `pieces root` for each file, skip `pieces` field.
- hybrid: parse both. Populate all v1 fields AND all v2 fields. The `files` array is populated from both sources (they must describe the same content).

### 2.5 v2 Info-Hash Calculation (`src/torrent/info_hash.zig`)

The v2 info-hash is SHA-256 of the bencoded info dict (same concept as v1, different hash). The existing `findInfoBytes` function already extracts the raw info dict bytes from the torrent file -- it can be reused.

```zig
pub fn computeV2(torrent_bytes: []const u8) ![32]u8 {
    const info_bytes = try findInfoBytes(torrent_bytes);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(info_bytes, &digest, .{});
    return digest;
}
```

Note from `docs/future-features.md`: "Zig std lib SHA-256 already has SHA-NI acceleration. SHA-256 for BEP 52 (BitTorrent v2) would use std lib directly." No custom SHA-256 implementation needed -- use `std.crypto.hash.sha2.Sha256`.

### 2.6 Merkle Tree Piece Verification (`src/torrent/merkle.zig`)

In v2, each file has a Merkle hash tree where:
- Leaf nodes = SHA-256 of piece data (piece_length bytes each).
- Internal nodes = SHA-256(left_child || right_child).
- The root is stored in the `.torrent` as `pieces root` per file.
- The tree is a complete balanced binary tree, padded with zero-hashes for the last level.

```zig
pub const MerkleTree = struct {
    /// Layer 0 = leaves (piece hashes), layer N = root.
    /// Stored as a flat array in level-order.
    layers: [][]const [32]u8,

    pub fn fromPieceHashes(allocator: Allocator, piece_hashes: [][32]u8) !MerkleTree;
    pub fn root(self: *const MerkleTree) [32]u8;
    pub fn verifyPiece(self: *const MerkleTree, piece_index: u32, piece_data: []const u8) bool;
    pub fn proofForPiece(self: *const MerkleTree, piece_index: u32) ![][32]u8;
    pub fn verifyProof(root: [32]u8, piece_index: u32, piece_hash: [32]u8, proof: [][32]u8) bool;
};

/// Hash a single piece (leaf node).
pub fn hashPiece(data: []const u8) [32]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return digest;
}

/// Hash two child nodes to produce parent.
pub fn hashPair(left: [32]u8, right: [32]u8) [32]u8 {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update(&left);
    hasher.update(&right);
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    return digest;
}
```

**Padding:** When the number of pieces is not a power of 2, the tree must be padded. Padding leaves are SHA-256 of an all-zero block of `piece_length` bytes. Pre-compute this once.

**Verification flow:**
1. Read piece data from disk (same `PieceStore.readPiece` as v1).
2. Compute `hashPiece(data)` using SHA-256.
3. Compare against the expected leaf hash (either from the full tree or using a Merkle proof).
4. For full verification at startup: rebuild the entire tree and compare root against `pieces_root`.

### 2.7 v2 File Tree Parsing (`src/torrent/file_tree.zig`)

The v2 `file tree` is a nested dictionary structure where directory names are keys and files are leaves containing a `length` integer and a `pieces root` 32-byte string.

Example structure:
```
file tree:
  dir1:
    file1.txt:
      "": {length: 1234, pieces root: <32 bytes>}
    file2.txt:
      "": {length: 5678, pieces root: <32 bytes>}
```

The empty-string key `""` marks a leaf (file entry) vs. a directory.

```zig
pub fn parseFileTree(allocator: Allocator, file_tree_dict: bencode.DictEntries) ![]Metainfo.V2File {
    var files = ArrayList(Metainfo.V2File).init(allocator);
    var path_stack = ArrayList([]const u8).init(allocator);
    try walkFileTree(allocator, file_tree_dict, &path_stack, &files);
    return files.toOwnedSlice(allocator);
}
```

Recursive walk: at each level, iterate dictionary keys. If a key is `""`, this is a file leaf -- extract `length` and `pieces root`. Otherwise, push the key as a path component and recurse.

### 2.8 Storage Changes for File-Aligned Pieces

In v1, pieces can span file boundaries (a single piece may contain data from two files). In v2, pieces are always aligned to file boundaries. The last piece of each file may be shorter than `piece_length`.

**Impact on `src/torrent/layout.zig`:**
The current `Layout` maps piece indices to file spans. For v2, each piece maps to exactly one file. The `mapPiece` function can be simplified for v2 (no cross-file spans), but the v1 path must remain for hybrid and v1 torrents. Add a version flag:

```zig
pub fn mapPiece(self: *const Layout, piece_index: u32, spans: []Span) ![]Span {
    if (self.version == .v2 or self.version == .hybrid) {
        return self.mapPieceV2(piece_index, spans);  // always single-file
    }
    return self.mapPieceV1(piece_index, spans);  // may cross files
}
```

**Impact on `src/storage/verify.zig`:**
The current `PiecePlan` uses SHA-1. For v2, use SHA-256. Add a union or version field:

```zig
pub const PiecePlan = struct {
    piece_index: u32,
    piece_length: u32,
    hash_type: HashType,
    expected_hash_v1: [20]u8,    // SHA-1 for v1
    expected_hash_v2: [32]u8,    // SHA-256 for v2
    spans: []layout.Layout.Span,

    pub const HashType = enum { sha1, sha256 };
};
```

**Impact on `src/io/hasher.zig`:**
The hasher thread pool computes SHA-1 digests. Add a SHA-256 code path. Since `std.crypto.hash.sha2.Sha256` already has hardware acceleration, no custom assembly needed.

### 2.9 Peer Wire Protocol Changes

**Handshake:** v2 peers use the v2 info-hash (32 bytes, truncated to 20 for the handshake, OR the v1 info-hash for hybrid torrents). For hybrid torrents, the peer can connect using either info-hash. The daemon must recognize both.

**Impact on `src/net/peer_wire.zig`:**
- During handshake, match incoming info-hash against both v1 and v2 hashes for hybrid torrents.
- The `TorrentContext` (used for handshake matching in the event loop) needs to store both hashes.

**BEP 52 extension messages:** v2 introduces a `hash request` / `hash` / `hash reject` message set for requesting Merkle proofs from peers. These are new message types:
- `hash request`: request Merkle proof for a piece range.
- `hashes`: response containing the proof nodes.
- `hash reject`: peer cannot provide the requested hashes.

These are needed for incremental piece verification but are a lower priority than basic v2 support. Initial implementation can compute the full Merkle tree locally and defer the hash exchange messages.

### 2.10 Tracker Announce with v2 Info-Hash

For v2-only torrents, the tracker announce uses the SHA-256 info-hash (truncated to 20 bytes for the HTTP announce `info_hash` parameter, or the full 32 bytes depending on tracker support).

For hybrid torrents, announce with the v1 info-hash by default (maximum compatibility). Optionally announce with both.

**Impact on `src/tracker/announce.zig`:**
- The `Request` struct currently has `info_hash: [20]u8`. For v2, this is the truncated SHA-256 hash. No struct change needed for the HTTP path.
- For the UDP tracker (`src/tracker/udp.zig`), same truncation applies.

### 2.11 DHT with v2 Info-Hash

DHT `get_peers` and `announce_peer` use a 20-byte info-hash. For v2 torrents, use the truncated (first 20 bytes of) SHA-256 info-hash. For hybrid torrents, perform lookups with both info-hashes to maximize peer discovery.

### 2.12 Backward Compatibility

**Pure v1 torrents:** Zero changes. The `version` field defaults to `.v1`, and all v2-specific fields are null/empty. Existing code paths are unaffected.

**Hybrid torrents:** Parse both v1 and v2 metadata. Use v1 metadata for v1 peers and v2 metadata for v2 peers. In practice, most clients will use the v1 info-hash for tracker announces (wider compatibility).

**Pure v2 torrents:** Require the full v2 code path. These are currently rare but will become more common. Support is additive -- it does not change any v1 behavior.

**Resume state:** The existing `ResumeDb` keys on `info_hash BLOB`. For v2 torrents, key on the v2 info-hash (32 bytes). For hybrid, key on v1 info-hash (existing behavior) and store v2 info-hash as an additional column.

### 2.13 BEP 52 Phasing

**Phase 1 -- Parsing and detection:**
- `file_tree.zig`: v2 file tree parser
- Extend `metainfo.zig` to detect version and parse v2/hybrid metadata
- Extend `info_hash.zig` with `computeV2`
- Unit tests: parse v2-only, hybrid, and v1-only torrents

**Phase 2 -- Merkle tree verification:**
- `merkle.zig`: tree construction, root computation, piece verification
- Extend `verify.zig` with SHA-256 piece hashing
- Extend `hasher.zig` with SHA-256 path
- Unit tests: build tree from known data, verify individual pieces, test padding

**Phase 3 -- Storage and layout:**
- Extend `layout.zig` for file-aligned pieces
- Extend `writer.zig` for v2 piece writing (simpler -- no cross-file spans)
- Integration test: download and verify a v2 torrent

**Phase 4 -- Protocol integration:**
- Extend peer wire handshake for dual info-hash matching
- Tracker announce with v2 info-hash
- DHT lookups with v2 info-hash
- Resume DB schema extension for v2 info-hash

**Phase 5 -- Advanced v2 features (deferred):**
- `hash request` / `hashes` / `hash reject` message exchange (BEP 52 section 5)
- Merkle proof exchange with peers
- Piece-layer streaming (request Merkle layers incrementally)

### 2.14 Testing Strategy

- **Unit tests:** v2 file tree parsing, Merkle tree construction and root computation, SHA-256 piece hashing, version detection for v1/v2/hybrid torrents.
- **Test fixtures:** Create test `.torrent` files for v2-only and hybrid formats. Store in `testdata/`. Use `varuna-tools create` for Varuna-supported fixture generation, and use a v2-capable external creator such as libtorrent's Python bindings or mktorrent v2 when exercising unsupported BEP 52 fixture shapes.
- **Fuzz tests:** v2 file tree parsing (untrusted input from `.torrent` files).
- **Integration test:** Full download of a hybrid torrent, verifying both v1 and v2 hashes match.
- **Benchmark:** SHA-256 Merkle tree construction throughput for large files (compare with v1 flat SHA-1 hashing).

---

## Part 3: Implementation Order and Dependencies

### Recommended order:
1. **DHT Phase 1-2** (core protocol, active lookups) -- standalone, no other feature depends on it.
2. **BEP 52 Phase 1** (parsing) -- standalone, needed before any v2 work.
3. **BEP 52 Phase 2** (Merkle verification) -- depends on Phase 1.
4. **DHT Phase 3** (announce, persistence) -- depends on DHT Phase 1-2.
5. **BEP 52 Phase 3-4** (storage, protocol) -- depends on Phase 1-2.
6. **DHT Phase 4** (hardening) -- depends on Phase 3.
7. **BEP 52 Phase 5** (hash exchange) -- lowest priority, deferred.

### Cross-cutting concerns:
- **Bencode:** Both features reuse `src/torrent/bencode.zig` and `src/torrent/bencode_encode.zig`. No changes needed to the parser/encoder themselves.
- **io_uring:** DHT adds UDP send/recv to the event loop. BEP 52 adds SHA-256 to the hasher thread. Neither conflicts with existing io_uring paths.
- **SQLite:** DHT adds tables to the resume DB. BEP 52 extends the `pieces` table (wider info-hash column or separate table). Both run on the existing background thread.
- **Private torrents:** DHT must be disabled. BEP 52 is orthogonal to the private flag.

### Estimated scope:
- **DHT (all phases):** ~2000-3000 lines of Zig across 8 files, plus ~500 lines of tests.
- **BEP 52 (all phases):** ~1000-1500 lines of Zig across 4 new files + modifications to 6 existing files, plus ~400 lines of tests.
- **DHT is the larger feature** due to the stateful routing table, iterative lookup algorithm, and UDP protocol handling. BEP 52 is more surgical -- it extends existing structures rather than introducing a new subsystem.
