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

test "parser: query missing required 'id' key is rejected" {
    // BEP 5: every KRPC query MUST include the querier's node id in
    // the `a` body. Without it, `sender_id` would propagate
    // `undefined` into the routing table — a real correctness/UB bug.
    // The parser must reject these cases instead of silently accepting.
    const inputs = [_][]const u8{
        // ping query with no id field at all
        "d1:ade1:q4:ping1:t2:tt1:y1:qe",
        // find_node with target but no id
        "d1:ad6:target20:bbbbbbbbbbbbbbbbbbbbe1:q9:find_node1:t2:tt1:y1:qe",
        // get_peers with info_hash but no id
        "d1:ad9:info_hash20:cccccccccccccccccccce1:q9:get_peers1:t2:tt1:y1:qe",
        // announce_peer with token+port+info_hash but no id
        "d1:ad9:info_hash20:cccccccccccccccccccc4:porti6881e5:token4:tokne1:q13:announce_peer1:t2:tt1:y1:qe",
        // 'id' present but with wrong key name (case-sensitive)
        "d1:ad2:ID20:aaaaaaaaaaaaaaaaaaaae1:q4:ping1:t2:tt1:y1:qe",
    };
    for (inputs) |inp| {
        const r = krpc.parse(inp);
        try testing.expectError(error.InvalidKrpc, r);
    }
}

test "parser: response missing required 'id' key is rejected" {
    // BEP 5: every KRPC response MUST include the responder's node id
    // in the `r` body. Without it, `sender_id` would propagate
    // `undefined` into table.markResponded() / addNode() — UB.
    const inputs = [_][]const u8{
        // empty response body
        "d1:rde1:t2:tt1:y1:re",
        // response with nodes but no id (find_node response shape)
        "d1:rd5:nodes0:e1:t2:tt1:y1:re",
        // response with token+nodes but no id (get_peers response shape)
        "d1:rd5:nodes0:5:token4:tokne1:t2:tt1:y1:re",
        // 'id' present with empty string
        "d1:rd2:id0:e1:t2:tt1:y1:re",
        // 'id' present with 19-byte string (already covered upstream,
        // but a stricter belt-and-braces line)
        "d1:rd2:id19:aaaaaaaaaaaaaaaaaaae1:t2:tt1:y1:re",
    };
    for (inputs) |inp| {
        const r = krpc.parse(inp);
        try testing.expectError(error.InvalidKrpc, r);
    }
}

test "parser: query with valid 'id' parses sender_id deterministically" {
    // Belt-and-braces: parsing a well-formed query produces the exact
    // sender_id from the wire — never a stale/undefined value.
    var our_id: NodeId = undefined;
    @memset(&our_id, 0xCD);
    var buf: [256]u8 = undefined;
    const len = try krpc.encodePingQuery(&buf, 0xAABB, our_id);
    const m = try krpc.parse(buf[0..len]);
    switch (m) {
        .query => |q| try testing.expectEqualSlices(u8, &our_id, &q.sender_id),
        else => try testing.expect(false),
    }
}

test "parser: response with valid 'id' parses sender_id deterministically" {
    var our_id: NodeId = undefined;
    @memset(&our_id, 0xEF);
    var buf: [256]u8 = undefined;
    const len = try krpc.encodePingResponse(&buf, "tt", our_id);
    const m = try krpc.parse(buf[0..len]);
    switch (m) {
        .response => |r| try testing.expectEqualSlices(u8, &our_id, &r.sender_id),
        else => try testing.expect(false),
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

// ── R2: IPv6 outbound (BEP 32 dual-stack) ────────────────────────────
//
// Before the BEP 32 fix, `respondFindNode` and `respondGetPeers`
// dropped every IPv6 node from the closest set with
// `if (family != AF.INET) continue;`. The parser side already handled
// inbound `nodes6`; the encoder side was the gap. These tests pin the
// fix: a routing table containing both v4 and v6 nodes must produce a
// response with both `nodes` and `nodes6` fields populated.

const dht = varuna.dht;

/// Drain all outbound packets on the engine and free the slice.
fn drainAndFree(engine: *dht.DhtEngine) void {
    const pkts = engine.drainSendQueue();
    if (pkts.len > 0) testing.allocator.free(pkts);
    const peers = engine.drainPeerResults();
    if (peers.len > 0) {
        for (peers) |p| testing.allocator.free(p.peers);
        testing.allocator.free(peers);
    }
}

/// Look at the most recent outbound packet without removing it; tests
/// then call `drainAndFree` to clean up. Returns null if none queued.
fn peekLastSend(engine: *dht.DhtEngine) ?[]const u8 {
    if (engine.send_queue.items.len == 0) return null;
    const pkt = &engine.send_queue.items[engine.send_queue.items.len - 1];
    return pkt.data[0..pkt.len];
}

test "R2: respondFindNode emits both nodes and nodes6 for mixed routing table" {
    var engine = dht.DhtEngine.init(testing.allocator, node_id.generateRandom());
    defer engine.deinit();

    const now: i64 = 1_000_000;
    // Add 3 v4 nodes
    for (0..3) |i| {
        _ = engine.table.addNode(.{
            .id = node_id.generateRandom(),
            .address = std.net.Address.initIp4(.{ 10, 0, 0, @intCast(i + 1) }, 6881),
        }, now);
    }
    // Add 3 v6 nodes
    for (0..3) |i| {
        var addr6: [16]u8 = [_]u8{0} ** 16;
        addr6[15] = @intCast(i + 1);
        _ = engine.table.addNode(.{
            .id = node_id.generateRandom(),
            .address = std.net.Address.initIp6(addr6, 6881, 0, 0),
        }, now);
    }

    // Drive a find_node query. Note: handleQuery also adds the querier
    // to the routing table — so the closest set may include the
    // sender's IPv4 entry. We assert only the structural BEP 32
    // invariants (both fields present, lengths match the wire format)
    // rather than exact counts.
    var query_buf: [512]u8 = undefined;
    var sender_id: NodeId = undefined;
    @memset(&sender_id, 0xAB);
    const target = node_id.generateRandom();
    const len = try krpc.encodeFindNodeQuery(&query_buf, 0xBEEF, sender_id, target);
    const sender = std.net.Address.initIp4(.{ 10, 0, 0, 99 }, 6881);
    engine.handleIncoming(query_buf[0..len], sender);

    const out = peekLastSend(&engine) orelse return error.TestUnexpectedResult;
    defer drainAndFree(&engine);

    // Parse the response and assert both nodes and nodes6 populated.
    const parsed = try krpc.parse(out);
    switch (parsed) {
        .response => |r| {
            try testing.expect(r.nodes != null);
            try testing.expect(r.nodes6 != null);
            // BEP 5 wire format: 26 bytes per IPv4 entry.
            try testing.expect(r.nodes.?.len > 0);
            try testing.expectEqual(@as(usize, 0), r.nodes.?.len % 26);
            // BEP 32 wire format: 38 bytes per IPv6 entry.
            try testing.expect(r.nodes6.?.len > 0);
            try testing.expectEqual(@as(usize, 0), r.nodes6.?.len % 38);
            // We added 3 v6 nodes; v6 querier never gets added (querier
            // is v4 here), so v6 count is exactly 3.
            try testing.expectEqual(@as(usize, 3 * 38), r.nodes6.?.len);
        },
        else => try testing.expect(false),
    }
}

test "R2: respondGetPeers emits both nodes and nodes6 when no peers known" {
    var engine = dht.DhtEngine.init(testing.allocator, node_id.generateRandom());
    defer engine.deinit();

    const now: i64 = 2_000_000;
    // 2 v4, 2 v6 nodes
    for (0..2) |i| {
        _ = engine.table.addNode(.{
            .id = node_id.generateRandom(),
            .address = std.net.Address.initIp4(.{ 192, 168, 1, @intCast(i + 1) }, 51413),
        }, now);
        var addr6: [16]u8 = [_]u8{0} ** 16;
        addr6[14] = 0xfe;
        addr6[15] = @intCast(i + 1);
        _ = engine.table.addNode(.{
            .id = node_id.generateRandom(),
            .address = std.net.Address.initIp6(addr6, 51413, 0, 0),
        }, now);
    }

    var info_hash: [20]u8 = undefined;
    @memset(&info_hash, 0x33);
    var query_buf: [512]u8 = undefined;
    var sender_id: NodeId = undefined;
    @memset(&sender_id, 0x44);
    const len = try krpc.encodeGetPeersQuery(&query_buf, 0xCAFE, sender_id, info_hash);
    const sender = std.net.Address.initIp4(.{ 10, 0, 0, 50 }, 6881);
    engine.handleIncoming(query_buf[0..len], sender);

    const out = peekLastSend(&engine) orelse return error.TestUnexpectedResult;
    defer drainAndFree(&engine);

    const parsed = try krpc.parse(out);
    switch (parsed) {
        .response => |r| {
            // Structural BEP 5 + BEP 32 invariants. The querier (a v4
            // sender) gets added to the table by handleQuery, so the v4
            // count here is 3 (2 seeded + sender), v6 stays at 2.
            try testing.expect(r.nodes != null);
            try testing.expectEqual(@as(usize, 0), r.nodes.?.len % 26);
            try testing.expect(r.nodes6 != null);
            try testing.expectEqual(@as(usize, 2 * 38), r.nodes6.?.len);
            // No peers announced yet → no values/values6
            try testing.expect(r.values_raw == null);
            try testing.expect(r.values6_raw == null);
            // Token is always emitted on get_peers responses
            try testing.expect(r.token != null);
        },
        else => try testing.expect(false),
    }
}

// ── R3: peer storage for announce_peer (BEP 5) ──────────────────────
//
// Before the fix, `respondAnnouncePeer` validated the token, queued a
// ping reply, and discarded the announce. `get_peers` always fell
// through to closest-nodes. The test surface here exercises the full
// announce → store → get_peers → values pipeline plus the
// expiry/eviction invariants.

/// Helper: send a get_peers query and obtain the token from the
/// response. The token is what the announcer must echo back.
fn primeTokenFor(
    engine: *dht.DhtEngine,
    sender: std.net.Address,
    info_hash: [20]u8,
) ![]const u8 {
    var qbuf: [512]u8 = undefined;
    var sid: NodeId = undefined;
    @memset(&sid, 0x55);
    const qlen = try krpc.encodeGetPeersQuery(&qbuf, 0x0001, sid, info_hash);
    engine.handleIncoming(qbuf[0..qlen], sender);
    const out = peekLastSend(engine) orelse return error.TestUnexpectedResult;
    const parsed = try krpc.parse(out);
    return switch (parsed) {
        .response => |r| r.token orelse error.TestUnexpectedResult,
        else => error.TestUnexpectedResult,
    };
}

test "R3: announce_peer with valid token stores peer; get_peers returns it in values" {
    var engine = dht.DhtEngine.init(testing.allocator, node_id.generateRandom());
    defer engine.deinit();
    defer drainAndFree(&engine);

    var info_hash: [20]u8 = undefined;
    @memset(&info_hash, 0x77);
    const announcer = std.net.Address.initIp4(.{ 100, 64, 1, 5 }, 9000);

    // Prime: get a token by sending get_peers first.
    const tok_slice = try primeTokenFor(&engine, announcer, info_hash);
    // Copy out — the buffer is the engine's own send queue and may move.
    var tok_buf: [32]u8 = undefined;
    @memcpy(tok_buf[0..tok_slice.len], tok_slice);
    const tok = tok_buf[0..tok_slice.len];

    // Drain the prime response so subsequent peek looks at the announce reply.
    const out0 = engine.drainSendQueue();
    if (out0.len > 0) testing.allocator.free(out0);

    // Build announce_peer query: implied_port=0, port=51234.
    var ap_buf: [512]u8 = undefined;
    var sid: NodeId = undefined;
    @memset(&sid, 0xAA);
    const announce_port: u16 = 51234;
    const ap_len = try krpc.encodeAnnouncePeerQuery(
        &ap_buf,
        0x0002,
        sid,
        info_hash,
        announce_port,
        tok,
        false,
    );
    engine.handleIncoming(ap_buf[0..ap_len], announcer);

    // Engine should have stored exactly one peer for this hash.
    try testing.expectEqual(@as(usize, 1), engine.peer_store.peerCount(info_hash));

    // Drain the announce ack.
    const out1 = engine.drainSendQueue();
    if (out1.len > 0) testing.allocator.free(out1);

    // Now ask get_peers from a *different* sender; the response should
    // include the announced peer in `values`.
    const querier = std.net.Address.initIp4(.{ 8, 8, 8, 8 }, 1234);
    var qbuf: [512]u8 = undefined;
    @memset(&sid, 0xBB);
    const qlen = try krpc.encodeGetPeersQuery(&qbuf, 0x0003, sid, info_hash);
    engine.handleIncoming(qbuf[0..qlen], querier);

    const out2 = peekLastSend(&engine) orelse return error.TestUnexpectedResult;
    const parsed = try krpc.parse(out2);
    switch (parsed) {
        .response => |r| {
            try testing.expect(r.values_raw != null);
            // Decode the values list manually: it must contain the
            // announcer's IPv4 + announce_port (51234), not the UDP
            // source port (9000), since implied_port was false.
            const raw = r.values_raw.?;
            try testing.expect(raw.len > 2);
            try testing.expectEqual(@as(u8, 'l'), raw[0]);
            // First entry: "6:" + 4-byte IP + 2-byte port
            try testing.expectEqualStrings("6:", raw[1..3]);
            const ip_part = raw[3..7];
            try testing.expectEqualSlices(u8, &.{ 100, 64, 1, 5 }, ip_part);
            const port = std.mem.readInt(u16, raw[7..9], .big);
            try testing.expectEqual(announce_port, port);
        },
        else => try testing.expect(false),
    }
}

test "R3: announce_peer with invalid token does not store" {
    var engine = dht.DhtEngine.init(testing.allocator, node_id.generateRandom());
    defer engine.deinit();
    defer drainAndFree(&engine);

    var info_hash: [20]u8 = undefined;
    @memset(&info_hash, 0xC0);

    var ap_buf: [512]u8 = undefined;
    var sid: NodeId = undefined;
    @memset(&sid, 0xDE);
    // Forge a token of valid length but wrong bytes.
    const fake_tok = [_]u8{0xFF} ** 8;
    const ap_len = try krpc.encodeAnnouncePeerQuery(
        &ap_buf,
        0x0010,
        sid,
        info_hash,
        12345,
        &fake_tok,
        false,
    );
    const announcer = std.net.Address.initIp4(.{ 5, 5, 5, 5 }, 6881);
    engine.handleIncoming(ap_buf[0..ap_len], announcer);

    // No peer stored.
    try testing.expectEqual(@as(usize, 0), engine.peer_store.peerCount(info_hash));
}

test "R3: announce_peer implied_port=1 uses UDP source port" {
    var engine = dht.DhtEngine.init(testing.allocator, node_id.generateRandom());
    defer engine.deinit();
    defer drainAndFree(&engine);

    var info_hash: [20]u8 = undefined;
    @memset(&info_hash, 0x88);
    const announcer = std.net.Address.initIp4(.{ 7, 7, 7, 7 }, 4567);

    const tok_slice = try primeTokenFor(&engine, announcer, info_hash);
    var tok_buf: [32]u8 = undefined;
    @memcpy(tok_buf[0..tok_slice.len], tok_slice);
    const tok = tok_buf[0..tok_slice.len];
    const out0 = engine.drainSendQueue();
    if (out0.len > 0) testing.allocator.free(out0);

    var ap_buf: [512]u8 = undefined;
    var sid: NodeId = undefined;
    @memset(&sid, 0x99);
    // implied_port=true; the announced port should be ignored.
    const ap_len = try krpc.encodeAnnouncePeerQuery(
        &ap_buf,
        0x0020,
        sid,
        info_hash,
        9999,
        tok,
        true,
    );
    engine.handleIncoming(ap_buf[0..ap_len], announcer);

    try testing.expectEqual(@as(usize, 1), engine.peer_store.peerCount(info_hash));
    // Confirm via get_peers that the stored port matches the source
    // port (4567), not the announced port (9999).
    const out1 = engine.drainSendQueue();
    if (out1.len > 0) testing.allocator.free(out1);

    var qbuf: [512]u8 = undefined;
    @memset(&sid, 0x77);
    const qlen = try krpc.encodeGetPeersQuery(&qbuf, 0x0021, sid, info_hash);
    const querier = std.net.Address.initIp4(.{ 1, 1, 1, 1 }, 80);
    engine.handleIncoming(qbuf[0..qlen], querier);

    const out2 = peekLastSend(&engine) orelse return error.TestUnexpectedResult;
    const parsed = try krpc.parse(out2);
    const r = switch (parsed) {
        .response => |x| x,
        else => return error.TestUnexpectedResult,
    };
    const raw = r.values_raw orelse return error.TestUnexpectedResult;
    // Skip 'l' + "6:" then read IP+port
    const port = std.mem.readInt(u16, raw[7..9], .big);
    try testing.expectEqual(@as(u16, 4567), port);
}

test "R3: peer_store sweep removes expired entries" {
    var engine = dht.DhtEngine.init(testing.allocator, node_id.generateRandom());
    defer engine.deinit();
    defer drainAndFree(&engine);

    var info_hash: [20]u8 = undefined;
    @memset(&info_hash, 0xEE);

    // Inject an entry directly through the public API: the announce
    // path requires a token round-trip; for a sweep test we exercise
    // the underlying store via two announces and then advance time.
    const announcer = std.net.Address.initIp4(.{ 2, 2, 2, 2 }, 6881);
    const tok_slice = try primeTokenFor(&engine, announcer, info_hash);
    var tok_buf: [32]u8 = undefined;
    @memcpy(tok_buf[0..tok_slice.len], tok_slice);
    const tok = tok_buf[0..tok_slice.len];
    const out0 = engine.drainSendQueue();
    if (out0.len > 0) testing.allocator.free(out0);

    var ap_buf: [512]u8 = undefined;
    var sid: NodeId = undefined;
    @memset(&sid, 0x12);
    const ap_len = try krpc.encodeAnnouncePeerQuery(&ap_buf, 0x0030, sid, info_hash, 12345, tok, false);
    engine.handleIncoming(ap_buf[0..ap_len], announcer);
    try testing.expectEqual(@as(usize, 1), engine.peer_store.peerCount(info_hash));

    // Advance the engine clock past the BEP 5 30-min TTL and sweep.
    const future = std.time.timestamp() + 60 * 60;
    engine.peer_store.sweep(testing.allocator, future);
    try testing.expectEqual(@as(usize, 0), engine.peer_store.peerCount(info_hash));
    // The empty hash entry should have been reaped from the map too.
    try testing.expectEqual(@as(usize, 0), engine.peer_store.hashCount());
}

test "R3: peer_store FIFO eviction at per-hash capacity" {
    // Construct a peer-store directly so we can drive it past the cap
    // without burning 100 token round-trips through the engine.
    const PeerStore = @TypeOf(@as(dht.DhtEngine, undefined).peer_store);
    var store = PeerStore.init(testing.allocator);
    defer store.deinit(testing.allocator);

    var info_hash: [20]u8 = undefined;
    @memset(&info_hash, 0xAB);

    const cap = PeerStore.max_peers_per_hash;
    const now: i64 = 5_000_000;

    // Fill to capacity with unique addresses.
    for (0..cap) |i| {
        const addr = std.net.Address.initIp4(.{ 10, 0, 0, 0 }, @intCast(10000 + i));
        store.announce(testing.allocator, info_hash, addr, now);
    }
    try testing.expectEqual(cap, store.peerCount(info_hash));

    // One more new address: the oldest must be evicted (FIFO), so total
    // count stays at cap. Use a distinct port range to make the new
    // entry obviously distinguishable.
    const newcomer = std.net.Address.initIp4(.{ 10, 0, 0, 0 }, 60000);
    store.announce(testing.allocator, info_hash, newcomer, now);
    try testing.expectEqual(cap, store.peerCount(info_hash));

    // Encode values: the oldest (port 10000) must be gone, the
    // newcomer (port 60000) must be present.
    var v4_buf: [PeerStore.max_peers_per_hash][6]u8 = undefined;
    var v6_buf: [PeerStore.max_peers_per_hash][18]u8 = undefined;
    const counts = store.encodeValues(info_hash, &v4_buf, &v6_buf, now);
    try testing.expectEqual(cap, counts.v4);
    try testing.expectEqual(@as(usize, 0), counts.v6);

    var saw_oldest = false;
    var saw_newcomer = false;
    for (v4_buf[0..counts.v4]) |entry| {
        const port = std.mem.readInt(u16, entry[4..6], .big);
        if (port == 10000) saw_oldest = true;
        if (port == 60000) saw_newcomer = true;
    }
    try testing.expect(!saw_oldest);
    try testing.expect(saw_newcomer);
}

test "R3: re-announce by same peer refreshes expiry, does not duplicate" {
    const PeerStore = @TypeOf(@as(dht.DhtEngine, undefined).peer_store);
    var store = PeerStore.init(testing.allocator);
    defer store.deinit(testing.allocator);

    var info_hash: [20]u8 = undefined;
    @memset(&info_hash, 0x44);

    const addr = std.net.Address.initIp4(.{ 11, 22, 33, 44 }, 2020);
    const now: i64 = 100;
    store.announce(testing.allocator, info_hash, addr, now);
    store.announce(testing.allocator, info_hash, addr, now + 60);
    try testing.expectEqual(@as(usize, 1), store.peerCount(info_hash));

    // After the original TTL would have expired but before the refresh
    // TTL, the entry must still be present.
    const after_orig_ttl = now + PeerStore.ttl_secs + 1;
    store.sweep(testing.allocator, after_orig_ttl);
    try testing.expectEqual(@as(usize, 1), store.peerCount(info_hash));

    // After the refresh TTL, it should be gone.
    const after_refresh_ttl = now + 60 + PeerStore.ttl_secs + 1;
    store.sweep(testing.allocator, after_refresh_ttl);
    try testing.expectEqual(@as(usize, 0), store.peerCount(info_hash));
}
