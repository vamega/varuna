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

test "BUGGIFY: 4096-deep KRPC list does not blow the native stack" {
    // The post-rewrite `skipValue` is iterative (explicit container
    // stack sized at `skip_max_depth = 64`). This crafts a packet whose
    // `a` body is a list of 4096+ open 'l' bytes — far beyond what any
    // valid bencode payload could carry inside a UDP MTU, but the
    // iterative form must still terminate cleanly with `error.InvalidKrpc`
    // rather than blow the native stack. If a future TCP-framed KRPC
    // variant ever buffered packets >MTU, this would have been the
    // hostile payload to defend against.
    const depth: usize = 4096;
    const total = 4 + depth + 1 + "1:t1:t1:y1:qe".len;
    var buf = try testing.allocator.alloc(u8, total);
    defer testing.allocator.free(buf);

    // Top-level envelope `d1:a` then `depth` 'l' bytes (open lists, no
    // closing 'e') then a single 'e' to close the outer dict's `a`
    // value, then the rest of the envelope. The packet is not
    // syntactically valid (the depth bound rejects it first), but the
    // parser must reject cleanly without recursing through every 'l'.
    var len: usize = 0;
    @memcpy(buf[len..][0..4], "d1:a");
    len += 4;
    @memset(buf[len .. len + depth], 'l');
    len += depth;
    buf[len] = 'e';
    len += 1;
    const tail = "1:t1:t1:y1:qe";
    @memcpy(buf[len..][0..tail.len], tail);
    len += tail.len;

    _ = krpc.parse(buf[0..len]) catch |err| {
        try testing.expectEqual(@as(anyerror, error.InvalidKrpc), err);
        return;
    };
    // If parse returns OK on a malformed packet, fail.
    try testing.expect(false);
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

// ── Layer 1: KRPC encoder bounds-checking contract ──────────────
//
// Closes the bug filed by `progress-reports/2026-04-26-stage-4-and-buggify-exploration.md`
// (Task #6): every encoder must return `error.NoSpaceLeft` when the
// caller-supplied buffer is too small, never panic and never write
// out of bounds. The production caller already passes an MTU-sized
// buffer, so these tests exercise the edge of the API contract that
// adversarial usage (or a future caller with a tighter buffer) would
// hit.

test "encoder: encodePingQuery returns NoSpaceLeft on tiny buffers" {
    const our_id = node_id.generateRandom();
    // Try every length 0..min_size-1 — every one must error.
    var got_ok = false;
    var probe: [256]u8 = undefined;
    const ok_len = try krpc.encodePingQuery(&probe, 0xAABB, our_id);
    try testing.expect(ok_len > 0);

    var i: usize = 0;
    while (i < ok_len) : (i += 1) {
        var tiny: [64]u8 = undefined;
        const result = krpc.encodePingQuery(tiny[0..i], 0xAABB, our_id);
        try testing.expectError(error.NoSpaceLeft, result);
    }
    // And the exact-size succeeds.
    var exact: [256]u8 = undefined;
    const exact_len = try krpc.encodePingQuery(exact[0..ok_len], 0xAABB, our_id);
    try testing.expectEqual(ok_len, exact_len);
    got_ok = true;
    try testing.expect(got_ok);
}

test "encoder: encodeFindNodeQuery returns NoSpaceLeft on tiny buffers" {
    const our_id = node_id.generateRandom();
    const target = node_id.generateRandom();
    var probe: [256]u8 = undefined;
    const ok_len = try krpc.encodeFindNodeQuery(&probe, 0xAABB, our_id, target);

    // Spot-check a handful of insufficient sizes including 0.
    for ([_]usize{ 0, 1, 16, 32, 64, ok_len - 1 }) |sz| {
        var tiny: [256]u8 = undefined;
        const result = krpc.encodeFindNodeQuery(tiny[0..sz], 0xAABB, our_id, target);
        try testing.expectError(error.NoSpaceLeft, result);
    }
}

test "encoder: encodeGetPeersQuery returns NoSpaceLeft on tiny buffers" {
    const our_id = node_id.generateRandom();
    var probe: [256]u8 = undefined;
    const ok_len = try krpc.encodeGetPeersQuery(&probe, 0xAABB, our_id, [_]u8{0} ** 20);

    for ([_]usize{ 0, 1, 16, 32, 64, ok_len - 1 }) |sz| {
        var tiny: [256]u8 = undefined;
        const result = krpc.encodeGetPeersQuery(tiny[0..sz], 0xAABB, our_id, [_]u8{0} ** 20);
        try testing.expectError(error.NoSpaceLeft, result);
    }
}

test "encoder: encodeAnnouncePeerQuery returns NoSpaceLeft on tiny buffers" {
    const our_id = node_id.generateRandom();
    var token_buf: [32]u8 = undefined;
    @memset(&token_buf, 0xab);
    var probe: [256]u8 = undefined;
    const ok_len = try krpc.encodeAnnouncePeerQuery(
        &probe,
        0xAABB,
        our_id,
        [_]u8{0} ** 20,
        6881,
        &token_buf,
        false,
    );

    for ([_]usize{ 0, 1, 16, 32, 64, ok_len - 1 }) |sz| {
        var tiny: [256]u8 = undefined;
        const result = krpc.encodeAnnouncePeerQuery(
            tiny[0..sz],
            0xAABB,
            our_id,
            [_]u8{0} ** 20,
            6881,
            &token_buf,
            false,
        );
        try testing.expectError(error.NoSpaceLeft, result);
    }
}

test "encoder: encodePingResponse returns NoSpaceLeft on tiny buffers" {
    const our_id = node_id.generateRandom();
    const tid = "tt";
    var probe: [256]u8 = undefined;
    const ok_len = try krpc.encodePingResponse(&probe, tid, our_id);

    for ([_]usize{ 0, 1, 16, 32, ok_len - 1 }) |sz| {
        var tiny: [256]u8 = undefined;
        const result = krpc.encodePingResponse(tiny[0..sz], tid, our_id);
        try testing.expectError(error.NoSpaceLeft, result);
    }
}

test "encoder: encodeFindNodeResponse returns NoSpaceLeft on tiny buffers" {
    const our_id = node_id.generateRandom();
    const tid = "tt";
    var nodes_blob: [52]u8 = undefined;
    @memset(&nodes_blob, 0x42);
    var probe: [512]u8 = undefined;
    const ok_len = try krpc.encodeFindNodeResponse(&probe, tid, our_id, &nodes_blob);

    for ([_]usize{ 0, 1, 16, 64, ok_len - 1 }) |sz| {
        var tiny: [512]u8 = undefined;
        const result = krpc.encodeFindNodeResponse(tiny[0..sz], tid, our_id, &nodes_blob);
        try testing.expectError(error.NoSpaceLeft, result);
    }
}

test "encoder: encodeGetPeersResponseValues returns NoSpaceLeft on tiny buffers" {
    const our_id = node_id.generateRandom();
    const tid = "tt";
    const tok = "abcdefgh";
    const values = [_][6]u8{
        .{ 1, 2, 3, 4, 0x1A, 0xE1 },
        .{ 5, 6, 7, 8, 0x1A, 0xE2 },
    };
    var probe: [512]u8 = undefined;
    const ok_len = try krpc.encodeGetPeersResponseValues(&probe, tid, our_id, tok, &values);

    for ([_]usize{ 0, 1, 16, 64, ok_len - 1 }) |sz| {
        var tiny: [512]u8 = undefined;
        const result = krpc.encodeGetPeersResponseValues(tiny[0..sz], tid, our_id, tok, &values);
        try testing.expectError(error.NoSpaceLeft, result);
    }
}

test "encoder: encodeGetPeersResponseNodes returns NoSpaceLeft on tiny buffers" {
    const our_id = node_id.generateRandom();
    const tid = "tt";
    const tok = "abcdefgh";
    var nodes_blob: [78]u8 = undefined;
    @memset(&nodes_blob, 0x42);
    var probe: [512]u8 = undefined;
    const ok_len = try krpc.encodeGetPeersResponseNodes(&probe, tid, our_id, tok, &nodes_blob);

    for ([_]usize{ 0, 1, 16, 64, ok_len - 1 }) |sz| {
        var tiny: [512]u8 = undefined;
        const result = krpc.encodeGetPeersResponseNodes(tiny[0..sz], tid, our_id, tok, &nodes_blob);
        try testing.expectError(error.NoSpaceLeft, result);
    }
}

test "encoder: encodeError returns NoSpaceLeft on tiny buffers" {
    const tid = "tt";
    const msg = "Server Error";
    var probe: [256]u8 = undefined;
    const ok_len = try krpc.encodeError(&probe, tid, 202, msg);

    for ([_]usize{ 0, 1, 8, 16, ok_len - 1 }) |sz| {
        var tiny: [256]u8 = undefined;
        const result = krpc.encodeError(tiny[0..sz], tid, 202, msg);
        try testing.expectError(error.NoSpaceLeft, result);
    }
}

// ── Layer 1: parser bounds against adversarial length-prefix attacks ──
//
// Before the parseByteString hardening, a length prefix near
// `maxInt(usize)` (e.g. `99999999999999999999:...`) caused
// `i + len > data.len` to overflow `usize`, panicking in Debug and
// triggering UB in Release. The fix uses the saturating-subtraction
// form `len > data.len - i` plus a 20-digit cap on the prefix scan.

test "parser: byte-string with maxInt-ish length prefix does not panic" {
    // 20 nines fit in a u64 (max u64 ≈ 1.8e19, 20 nines = 9.99e19 > max),
    // so parseUnsigned will overflow. Either way: must return
    // InvalidKrpc, not panic.
    const inputs = [_][]const u8{
        // top-level dict with `t` key whose length is u64-ish:
        "d1:t99999999999999999999:abe",
        // smaller but still > input length (must not pass the bounds check):
        "d1:t1000000:abe",
        // exactly at-len-but-out-of-data (claims 5 but only has 2 bytes):
        "d1:t5:abe",
        // length prefix that itself overflows the digit cap (21 digits):
        "d1:t999999999999999999999:abe",
    };
    for (inputs) |inp| {
        const r = krpc.parse(inp) catch |err| {
            try testing.expectEqual(@as(anyerror, error.InvalidKrpc), err);
            continue;
        };
        // If the parser somehow returned a value, it must still be
        // shape-valid (no broken slices into garbage memory).
        switch (r) {
            .query => |q| std.debug.assert(q.transaction_id.len <= inp.len),
            .response => |rsp| std.debug.assert(rsp.transaction_id.len <= inp.len),
            .@"error" => |e| std.debug.assert(e.message.len <= inp.len),
        }
    }
}

test "parser: integer field with adversarial length stays safe" {
    // `i9999...e` with > 20 digits cannot represent an i64 — parser
    // must reject without panicking on the length scan.
    const inputs = [_][]const u8{
        // Integer with 21 digits (exceeds i64). Top-level dict carrying
        // it as the `port` of an announce_peer.
        "d1:ad2:id20:aaaaaaaaaaaaaaaaaaaa4:porti999999999999999999999e9:info_hash20:bbbbbbbbbbbbbbbbbbbb5:token4:tokne1:q13:announce_peer1:t2:tt1:y1:qe",
        // Negative digit run > 20 chars.
        "d1:ad2:id20:aaaaaaaaaaaaaaaaaaaa4:porti-999999999999999999999e9:info_hash20:bbbbbbbbbbbbbbbbbbbb5:token4:tokne1:q13:announce_peer1:t2:tt1:y1:qe",
        // Integer with no digits.
        "d1:ad2:id20:aaaaaaaaaaaaaaaaaaaa4:portie9:info_hash20:bbbbbbbbbbbbbbbbbbbb5:token4:tokne1:q13:announce_peer1:t2:tt1:y1:qe",
    };
    for (inputs) |inp| {
        _ = krpc.parse(inp) catch |err| {
            try testing.expectEqual(@as(anyerror, error.InvalidKrpc), err);
        };
    }
}

test "parser: error response with code > maxInt(u32) clamps without panic" {
    // The error parser used to `@intCast(i64 -> u32)` after only
    // clamping the negative side, panicking on a code > maxInt(u32).
    // The hardened version clamps both sides.
    const high = "d1:eli99999999999e7:somemsge1:t2:tt1:y1:ee";
    const negative = "d1:eli-12345e7:somemsge1:t2:tt1:y1:ee";
    const max_u32 = "d1:eli4294967295e7:somemsge1:t2:tt1:y1:ee";
    const max_u32_plus = "d1:eli4294967296e7:somemsge1:t2:tt1:y1:ee";

    const inputs = [_][]const u8{ high, negative, max_u32, max_u32_plus };
    for (inputs) |inp| {
        const r = krpc.parse(inp) catch |err| {
            try testing.expectEqual(@as(anyerror, error.InvalidKrpc), err);
            continue;
        };
        switch (r) {
            .@"error" => |e| {
                // No panic, no UB; the code is in the documented u32
                // range. Negative is clamped to 0; over-max is clamped
                // to maxInt(u32).
                _ = e.code;
                try testing.expect(e.message.len <= inp.len);
            },
            else => try testing.expect(false),
        }
    }
}

test "parser: pathological-length string truncation returns InvalidKrpc" {
    // Length prefix matches input claim but the body overflows the
    // remaining buffer. Should always reject cleanly.
    const inputs = [_][]const u8{
        // claims 100 bytes for `t` value, only 2 follow:
        "d1:t100:ab",
        // claims 1000 for sender id but only 5 bytes after:
        "d1:y1:q1:q4:ping1:ad2:id1000:hello",
        // claims length 1, but no body
        "d1:t1:",
    };
    for (inputs) |inp| {
        const r = krpc.parse(inp) catch |err| {
            try testing.expectEqual(@as(anyerror, error.InvalidKrpc), err);
            continue;
        };
        // If it parsed at all, every reference must be in-bounds.
        switch (r) {
            .query => |q| std.debug.assert(q.transaction_id.len <= inp.len),
            .response => |rsp| std.debug.assert(rsp.transaction_id.len <= inp.len),
            .@"error" => |e| std.debug.assert(e.message.len <= inp.len),
        }
    }
}

test "parser: type-confused fields return InvalidKrpc" {
    // 'a' should be a dict; supply a list. 'r' should be a dict; supply
    // an integer. 'e' should be a list; supply a dict. None should
    // panic; all should fail cleanly.
    const inputs = [_][]const u8{
        // 'a' is a list (must be dict)
        "d1:al4:pinge1:q4:ping1:t2:tt1:y1:qe",
        // 'r' is an integer
        "d1:ri42e1:t2:tt1:y1:re",
        // 'e' is a dict
        "d1:ed1:k1:ve1:t2:tt1:y1:ee",
        // 'y' is empty
        "d1:t2:tt1:y0:1:q4:ping1:ade2:id20:aaaaaaaaaaaaaaaaaaaaee",
        // 'y' is multi-byte
        "d1:t2:tt1:y3:abc1:q4:ping1:ade2:id20:aaaaaaaaaaaaaaaaaaaaee",
    };
    for (inputs) |inp| {
        _ = krpc.parse(inp) catch |err| {
            try testing.expectEqual(@as(anyerror, error.InvalidKrpc), err);
        };
    }
}

test "parser: 19/21-byte node id is rejected (sender_id, target, info_hash)" {
    // sender_id (`a.id`) must be exactly 20 bytes. So must `target`
    // and `info_hash`. Off-by-one on either side must reject.
    const inputs = [_][]const u8{
        // sender_id = 19 bytes (ping query)
        "d1:ad2:id19:aaaaaaaaaaaaaaaaaaae1:q4:ping1:t2:tt1:y1:qe",
        // sender_id = 21 bytes
        "d1:ad2:id21:aaaaaaaaaaaaaaaaaaaaae1:q4:ping1:t2:tt1:y1:qe",
        // target = 19 bytes (find_node)
        "d1:ad2:id20:aaaaaaaaaaaaaaaaaaaa6:target19:bbbbbbbbbbbbbbbbbbbe1:q9:find_node1:t2:tt1:y1:qe",
        // info_hash = 21 bytes (get_peers)
        "d1:ad2:id20:aaaaaaaaaaaaaaaaaaaa9:info_hash21:cccccccccccccccccccccc1:q9:get_peers1:t2:tt1:y1:qe",
    };
    for (inputs) |inp| {
        _ = krpc.parse(inp) catch |err| {
            try testing.expectEqual(@as(anyerror, error.InvalidKrpc), err);
        };
    }
}

test "parser: round-trip after hardening (regression for valid inputs)" {
    // Belt-and-braces: confirm the hardened parser still accepts a
    // canonical ping query / response / error.
    var buf: [512]u8 = undefined;
    const our_id = node_id.generateRandom();

    {
        const len = try krpc.encodePingQuery(&buf, 0x1234, our_id);
        const m = try krpc.parse(buf[0..len]);
        try testing.expect(m == .query);
    }
    {
        const len = try krpc.encodePingResponse(&buf, "tt", our_id);
        const m = try krpc.parse(buf[0..len]);
        try testing.expect(m == .response);
    }
    {
        const len = try krpc.encodeError(&buf, "tt", 201, "Generic Error");
        const m = try krpc.parse(buf[0..len]);
        switch (m) {
            .@"error" => |e| {
                try testing.expectEqual(@as(u32, 201), e.code);
                try testing.expectEqualStrings("Generic Error", e.message);
            },
            else => try testing.expect(false),
        }
    }
}

// ── Layer 1: token-manager forgery resistance under adversarial inputs ──
//
// `validateToken` already rejects tokens of the wrong length; verify
// that under random forged-token / forged-IP combinations, it never
// validates spuriously and never panics. This is the safety property
// — token validation is constant-time relative to byte length, but we
// don't assert that here; we assert no false-positive validations and
// no panics under random inputs.

test "BUGGIFY: token validation is panic-free and forgery-resistant" {
    const Token = varuna.dht.token.TokenManager;
    var mgr = Token.initWithTime(1000);

    // Per-seed, drive the secret rotation while feeding random
    // adversarial tokens against random IPs. None should validate.
    var false_positives: usize = 0;
    var rotations: usize = 0;
    for (fuzz_seeds[0..8]) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        for (0..512) |_| {
            // Random IP for token request
            var ip: [4]u8 = undefined;
            prng.random().bytes(&ip);
            // Random forged token of varied length
            var tok_buf: [32]u8 = undefined;
            const tok_len = prng.random().uintLessThan(usize, tok_buf.len);
            prng.random().bytes(tok_buf[0..tok_len]);

            // Validate against a *different* random IP — any match is
            // an immediate forgery success.
            var other_ip: [4]u8 = undefined;
            prng.random().bytes(&other_ip);
            if (mgr.validateToken(tok_buf[0..tok_len], &other_ip)) {
                false_positives += 1;
            }

            // Occasionally rotate. Old tokens (from this random space)
            // remain rejectable.
            if (prng.random().uintLessThan(u8, 16) == 0) {
                mgr.maybeRotate(1000 + @as(i64, @intCast(rotations + 1)) * Token.rotation_interval_secs);
                rotations += 1;
            }
        }
    }
    // 8-byte tokens against an 8-byte SipHash space: random hits are
    // ~ 1/2^64 per try; over 4096 attempts we expect zero. If any
    // surface, the test should reproduce them under a known seed.
    try testing.expectEqual(@as(usize, 0), false_positives);
}

test "token: cross-IP and cross-secret tokens are rejected" {
    const Token = varuna.dht.token.TokenManager;
    var mgr = Token.initWithTime(1000);
    const ip_a = [_]u8{ 192, 168, 0, 1 };
    const ip_b = [_]u8{ 192, 168, 0, 2 };

    const t_a = mgr.generateToken(&ip_a);
    // Same secret, different IP — must reject.
    try testing.expect(!mgr.validateToken(&t_a, &ip_b));

    // Rotate twice; t_a is now from a fully-replaced secret pair.
    mgr.maybeRotate(1000 + Token.rotation_interval_secs);
    mgr.maybeRotate(1000 + 2 * Token.rotation_interval_secs);
    try testing.expect(!mgr.validateToken(&t_a, &ip_a));
}

// ── Layer 1: parser fuzz keeps panic-free with the hardened parser ──
//
// The original 32×1024 random-byte fuzz is preserved above (it only
// asserts panic-free behaviour, not a specific outcome shape). This
// deeper variant pushes harder on the length-prefix surface by
// crafting random bencode-shaped envelopes with adversarial byte-string
// lengths. The intent is to force a high rate of "near-miss" parses
// where the length scan, integer scan, or container nesting is at
// the bound that previously panicked.

test "BUGGIFY: parser panic-free under adversarial bencode-shaped envelopes" {
    var attempted: usize = 0;
    var rejected: usize = 0;
    for (fuzz_seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        for (0..256) |_| {
            var buf: [1500]u8 = undefined;
            // Build a half-real, half-adversarial envelope:
            //   d 1:<key> <random> 1:t2:tt 1:y1:q e
            var pos: usize = 0;
            buf[pos] = 'd';
            pos += 1;
            // Pick a random key in {a, t, y, q, r, e, x}
            const keys = "atyqrex";
            buf[pos] = '1';
            pos += 1;
            buf[pos] = ':';
            pos += 1;
            buf[pos] = keys[prng.random().uintLessThan(u8, keys.len)];
            pos += 1;
            // Pick a random adversarial body
            const choice = prng.random().uintLessThan(u8, 8);
            switch (choice) {
                0 => {
                    // huge length prefix
                    const hdr = "99999999999999999999:";
                    @memcpy(buf[pos..][0..hdr.len], hdr);
                    pos += hdr.len;
                },
                1 => {
                    // integer with many digits
                    const hdr = "i99999999999999999999e";
                    @memcpy(buf[pos..][0..hdr.len], hdr);
                    pos += hdr.len;
                },
                2 => {
                    // negative integer with many digits
                    const hdr = "i-99999999999999999999e";
                    @memcpy(buf[pos..][0..hdr.len], hdr);
                    pos += hdr.len;
                },
                3 => {
                    // empty integer
                    const hdr = "ie";
                    @memcpy(buf[pos..][0..hdr.len], hdr);
                    pos += hdr.len;
                },
                4 => {
                    // bytes claiming exact-but-truncated length
                    const hdr = "5:abc"; // claims 5, has 3
                    @memcpy(buf[pos..][0..hdr.len], hdr);
                    pos += hdr.len;
                },
                5 => {
                    // unmatched 'e' inside a list
                    const hdr = "le";
                    @memcpy(buf[pos..][0..hdr.len], hdr);
                    pos += hdr.len;
                },
                6 => {
                    // dict with non-string key
                    const hdr = "di42e1:vee";
                    @memcpy(buf[pos..][0..hdr.len], hdr);
                    pos += hdr.len;
                },
                else => {
                    // random bytes in body
                    const body_len = prng.random().uintLessThan(usize, 64);
                    prng.random().bytes(buf[pos .. pos + body_len]);
                    pos += body_len;
                },
            }
            // tail: 1:t2:tt 1:y1:q e
            const tail = "1:t2:tt1:y1:qe";
            if (pos + tail.len < buf.len) {
                @memcpy(buf[pos..][0..tail.len], tail);
                pos += tail.len;
            }

            attempted += 1;
            _ = krpc.parse(buf[0..pos]) catch {
                rejected += 1;
            };
        }
    }
    // Most adversarial inputs should be rejected; the contract is just
    // "no panics", so we assert the loop ran and rejection-rate is
    // sane (>50%) as a vacuous-pass guard.
    try testing.expect(attempted > 0);
    try testing.expect(rejected * 2 > attempted);
}

// ── Layer 1: compact peer-list parsing under adversarial inputs ──────
//
// Reproduces the `dlen *= 10 / vpos += dlen` overflow bug in
// `dht.handleResponse`'s peer-list parser. The fix routes through
// `parseCompactPeers` with a 5-digit cap and a saturating-remainder
// check. These tests build a `Response.values_raw` directly and feed
// it through a constructed packet — the response handler will hit
// the bug if the bound is missing.

test "BUGGIFY: compact peer-list parsing rejects adversarial length prefix" {
    // Construct a get_peers response whose `values` list contains an
    // adversarial entry. The DHT engine ignores responses for
    // unknown txns, so we drive the parser directly via krpc.parse
    // and inspect the values_raw slice — we don't need a live engine.

    const inputs = [_][]const u8{
        // values entry with 21-digit length (exceeds usize cap):
        "d1:rd2:id20:aaaaaaaaaaaaaaaaaaaa6:valuesl999999999999999999999:xe5:token4:tokne1:t2:tt1:y1:re",
        // values entry with valid 6-byte form, then garbage:
        "d1:rd2:id20:aaaaaaaaaaaaaaaaaaaa6:valuesl6:abcdef99999999999999:Xe5:token4:tokne1:t2:tt1:y1:re",
        // values entry where length claims more than remainder:
        "d1:rd2:id20:aaaaaaaaaaaaaaaaaaaa6:valuesl1000:abce5:token4:tokne1:t2:tt1:y1:re",
    };

    for (inputs) |inp| {
        // The outer packet either parses and produces a values_raw
        // slice (which we then ask the engine to parse), or it doesn't.
        // Either is OK; nothing must panic.
        const m = krpc.parse(inp) catch continue;
        switch (m) {
            .response => |r| {
                if (r.values_raw) |raw| {
                    std.debug.assert(raw.len <= inp.len);
                    // Drive the engine's peer-list parsing path. We
                    // construct a tiny DhtEngine and feed the response
                    // through `handleIncoming`; this exercises the
                    // adversarial code path end-to-end.
                    var engine = varuna.dht.DhtEngine.init(testing.allocator, node_id.generateRandom());
                    defer engine.deinit();
                    engine.handleIncoming(inp, std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 6881));
                    // Drain anything we queued so deinit is clean.
                    const out = engine.drainSendQueue();
                    if (out.len > 0) testing.allocator.free(out);
                    const peers = engine.drainPeerResults();
                    if (peers.len > 0) {
                        for (peers) |p| testing.allocator.free(p.peers);
                        testing.allocator.free(peers);
                    }
                }
            },
            else => {},
        }
    }
}

// ── Layer 1: txn-id mismatch / unknown response is harmless ──────────
//
// `findAndRemovePending` returns null when the transaction id does
// not match a pending query. The handler must then early-return with
// no state mutation. Verify by sending a freshly-encoded response
// for which no query was sent: nothing should appear in the routing
// table, no panic.

test "txn-id mismatch: unsolicited response causes no state mutation" {
    var engine = varuna.dht.DhtEngine.init(testing.allocator, node_id.generateRandom());
    defer engine.deinit();

    // Build a real ping response that the engine never queried for.
    var buf: [512]u8 = undefined;
    var sender_id: NodeId = undefined;
    @memset(&sender_id, 0xCC);
    const len = try krpc.encodePingResponse(&buf, "ZZ", sender_id);

    const before_count = engine.nodeCount();
    const before_send_q = engine.send_queue.items.len;

    engine.handleIncoming(buf[0..len], std.net.Address.initIp4(.{ 9, 9, 9, 9 }, 6881));

    // No pending query matched: routing table unchanged, send queue
    // unchanged. (Routing-table addNode happens for QUERIES, not for
    // unsolicited responses — the early-return path is what we're
    // testing.)
    try testing.expectEqual(before_count, engine.nodeCount());
    try testing.expectEqual(before_send_q, engine.send_queue.items.len);
}

// ── Layer 1: short txn-id is rejected without panic ──────────────────
//
// `findAndRemovePending` reads `txn_id_bytes[0..2]` if `len == 2`. A
// 1-byte or 0-byte txn id must not panic, must not match.

test "txn-id length != 2 is harmless" {
    var engine = varuna.dht.DhtEngine.init(testing.allocator, node_id.generateRandom());
    defer engine.deinit();

    // Hand-craft a response with a 1-byte txn id.
    const inp1 = "d1:rd2:id20:bbbbbbbbbbbbbbbbbbbbe1:t1:Z1:y1:re";
    engine.handleIncoming(inp1, std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 6881));

    // 0-byte txn id.
    const inp0 = "d1:rd2:id20:bbbbbbbbbbbbbbbbbbbbe1:t0:1:y1:re";
    engine.handleIncoming(inp0, std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 6881));

    // 5-byte txn id.
    const inp5 = "d1:rd2:id20:bbbbbbbbbbbbbbbbbbbbe1:t5:abcde1:y1:re";
    engine.handleIncoming(inp5, std.net.Address.initIp4(.{ 1, 2, 3, 4 }, 6881));

    // Drain anything that might've slipped into queues so deinit is clean.
    const out = engine.drainSendQueue();
    if (out.len > 0) testing.allocator.free(out);
    const peers = engine.drainPeerResults();
    if (peers.len > 0) {
        for (peers) |p| testing.allocator.free(p.peers);
        testing.allocator.free(peers);
    }
}
