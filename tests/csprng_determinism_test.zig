//! End-to-end determinism coverage for the daemon-seeded CSPRNG.
//!
//! The 2026-04-29 SimRandom round documented five callers as a
//! "crypto-determinism boundary" deliberately left on
//! `std.crypto.random` (MSE handshake DH keys, peer ID, DHT node ID,
//! DHT tokens, RPC SID). The 2026-04-30 CSPRNG migration closed that
//! boundary by routing all five through `runtime.Random`, which now
//! wraps `std.Random.ChaCha` (ChaCha8 IETF) in both production and
//! sim variants — the only difference is the seed source. Production
//! seeds 32 bytes from `std.crypto.random.bytes()` once at daemon
//! startup; sim builds inject a deterministic 32-byte seed via
//! `Random.simRandomFromKey` or its u64 convenience overload
//! `Random.simRandom`.
//!
//! This file replaces the behavioural assertions previously needed
//! at the boundary with byte-equality assertions. The
//! crypto-determinism boundary is now closed — see
//! `progress-reports/2026-04-30-csprng-migration.md` and
//! `docs/simulation-roadmap.md` Phase 2 #2.

const std = @import("std");
const testing = std.testing;
const varuna = @import("varuna");

const Random = varuna.runtime.Random;
const peer_id_mod = varuna.torrent.peer_id;
const node_id = varuna.dht.node_id;
const TokenManager = varuna.dht.token.TokenManager;
const SessionStore = varuna.rpc.auth.SessionStore;
const mse = varuna.crypto.mse;

// ── Foundation: same key produces same byte stream ────────────

test "CSPRNG: simRandomFromKey is byte-deterministic across instances" {
    const key: [Random.seed_length]u8 = .{
        0x00, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07,
        0x08, 0x09, 0x0a, 0x0b, 0x0c, 0x0d, 0x0e, 0x0f,
        0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17,
        0x18, 0x19, 0x1a, 0x1b, 0x1c, 0x1d, 0x1e, 0x1f,
    };

    var r1 = Random.simRandomFromKey(key);
    var r2 = Random.simRandomFromKey(key);

    var a: [4096]u8 = undefined;
    var b: [4096]u8 = undefined;
    r1.bytes(&a);
    r2.bytes(&b);
    try testing.expectEqualSlices(u8, &a, &b);
}

test "CSPRNG: distinct seeds produce distinct streams" {
    var r1 = Random.simRandomFromKey(@as([32]u8, @splat(1)));
    var r2 = Random.simRandomFromKey(@as([32]u8, @splat(2)));

    var a: [128]u8 = undefined;
    var b: [128]u8 = undefined;
    r1.bytes(&a);
    r2.bytes(&b);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}

// ── Per-caller determinism (was: behavioural assertions) ──────

test "CSPRNG closes boundary: peer ID is byte-deterministic" {
    var r1 = Random.simRandom(0xc0ffee);
    var r2 = Random.simRandom(0xc0ffee);
    const id1 = try peer_id_mod.generate(&r1, null);
    const id2 = try peer_id_mod.generate(&r2, null);
    try testing.expectEqualSlices(u8, &id1, &id2);
}

test "CSPRNG closes boundary: peer ID with masquerade is byte-deterministic" {
    var r1 = Random.simRandom(0xfeedface);
    var r2 = Random.simRandom(0xfeedface);
    const id1 = try peer_id_mod.generate(&r1, "qBittorrent 5.1.4");
    const id2 = try peer_id_mod.generate(&r2, "qBittorrent 5.1.4");
    try testing.expectEqualSlices(u8, &id1, &id2);
}

test "CSPRNG closes boundary: DHT node ID is byte-deterministic" {
    var r1 = Random.simRandom(0xdeadbeef);
    var r2 = Random.simRandom(0xdeadbeef);
    const n1 = node_id.generateRandom(&r1);
    const n2 = node_id.generateRandom(&r2);
    try testing.expectEqualSlices(u8, &n1, &n2);
}

test "CSPRNG closes boundary: DHT token-manager init is byte-deterministic" {
    var r1 = Random.simRandom(0xcafebabe);
    var r2 = Random.simRandom(0xcafebabe);
    const m1 = TokenManager.init(&r1);
    const m2 = TokenManager.init(&r2);
    try testing.expectEqualSlices(u8, &m1.secret, &m2.secret);
    try testing.expectEqualSlices(u8, &m1.prev_secret, &m2.prev_secret);
}

test "CSPRNG closes boundary: DHT token-rotation is byte-deterministic" {
    var r1 = Random.simRandom(0xdadabad);
    var r2 = Random.simRandom(0xdadabad);
    var m1 = TokenManager.initWithTime(&r1, 1000);
    var m2 = TokenManager.initWithTime(&r2, 1000);
    m1.maybeRotate(&r1, 1000 + TokenManager.rotation_interval_secs);
    m2.maybeRotate(&r2, 1000 + TokenManager.rotation_interval_secs);
    try testing.expectEqualSlices(u8, &m1.secret, &m2.secret);
    try testing.expectEqualSlices(u8, &m1.prev_secret, &m2.prev_secret);
}

test "CSPRNG closes boundary: RPC SID is byte-deterministic" {
    var r1 = Random.simRandom(0xa11ce);
    var r2 = Random.simRandom(0xa11ce);
    var s1 = SessionStore{};
    var s2 = SessionStore{};
    const sid1 = s1.createSession(&r1);
    const sid2 = s2.createSession(&r2);
    try testing.expectEqualSlices(u8, &sid1, &sid2);
}

test "CSPRNG closes boundary: MSE DH private key is byte-deterministic" {
    // The handshake state machine generates its DH private key at
    // `init` from the injected `*Random`. Two initiator handshakes
    // built off two `simRandom(seed)` instances must produce the
    // same `private_key`, `public_key`, and (after seeing the same
    // peer key) the same `shared_secret`.
    const info_hash = @as([20]u8, @splat(0x42));

    var r1 = Random.simRandom(0xb01);
    var r2 = Random.simRandom(0xb01);

    const hs1 = mse.MseInitiatorHandshake.init(&r1, info_hash, .preferred);
    const hs2 = mse.MseInitiatorHandshake.init(&r2, info_hash, .preferred);

    try testing.expectEqualSlices(u8, &hs1.private_key, &hs2.private_key);
    try testing.expectEqualSlices(u8, &hs1.public_key, &hs2.public_key);
}

test "CSPRNG closes boundary: MSE responder DH private key is byte-deterministic" {
    const known: [1][20]u8 = .{@as([20]u8, @splat(0xAA))};

    var r1 = Random.simRandom(0xb02);
    var r2 = Random.simRandom(0xb02);

    const hs1 = mse.MseResponderHandshake.init(&r1, &known, .preferred);
    const hs2 = mse.MseResponderHandshake.init(&r2, &known, .preferred);

    try testing.expectEqualSlices(u8, &hs1.private_key, &hs2.private_key);
    try testing.expectEqualSlices(u8, &hs1.public_key, &hs2.public_key);
}

// ── Whole-daemon determinism: one shared `*Random` reproduces
//    every sensitive output across two runs ───────────────────

const DaemonOutput = struct {
    peer_id: [20]u8,
    node_id: [20]u8,
    token_secret: [16]u8,
    sid: [SessionStore.sid_len]u8,
    mse_private_key: [mse.dh_key_size]u8,
    mse_public_key: [mse.dh_key_size]u8,
};

fn runDaemonScenario(seed: u64) !DaemonOutput {
    // Single shared `*Random`, mirroring the production wiring where
    // every call site borrows from `EventLoop.random`.
    var rng = Random.simRandom(seed);

    const pid = try peer_id_mod.generate(&rng, null);
    const nid = node_id.generateRandom(&rng);
    const token_mgr = TokenManager.initWithTime(&rng, 1_700_000_000);
    var session_store = SessionStore{};
    const sid = session_store.createSession(&rng);
    const info_hash = @as([20]u8, @splat(0xDE));
    const hs = mse.MseInitiatorHandshake.init(&rng, info_hash, .preferred);

    return .{
        .peer_id = pid,
        .node_id = nid,
        .token_secret = token_mgr.secret,
        .sid = sid,
        .mse_private_key = hs.private_key,
        .mse_public_key = hs.public_key,
    };
}

test "CSPRNG closes boundary: same seed reproduces every sensitive output" {
    const a = try runDaemonScenario(0xdeadbeef_c0ffee);
    const b = try runDaemonScenario(0xdeadbeef_c0ffee);

    try testing.expectEqualSlices(u8, &a.peer_id, &b.peer_id);
    try testing.expectEqualSlices(u8, &a.node_id, &b.node_id);
    try testing.expectEqualSlices(u8, &a.token_secret, &b.token_secret);
    try testing.expectEqualSlices(u8, &a.sid, &b.sid);
    try testing.expectEqualSlices(u8, &a.mse_private_key, &b.mse_private_key);
    try testing.expectEqualSlices(u8, &a.mse_public_key, &b.mse_public_key);
}

test "CSPRNG closes boundary: distinct seeds give distinct sensitive outputs" {
    const a = try runDaemonScenario(1);
    const b = try runDaemonScenario(2);

    // Every sensitive output should differ across distinct seeds.
    try testing.expect(!std.mem.eql(u8, &a.peer_id, &b.peer_id));
    try testing.expect(!std.mem.eql(u8, &a.node_id, &b.node_id));
    try testing.expect(!std.mem.eql(u8, &a.token_secret, &b.token_secret));
    try testing.expect(!std.mem.eql(u8, &a.sid, &b.sid));
    try testing.expect(!std.mem.eql(u8, &a.mse_private_key, &b.mse_private_key));
    try testing.expect(!std.mem.eql(u8, &a.mse_public_key, &b.mse_public_key));
}

test "CSPRNG closes boundary: 32-byte key reproduces sensitive outputs" {
    // The full-strength API (`simRandomFromKey([32]u8)`) — the same
    // shape `realRandom()` uses internally after reading 32 bytes
    // from the OS CSPRNG.
    const key: [Random.seed_length]u8 = blk: {
        var k: [Random.seed_length]u8 = undefined;
        for (&k, 0..) |*b, i| b.* = @as(u8, @intCast(i));
        break :blk k;
    };

    var r1 = Random.simRandomFromKey(key);
    var r2 = Random.simRandomFromKey(key);

    const pid1 = try peer_id_mod.generate(&r1, null);
    const pid2 = try peer_id_mod.generate(&r2, null);
    try testing.expectEqualSlices(u8, &pid1, &pid2);

    const nid1 = node_id.generateRandom(&r1);
    const nid2 = node_id.generateRandom(&r2);
    try testing.expectEqualSlices(u8, &nid1, &nid2);
}
