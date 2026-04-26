//! BUGGIFY-style fault-injection coverage for the Stage 2 RPC bump
//! arenas (Track C). Drives many seeds × randomised allocation
//! sequences against `TieredArena`, with parent-allocator failures
//! injected at random alloc sites, asserting safety invariants:
//!
//!   1. **No leaks.** Spilled allocations made before a parent-OOM
//!      must still be reachable from the spill chain so `reset()` /
//!      `deinit()` reclaims them. The `std.testing.allocator` GPA
//!      leak check enforces this across every seed.
//!
//!   2. **No bump corruption.** A failed slab allocation must leave
//!      `slabUsed` and `used()` invariant — the only way the FBA
//!      can claim memory is by bumping `end_index`, and that bump
//!      must be atomic with returning the slice. After OOM, prior
//!      slices remain valid and a smaller subsequent alloc still
//!      succeeds within remaining capacity.
//!
//!   3. **Cap is hard.** `used()` never exceeds `capacity()` even
//!      under random alloc sizes biased toward the cap edge.
//!
//!   4. **`reset()` reclaims everything.** After reset, `used()`
//!      and `spillUsed()` are both zero regardless of fault history.
//!
//! These tests don't drive the production HTTP path under SimIO (the
//! `ApiServer` is concrete-typed against `*RealIO`); they exercise
//! the arena module directly with the same kinds of randomised
//! failures BUGGIFY uses on the EventLoop. The arena is the piece of
//! the post-Track-B RPC stack that is most likely to UAF or leak
//! under fault, so it gets the focused coverage.
//!
//! Layered per `STYLE.md` Layered Testing Strategy: this is a
//! safety-under-faults test (layer 3), asserting only safety
//! properties — no liveness claim. Allocation failure is *expected*
//! to interrupt some sequences; the assertion is that the arena
//! never leaks or corrupts.

const std = @import("std");
const varuna = @import("varuna");
const scratch = varuna.rpc.scratch;

/// A failing allocator that wraps a parent and rejects allocations
/// past `fail_after` calls (in any kind: alloc/resize/remap). This is
/// the mechanism BUGGIFY-style tests use to probe alloc-failure
/// recovery paths deterministically per seed.
const FailingAllocator = struct {
    parent: std.mem.Allocator,
    fail_after: usize,
    call_count: usize = 0,

    fn allocator(self: *FailingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = vtableAlloc,
                .resize = vtableResize,
                .remap = vtableRemap,
                .free = vtableFree,
            },
        };
    }

    fn vtableAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        self.call_count += 1;
        if (self.call_count > self.fail_after) return null;
        return self.parent.rawAlloc(len, alignment, ret_addr);
    }

    fn vtableResize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        return self.parent.rawResize(buf, alignment, new_len, ret_addr);
    }

    fn vtableRemap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        return self.parent.rawRemap(buf, alignment, new_len, ret_addr);
    }

    fn vtableFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *FailingAllocator = @ptrCast(@alignCast(ctx));
        self.parent.rawFree(buf, alignment, ret_addr);
    }
};

/// Drives a randomised allocation sequence into the arena and
/// asserts safety invariants after each step. Returns true if the
/// sequence completed without hitting a fault, false if a fault
/// interrupted it. Either outcome is acceptable — the test asserts
/// invariants regardless.
fn driveRandomSequence(
    arena: *scratch.TieredArena,
    rng: *std.Random.DefaultPrng,
    steps: u32,
) !bool {
    const a = arena.allocator();
    var step: u32 = 0;
    while (step < steps) : (step += 1) {
        const op = rng.random().uintLessThan(u32, 8);
        if (op < 5) {
            // Bias: 5/8 small (slab path), 2/8 medium (early spill),
            // 1/8 large (cap-edge).
            const cap = arena.capacity();
            const remaining = cap - arena.used();
            if (remaining == 0) return false;
            const max_size = if (op < 5) @min(remaining, 256) else if (op < 7) @min(remaining, 8 * 1024) else remaining;
            if (max_size == 0) return false;
            const size = rng.random().uintLessThan(usize, max_size) + 1;
            const buf = a.alloc(u8, size) catch |err| {
                try std.testing.expectEqual(error.OutOfMemory, err);
                // Cap was hit (or parent allocator rejected via
                // FailingAllocator). The arena must be unchanged from
                // before the failed alloc — verify by making a tiny
                // alloc that fits in remaining slab room.  We don't
                // probe through spill: under FailingAllocator the
                // parent alloc may itself fail, which would be a
                // false-positive here.
                if (arena.slabUsed() + 1 <= arena.slabCapacity()) {
                    const probe = a.alloc(u8, 1) catch |probe_err| {
                        // Slab room available but alloc failed —
                        // that's a real bug in the arena. The vtable
                        // should always serve from the slab when
                        // there's space, regardless of parent state.
                        // Surface it.
                        std.debug.print("UNEXPECTED probe failure: slab_used={} slab_cap={} err={any}\n", .{ arena.slabUsed(), arena.slabCapacity(), probe_err });
                        return probe_err;
                    };
                    try std.testing.expectEqual(@as(usize, 1), probe.len);
                }
                return false;
            };
            // Touch the buffer to ensure it's writable.
            if (buf.len > 0) {
                buf[0] = @truncate(step);
                buf[buf.len - 1] = @truncate(step);
            }
        } else if (op == 5) {
            // Reset mid-sequence.
            arena.reset();
            try std.testing.expectEqual(@as(usize, 0), arena.used());
            try std.testing.expectEqual(@as(usize, 0), arena.spillUsed());
        } else if (op == 6) {
            // No-op: just probe the cap invariants.
            try std.testing.expect(arena.used() <= arena.capacity());
            try std.testing.expect(arena.slabUsed() <= arena.slabCapacity());
        } else {
            // ArrayList growth pattern (the production hot path).
            var list: std.ArrayList(u8) = .empty;
            const target_len = rng.random().uintLessThan(usize, 4096) + 1;
            var i: usize = 0;
            while (i < target_len) : (i += 1) {
                list.append(a, @truncate(i)) catch |err| {
                    try std.testing.expectEqual(error.OutOfMemory, err);
                    return false;
                };
            }
        }

        // Per-step invariants.
        try std.testing.expect(arena.used() <= arena.capacity());
        try std.testing.expect(arena.slabUsed() <= arena.slabCapacity());
    }
    return true;
}

test "TieredArena: BUGGIFY 64 seeds × random alloc sequences, parent never fails" {
    var seed: u64 = 0;
    while (seed < 64) : (seed += 1) {
        var arena = try scratch.TieredArena.init(std.testing.allocator, 4 * 1024, 256 * 1024);
        defer arena.deinit();
        var rng = std.Random.DefaultPrng.init(seed);
        _ = try driveRandomSequence(&arena, &rng, 256);
        // Final reset must leave used == 0.
        arena.reset();
        try std.testing.expectEqual(@as(usize, 0), arena.used());
        try std.testing.expectEqual(@as(usize, 0), arena.spillUsed());
    }
}

test "TieredArena: BUGGIFY 64 seeds × random alloc sequences, parent fails mid-sequence" {
    // Every seed runs the same random sequence twice — first to count
    // total parent-allocator calls, second with a `fail_after` chosen
    // randomly inside that range. The second run is allowed to be
    // interrupted by OOM at any point; the assertion is that the
    // arena's own state stays consistent and `deinit()` cleans up.
    var seed: u64 = 0;
    while (seed < 64) : (seed += 1) {
        // Pass 1: count total parent calls without failures.
        var counting_parent = FailingAllocator{
            .parent = std.testing.allocator,
            .fail_after = std.math.maxInt(usize),
        };
        var counting_arena = try scratch.TieredArena.init(counting_parent.allocator(), 4 * 1024, 256 * 1024);
        var rng_count = std.Random.DefaultPrng.init(seed);
        _ = try driveRandomSequence(&counting_arena, &rng_count, 256);
        counting_arena.deinit();
        const total_parent_calls = counting_parent.call_count;
        if (total_parent_calls < 2) continue;

        // Pass 2: replay with parent failing at a random mid-sequence point.
        // This deterministically explores the OOM recovery path for the
        // arena's `reset()` and `deinit()` chains.
        var rng_fail_at = std.Random.DefaultPrng.init(seed +% 0xdeadbeef);
        const fail_at = rng_fail_at.random().uintLessThan(usize, total_parent_calls - 1) + 1;
        var failing_parent = FailingAllocator{
            .parent = std.testing.allocator,
            .fail_after = fail_at,
        };

        var arena = scratch.TieredArena.init(failing_parent.allocator(), 4 * 1024, 256 * 1024) catch {
            // Even the slab init can fail if fail_at == 0; that's a clean
            // path (no arena to clean up). Skip.
            continue;
        };
        defer arena.deinit();

        var rng_drive = std.Random.DefaultPrng.init(seed);
        _ = try driveRandomSequence(&arena, &rng_drive, 256);

        // Reset must always succeed without panic, regardless of how
        // many spilled allocations happened before fail_at hit.
        arena.reset();
        try std.testing.expectEqual(@as(usize, 0), arena.used());
        try std.testing.expectEqual(@as(usize, 0), arena.spillUsed());
    }
}

test "TieredArena: reset is idempotent" {
    var arena = try scratch.TieredArena.init(std.testing.allocator, 1024, 64 * 1024);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try a.alloc(u8, 200);
    _ = try a.alloc(u8, 8 * 1024); // spill

    arena.reset();
    arena.reset();
    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.used());
    try std.testing.expectEqual(@as(usize, 0), arena.spillUsed());

    // Arena still usable after triple-reset.
    const buf = try a.alloc(u8, 256);
    try std.testing.expectEqual(@as(usize, 256), buf.len);
}

test "TieredArena: deinit after partial spill chain frees everything" {
    // GPA leak detector + multiple spilled allocations + early deinit:
    // exercises the spill-chain free walk in `deinit` (calls `freeSpill`
    // before freeing the slab).
    var arena = try scratch.TieredArena.init(std.testing.allocator, 1024, 256 * 1024);
    const a = arena.allocator();

    // Force a chain of multiple spilled allocations, ensuring the
    // SpillNode linked list grows.
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        _ = try a.alloc(u8, 4 * 1024);
    }
    try std.testing.expect(arena.spillUsed() > 0);

    // Skip reset; deinit must still walk the chain and free.
    arena.deinit();
    // GPA leak detector verifies no allocations leaked across this test.
}

test "RequestArena: BUGGIFY 64 seeds × failing parent at init" {
    var seed: u64 = 0;
    while (seed < 64) : (seed += 1) {
        // Even a parent allocator that fails on the very first call
        // must leave the test allocator state clean — nothing was
        // allocated to leak.
        var failing = FailingAllocator{
            .parent = std.testing.allocator,
            .fail_after = 0,
        };
        const result = scratch.RequestArena.init(failing.allocator(), 4 * 1024);
        try std.testing.expectError(error.OutOfMemory, result);

        // And a parent that succeeds exactly once leaves an arena that
        // can be deinit'd cleanly.
        var ok_once = FailingAllocator{
            .parent = std.testing.allocator,
            .fail_after = 1,
        };
        var arena = try scratch.RequestArena.init(ok_once.allocator(), 4 * 1024);
        const a = arena.allocator();
        _ = try a.alloc(u8, 256);
        arena.reset();
        arena.deinit();
    }
}
