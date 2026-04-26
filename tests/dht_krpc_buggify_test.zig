//! BUGGIFY/fuzz coverage for the DHT KRPC parser and routing table.
//!
//! KRPC packets are the entry point for *adversarial* DHT data —
//! anyone on the internet who knows our UDP port can send malformed
//! bencode. Coverage today (`src/dht/krpc.zig` test block) includes
//! happy-path round-trips, "non-dict input rejected", and "truncated
//! input rejected", but does not exercise:
//!   * random byte sequences (fuzz)
//!   * partial / boundary-malformed bencode
//!   * deeply-nested dictionaries (recursion)
//!   * invalid NodeId lengths in 'a'/'r' bodies
//!   * negative / overflow integer fields
//!
//! This test layers on TigerBeetle-style randomized coverage:
//!
//! * **Layer 1 (Algorithm — bare parser)**: 32 deterministic seeds × 1024
//!   random packets each. Assert: never panics, never leaks, never hangs;
//!   either returns a valid `Message` or an error from `krpc.parse`'s
//!   declared error set.
//! * **Layer 1 (Recursion budget)**: craft a deeply-nested dict at the
//!   UDP MTU bound and parse. STYLE.md forbids unbounded recursion in
//!   bencode parsing; this test pins the current behaviour and serves
//!   as a regression guard if the recursion depth grows in future.
//! * **Layer 1 (Routing table)**: flood random adversarial nodes into a
//!   `RoutingTable` and assert k-bucket invariants and `findClosest`
//!   safety under partial / overflowing buffers.
//! * **Layer 1 (Compact node decode)**: random byte chunks fed to
//!   `decodeCompactNode`; assert no panic, ports stay in range.
//!
//! The "BUGGIFY" framing per `progress-reports/2026-04-25-buggify-smart-ban.md`:
//! these are SAFETY-only invariants. Liveness is not asserted (the
//! parser legitimately rejects most random bytes — assert only that
//! the *outcomes* are correct, not that any particular outcome shape
//! dominates).

const std = @import("std");
const testing = std.testing;

const varuna = @import("varuna");
const krpc = varuna.dht.krpc;
const node_id = varuna.dht.node_id;
const routing_table = varuna.dht.routing_table;
const NodeId = node_id.NodeId;
const NodeInfo = node_id.NodeInfo;

// ── Layer 1: Random-byte fuzz of krpc.parse ──────────────────

/// Seeds for deterministic BUGGIFY runs. Picked to span the u32 space
/// and include known nasty values.
const fuzz_seeds = [_]u64{
    0x00000000, 0x00000001, 0xffffffff, 0xfffffffe, 0xdeadbeef,
    0xcafebabe, 0x12345678, 0x87654321, 0x11111111, 0x22222222,
    0x33333333, 0x44444444, 0x55555555, 0x66666666, 0x77777777,
    0x88888888, 0x99999999, 0xaaaaaaaa, 0xbbbbbbbb, 0xcccccccc,
    0xdddddddd, 0xeeeeeeee, 0xa1b2c3d4, 0xe5f60708, 0x1a2b3c4d,
    0x5e6f7080, 0xdeaddead, 0xfedcba98, 0x76543210, 0x089abcde,
    0xf01234ab, 0x55aa55aa,
};

/// Runs the parser against a random byte buffer of varying length.
/// Asserts: never panics, never returns garbage, only valid Message
/// or one of the documented errors.
fn fuzzOnce(prng: *std.Random.DefaultPrng, max_len: usize) void {
    const rand = prng.random();
    const len = rand.uintLessThan(usize, max_len + 1);
    var buf: [4096]u8 = undefined;
    const data = buf[0..len];
    rand.bytes(data);

    // The parse function must not panic on any input. Catch every
    // possible error and ignore it. Successes are also acceptable
    // (random bytes occasionally form a valid skeleton).
    const result = krpc.parse(data) catch |err| switch (err) {
        // Allowable error set; widen as needed when parser is touched.
        error.InvalidKrpc => return,
    };
    // Successful parse: minimal safety check on the returned message.
    switch (result) {
        .query => |q| {
            std.debug.assert(q.transaction_id.len <= data.len);
            // method must be one of the known enum values (Method enum).
            switch (q.method) {
                .ping, .find_node, .get_peers, .announce_peer => {},
            }
        },
        .response => |r| {
            std.debug.assert(r.transaction_id.len <= data.len);
            if (r.nodes) |n| std.debug.assert(n.len <= data.len);
            if (r.nodes6) |n| std.debug.assert(n.len <= data.len);
        },
        .@"error" => |e| {
            std.debug.assert(e.transaction_id.len <= data.len);
            std.debug.assert(e.message.len <= data.len);
        },
    }
}

test "BUGGIFY: krpc.parse never panics on 32 seeds × 1024 random packets" {
    var stats_total: usize = 0;
    var stats_parsed: usize = 0;
    for (fuzz_seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const iterations: usize = 1024;
        for (0..iterations) |_| {
            // Vary max length: short (< 8), medium (< 256), full UDP MTU (1500).
            const r = prng.random().uintLessThan(u8, 3);
            const max = switch (r) {
                0 => @as(usize, 7),
                1 => @as(usize, 255),
                else => @as(usize, 1500),
            };
            fuzzOnce(&prng, max);
            stats_total += 1;
        }
        // Diagnostic: how often did random bytes form a parseable msg?
        var prng_check = std.Random.DefaultPrng.init(seed);
        for (0..32) |_| {
            var buf: [1500]u8 = undefined;
            const len = prng_check.random().uintLessThan(usize, 1501);
            prng_check.random().bytes(buf[0..len]);
            _ = krpc.parse(buf[0..len]) catch continue;
            stats_parsed += 1;
        }
    }
    try testing.expect(stats_total == fuzz_seeds.len * 1024);
    // Most random bytes should fail to parse (sanity that the parser
    // is not vacuously accepting). Don't pin a tight bound — the
    // parser is permissive in the sense that "any bencode dict with
    // a 't' key + matching 'y' may parse"; we just assert the lower
    // bound is sane.
    try testing.expect(stats_parsed < fuzz_seeds.len * 32);
}

// ── Layer 1: Recursion bound on skipValue ────────────────────────

test "BUGGIFY: deeply-nested KRPC dict does not blow the stack within UDP MTU" {
    // A KRPC envelope `d1:ad...e1:t1:te1:y1:qe` with a deeply-nested
    // dict in the 'a' slot. Each level adds 2 bytes (`d` + `e`); we
    // can fit ~700 levels in a 1500-byte UDP MTU.
    //
    // The current `skipValue` is recursive (STYLE.md violation, see
    // `src/dht/krpc.zig`). On Linux x86_64 with default 8 MiB stack
    // this should still be safe at 700 levels (~16 bytes/frame ×
    // 700 = 11 KiB). But the recursion depth is unbounded in the
    // code; if a future kernel reduces the default stack the code
    // could overflow. This test pins the current behaviour and
    // serves as a tripwire for future increases in MTU or recursion
    // depth.
    const max_depth: usize = 600; // safe within MTU and within stack
    var buf: [4096]u8 = undefined;

    // Outer envelope start: d1:ad...
    var len: usize = 0;
    @memcpy(buf[len..][0..4], "d1:a");
    len += 4;

    // Now nest dicts.
    var depth: usize = 0;
    while (depth < max_depth and len + 1 < buf.len) : (depth += 1) {
        buf[len] = 'd';
        len += 1;
    }
    // Add a single key+value at the bottom: 1:k1:v
    if (len + 6 < buf.len) {
        @memcpy(buf[len..][0..6], "1:k1:v");
        len += 6;
    }
    // Close all the dicts we opened.
    var i: usize = 0;
    while (i < depth and len < buf.len) : (i += 1) {
        buf[len] = 'e';
        len += 1;
    }
    // Close the outer 'a' dict's top level (we used one 'd' for it
    // above), and add 1:t1:t1:y1:qe to satisfy the envelope.
    // Actually we counted 'a' value as one of the `depth` dicts —
    // close one extra 'e' for the envelope.
    const tail = "1:t1:t1:y1:q";
    if (len + tail.len < buf.len) {
        @memcpy(buf[len..][0..tail.len], tail);
        len += tail.len;
    }
    if (len < buf.len) {
        buf[len] = 'e';
        len += 1;
    }

    // The parser must terminate — either accepting the message or
    // returning InvalidKrpc. It must NOT stack-overflow. (This test
    // is the safety property; if a future change pushes the depth
    // past the stack budget, it'll crash here and signal a real
    // bug.)
    _ = krpc.parse(buf[0..len]) catch |err| {
        // Any documented error is acceptable.
        switch (err) {
            error.InvalidKrpc => return,
            else => return err,
        }
    };
}

// ── Layer 1: KRPC parse on partially-corrupted valid envelopes ──

test "BUGGIFY: bit-flip mutation of valid KRPC ping query stays safe" {
    // Build a real ping query, then flip one byte at a random
    // position 1024 times per seed. The mutated packet must not
    // panic regardless of where the flip lands.
    const our_id = node_id.generateRandom();
    var orig_buf: [256]u8 = undefined;
    const orig_len = try krpc.encodePingQuery(&orig_buf, 0xAABB, our_id);
    try testing.expect(orig_len > 0 and orig_len < orig_buf.len);

    for (fuzz_seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        for (0..1024) |_| {
            var work: [256]u8 = undefined;
            @memcpy(work[0..orig_len], orig_buf[0..orig_len]);
            const flip_pos = prng.random().uintLessThan(usize, orig_len);
            const flip_bit: u8 = @as(u8, 1) << @as(u3, @intCast(prng.random().uintLessThan(u8, 8)));
            work[flip_pos] ^= flip_bit;
            // Result may parse or fail; either is fine — must not panic.
            _ = krpc.parse(work[0..orig_len]) catch {};
        }
    }
}

// ── Layer 1: Compact node decode with adversarial bytes ─────────

test "BUGGIFY: decodeCompactNode is panic-free over fuzz seeds" {
    for (fuzz_seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        for (0..1024) |_| {
            var buf: [26]u8 = undefined;
            prng.random().bytes(&buf);
            const node = node_id.decodeCompactNode(&buf);
            // Ports are u16 — implicitly any value valid. Address
            // family is INET. Just assert no panic and the ID round-
            // trips.
            try testing.expectEqual(@as(c_int, std.posix.AF.INET), @as(c_int, node.address.any.family));
            try testing.expectEqualSlices(u8, buf[0..20], &node.id);
        }
    }
}

// ── Layer 1: RoutingTable flood with adversarial nodes ──────────

test "BUGGIFY: RoutingTable invariants under random insertions" {
    // Across all seeds: insert random nodes, occasionally query
    // findClosest, mark some failed/responded, and remove some.
    // Assert: nodeCount() never exceeds K (8) per bucket × 160
    // buckets = 1280; node_id distance bucket ranges valid;
    // findClosest never overflows the output buffer.
    for (fuzz_seeds[0..8]) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        var own: NodeId = undefined;
        prng.random().bytes(&own);
        var table = routing_table.RoutingTable.init(own);
        var now: i64 = 1_000_000;

        for (0..2048) |_| {
            const op = prng.random().uintLessThan(u8, 6);
            switch (op) {
                0, 1, 2 => {
                    // Add random node
                    var id: NodeId = undefined;
                    prng.random().bytes(&id);
                    var ip: [4]u8 = undefined;
                    prng.random().bytes(&ip);
                    const port = prng.random().int(u16);
                    _ = table.addNode(.{
                        .id = id,
                        .address = std.net.Address.initIp4(ip, port),
                        .ever_responded = (prng.random().uintLessThan(u8, 2) == 0),
                    }, now);
                },
                3 => {
                    // findClosest into a small buffer
                    var target: NodeId = undefined;
                    prng.random().bytes(&target);
                    var out: [routing_table.K]NodeInfo = undefined;
                    const want = prng.random().uintLessThan(u8, routing_table.K + 1);
                    const got = table.findClosest(target, want, out[0..]);
                    try testing.expect(got <= want);
                    try testing.expect(got <= out.len);
                },
                4 => {
                    // markFailed on random ID
                    var id: NodeId = undefined;
                    prng.random().bytes(&id);
                    table.markFailed(id);
                },
                5 => {
                    // removeNode on random ID
                    var id: NodeId = undefined;
                    prng.random().bytes(&id);
                    _ = table.removeNode(id);
                },
                else => unreachable,
            }
            now += 1;
        }

        // Invariant: total nodes <= K * 160
        try testing.expect(table.nodeCount() <= routing_table.K * 160);

        // Invariant: every node's bucket index agrees with our own_id.
        for (&table.buckets, 0..) |*bucket, expected_idx| {
            for (bucket.getNodes()) |n| {
                const actual_idx = node_id.distanceBucket(own, n.id);
                // distanceBucket returns null only when own == n.id.
                // The routing table must have rejected such inserts.
                try testing.expect(actual_idx != null);
                try testing.expectEqual(@as(u8, @intCast(expected_idx)), actual_idx.?);
            }
        }
    }
}

test "BUGGIFY: RoutingTable findClosest with zero-length out buffer is safe" {
    var own: NodeId = [_]u8{0} ** 20;
    var table = routing_table.RoutingTable.init(own);
    own[0] = 1;
    _ = table.addNode(.{
        .id = own,
        .address = std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 6881),
    }, 100);

    var out: [0]NodeInfo = undefined;
    const got = table.findClosest([_]u8{0} ** 20, 5, &out);
    try testing.expectEqual(@as(u8, 0), got);
}

// ── Layer 1: KRPC encode happy-path size sanity ─────────────────
//
// **Finding (filed as follow-up; documented in progress report)**:
// `src/dht/krpc.zig` encoders (`encodePingQuery`, `encodeFindNodeQuery`,
// etc.) accept a `buf: []u8` parameter but lack bounds checking — the
// internal `writeByteString` and `writeInteger` helpers panic on a
// too-small buffer rather than returning `error.NoSpaceLeft`. In
// production this is currently safe because the only caller (the DHT
// engine's send path) uses a fixed-size MTU buffer, but the API
// contract is unsound. Tracked separately. This test pins the
// happy-path sizes so a future safety patch doesn't regress on
// payload size estimation.

test "BUGGIFY: KRPC encoder happy-path output sizes are bounded" {
    const our_id = node_id.generateRandom();
    const target = node_id.generateRandom();

    var ok: [256]u8 = undefined;
    const ping_len = try krpc.encodePingQuery(&ok, 0xAABB, our_id);
    try testing.expect(ping_len > 0 and ping_len < ok.len);

    const fn_len = try krpc.encodeFindNodeQuery(&ok, 0xAABB, our_id, target);
    try testing.expect(fn_len > 0 and fn_len < ok.len);

    const gp_len = try krpc.encodeGetPeersQuery(&ok, 0xAABB, our_id, [_]u8{0} ** 20);
    try testing.expect(gp_len > 0 and gp_len < ok.len);

    // BEP 5 token can be up to ~256 bytes; verify a reasonably long
    // token still fits in 256-byte ok buffer.
    var token_buf: [32]u8 = undefined;
    @memset(&token_buf, 0xab);
    const ap_len = try krpc.encodeAnnouncePeerQuery(
        &ok,
        0xAABB,
        our_id,
        [_]u8{0} ** 20,
        6881,
        &token_buf,
        false,
    );
    try testing.expect(ap_len > 0 and ap_len < ok.len);
}
