//! Bounded bump (request) arena for control-plane allocation.
//!
//! Stage 2 of the zero-allocation plan (see `STYLE.md` Memory section): the
//! control plane uses a bump allocator with a hard upper bound. The bump
//! pointer is reset after each operation completes. Two flavours:
//!
//! * `RequestArena` — a single fixed-size slab. `alloc` bumps within the
//!   slab and returns `error.OutOfMemory` past the end. Used by the DHT
//!   tick path and tracker announce parsing where the workload is bounded
//!   by protocol.
//!
//! * `TieredArena` — a small fixed-size slab as the fast path, with
//!   automatic fallback to the parent allocator when the slab is full
//!   (capped at a per-arena cap). Used by `ApiServer` per-slot, where the
//!   fast path covers the typical small response while `/sync/maindata`
//!   for thousands of torrents transparently spills to the parent. On
//!   `reset()` the slab bump pointer goes to zero and all spilled
//!   allocations are freed in LIFO order.
//!
//! Per `STYLE.md`: "If there is a finite upper bound, the allocation
//! belongs in `init`. If there is no bound, the code belongs on the
//! control plane behind a bump allocator." This is that bump allocator.

const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;

/// Single fixed-size bump arena. Allocations beyond the slab return OOM.
pub const RequestArena = struct {
    parent: Allocator,
    backing: []u8,
    fba: std.heap.FixedBufferAllocator,
    high_water: usize = 0,

    pub fn init(parent: Allocator, capacity_bytes: usize) !RequestArena {
        assert(capacity_bytes > 0);
        const buf = try parent.alloc(u8, capacity_bytes);
        return .{
            .parent = parent,
            .backing = buf,
            .fba = std.heap.FixedBufferAllocator.init(buf),
        };
    }

    pub fn deinit(self: *RequestArena) void {
        self.parent.free(self.backing);
        self.* = undefined;
    }

    pub fn allocator(self: *RequestArena) Allocator {
        return self.fba.allocator();
    }

    pub fn reset(self: *RequestArena) void {
        if (self.fba.end_index > self.high_water) self.high_water = self.fba.end_index;
        self.fba.reset();
    }

    pub fn used(self: *const RequestArena) usize {
        return self.fba.end_index;
    }

    pub fn capacity(self: *const RequestArena) usize {
        return self.backing.len;
    }

    pub fn highWater(self: *const RequestArena) usize {
        const live = self.fba.end_index;
        return if (live > self.high_water) live else self.high_water;
    }
};

/// Tiered bump arena: small fixed slab as the fast path, with automatic
/// spill to the parent allocator for the rest of the allocation up to a
/// hard cap. `reset()` returns the slab bump pointer to zero AND frees all
/// spilled allocations.
///
/// Allocations served from the slab are zero-cost (no parent allocator
/// call). Allocations that overflow the slab fall through to the parent;
/// they are tracked in an intrusive linked list so reset can free them.
///
/// The cap is enforced on the cumulative used bytes (slab + spill). When
/// exceeded, `alloc` returns `error.OutOfMemory` exactly like a fixed
/// arena.
pub const TieredArena = struct {
    parent: Allocator,
    backing: []u8,
    fba: std.heap.FixedBufferAllocator,
    /// Cumulative bytes used across slab and spill (since the last reset).
    /// Hard-capped at `cap_bytes`.
    used_bytes: usize = 0,
    cap_bytes: usize,
    /// Head of the linked list of spilled allocations to free on reset.
    spill_head: ?*SpillNode = null,
    /// Diagnostics: peak used since init.
    high_water: usize = 0,

    const SpillNode = struct {
        /// Underlying slice returned by `parent.alloc`. The caller sees
        /// `data[@sizeOf(SpillNode) + alignment_pad ..]`. We re-create the
        /// full slice on free using the `total_len` field.
        next: ?*SpillNode,
        total_len: usize,
        log2_align: u8,
    };

    pub fn init(parent: Allocator, slab_bytes: usize, cap_bytes: usize) !TieredArena {
        assert(slab_bytes > 0);
        assert(cap_bytes >= slab_bytes);
        const buf = try parent.alloc(u8, slab_bytes);
        return .{
            .parent = parent,
            .backing = buf,
            .fba = std.heap.FixedBufferAllocator.init(buf),
            .cap_bytes = cap_bytes,
        };
    }

    pub fn deinit(self: *TieredArena) void {
        self.freeSpill();
        self.parent.free(self.backing);
        self.* = undefined;
    }

    pub fn allocator(self: *TieredArena) Allocator {
        return .{
            .ptr = self,
            .vtable = &vtable,
        };
    }

    pub fn reset(self: *TieredArena) void {
        if (self.used_bytes > self.high_water) self.high_water = self.used_bytes;
        self.freeSpill();
        self.fba.reset();
        self.used_bytes = 0;
    }

    /// Bytes currently used (slab + spilled).
    pub fn used(self: *const TieredArena) usize {
        return self.used_bytes;
    }

    /// Bytes currently used in the slab itself.
    pub fn slabUsed(self: *const TieredArena) usize {
        return self.fba.end_index;
    }

    /// Bytes currently used in spill. Useful for diagnostics — when this
    /// is nonzero in steady state, the slab is too small for the workload.
    pub fn spillUsed(self: *const TieredArena) usize {
        return self.used_bytes -| self.fba.end_index;
    }

    pub fn slabCapacity(self: *const TieredArena) usize {
        return self.backing.len;
    }

    pub fn capacity(self: *const TieredArena) usize {
        return self.cap_bytes;
    }

    pub fn highWater(self: *const TieredArena) usize {
        return if (self.used_bytes > self.high_water) self.used_bytes else self.high_water;
    }

    /// Returns true if `slice` was allocated from the slab (not from spill).
    /// Used by callers that want to detect "in-arena" memory for sentinel
    /// free paths.
    pub fn slabContains(self: *const TieredArena, slice: []const u8) bool {
        if (slice.len == 0) return false;
        const buf = self.backing;
        const buf_start = @intFromPtr(buf.ptr);
        const slice_start = @intFromPtr(slice.ptr);
        return slice_start >= buf_start and slice_start + slice.len <= buf_start + buf.len;
    }

    fn freeSpill(self: *TieredArena) void {
        var cur = self.spill_head;
        while (cur) |node| {
            const next = node.next;
            // The original allocation includes the SpillNode header at the
            // start, then padding to user alignment. We recover the
            // original ptr+len by reading total_len from the header.
            const node_addr = @intFromPtr(node);
            const raw_ptr: [*]u8 = @ptrFromInt(node_addr);
            const raw_slice = raw_ptr[0..node.total_len];
            const eff_align: std.mem.Alignment = @enumFromInt(node.log2_align);
            self.parent.rawFree(raw_slice, eff_align, @returnAddress());
            cur = next;
        }
        self.spill_head = null;
    }

    const vtable: Allocator.VTable = .{
        .alloc = vtableAlloc,
        .resize = vtableResize,
        .remap = vtableRemap,
        .free = vtableFree,
    };

    fn vtableAlloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *TieredArena = @ptrCast(@alignCast(ctx));
        if (self.used_bytes + len > self.cap_bytes) return null;

        // Try the slab first via the FBA's allocator.
        const fba_alloc = self.fba.allocator();
        if (fba_alloc.vtable.alloc(fba_alloc.ptr, len, alignment, ret_addr)) |p| {
            self.used_bytes += len;
            return p;
        }

        // Spill to parent. Stash a SpillNode header before the user buffer
        // so reset can find the original allocation to free. We size the
        // header rounded up to the user alignment so the user pointer is
        // properly aligned.
        const align_bytes = alignment.toByteUnits();
        const header_size = std.mem.alignForward(usize, @sizeOf(SpillNode), align_bytes);
        const total = header_size + len;
        const node_align = std.mem.Alignment.of(SpillNode);
        const eff_align = if (node_align.toByteUnits() > align_bytes) node_align else alignment;
        const raw_ptr = self.parent.rawAlloc(total, eff_align, ret_addr) orelse return null;
        const node_ptr: *SpillNode = @ptrCast(@alignCast(raw_ptr));
        node_ptr.* = .{
            .next = self.spill_head,
            .total_len = total,
            .log2_align = @intFromEnum(eff_align),
        };
        self.spill_head = node_ptr;
        self.used_bytes += len;
        const user_ptr: [*]u8 = @ptrFromInt(@intFromPtr(raw_ptr) + header_size);
        return user_ptr;
    }

    fn vtableResize(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *TieredArena = @ptrCast(@alignCast(ctx));
        // Slab path: forward to FBA's resize semantics.
        if (self.slabContains(buf)) {
            const fba_alloc = self.fba.allocator();
            const ok = fba_alloc.vtable.resize(fba_alloc.ptr, buf, alignment, new_len, ret_addr);
            if (ok) {
                if (new_len > buf.len) {
                    self.used_bytes += new_len - buf.len;
                } else {
                    self.used_bytes -= buf.len - new_len;
                }
            }
            return ok;
        }
        // Spilled allocations: do not support in-place resize.
        return false;
    }

    fn vtableRemap(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *TieredArena = @ptrCast(@alignCast(ctx));
        if (self.slabContains(buf)) {
            // FBA has no remap — it would just resize. Try resize first.
            if (vtableResize(ctx, buf, alignment, new_len, ret_addr)) return buf.ptr;
            // Slab was unable to grow in place; let the caller fall back to
            // alloc-new + copy + free-old.
            return null;
        }
        // Spilled: do not support remap.
        return null;
    }

    fn vtableFree(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        // Free is a no-op on the bump path; reset() does the real cleanup.
        // For spilled allocations we _could_ unlink from the list, but that
        // costs an O(N) walk and breaks the LIFO assumption used to free
        // bulk-on-reset. The std.ArrayList growth pattern is alloc-new ->
        // copy -> free-old (in that order), so freeing here without
        // reclamation is correct: we keep the old slot allocated until
        // reset, which is acceptable because the cap bounds the worst case.
        _ = ctx;
        _ = buf;
        _ = alignment;
        _ = ret_addr;
    }
};

// ── Tests: RequestArena ──────────────────────────────────────

test "RequestArena alloc/reset cycle returns memory" {
    var arena = try RequestArena.init(std.testing.allocator, 4096);
    defer arena.deinit();

    const a = arena.allocator();
    const buf1 = try a.alloc(u8, 128);
    @memset(buf1, 0xAB);
    try std.testing.expect(arena.used() >= 128);

    const buf2 = try a.alloc(u8, 256);
    @memset(buf2, 0xCD);
    try std.testing.expect(arena.used() >= 128 + 256);

    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.used());
    try std.testing.expect(arena.highWater() >= 128 + 256);
}

test "RequestArena returns OOM at hard cap" {
    var arena = try RequestArena.init(std.testing.allocator, 1024);
    defer arena.deinit();
    const a = arena.allocator();
    _ = try a.alloc(u8, 512);
    _ = try a.alloc(u8, 256);
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 512));
}

// ── Tests: TieredArena ───────────────────────────────────────

test "TieredArena fast-path stays in the slab" {
    var arena = try TieredArena.init(std.testing.allocator, 4096, 1024 * 1024);
    defer arena.deinit();
    const a = arena.allocator();

    const small = try a.alloc(u8, 256);
    try std.testing.expectEqual(@as(usize, 256), arena.used());
    try std.testing.expectEqual(@as(usize, 0), arena.spillUsed());
    try std.testing.expect(arena.slabContains(small));
}

test "TieredArena spills past the slab and frees on reset" {
    var arena = try TieredArena.init(std.testing.allocator, 256, 64 * 1024);
    defer arena.deinit();
    const a = arena.allocator();

    // Slab capacity 256 — first request fits.
    const a1 = try a.alloc(u8, 200);
    @memset(a1, 0xAA);
    try std.testing.expect(arena.slabContains(a1));

    // Second request would exceed the slab → spill to parent.
    const a2 = try a.alloc(u8, 8 * 1024);
    @memset(a2, 0xBB);
    try std.testing.expect(!arena.slabContains(a2));
    try std.testing.expect(arena.spillUsed() >= 8 * 1024);

    arena.reset();
    // After reset: slab is reusable, spill is freed (validated by no leak).
    try std.testing.expectEqual(@as(usize, 0), arena.used());
    try std.testing.expectEqual(@as(usize, 0), arena.spillUsed());

    // Allocate again — slab should be reusable.
    const a3 = try a.alloc(u8, 128);
    try std.testing.expect(arena.slabContains(a3));
}

test "TieredArena enforces hard cap across slab+spill" {
    var arena = try TieredArena.init(std.testing.allocator, 256, 1024);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try a.alloc(u8, 200); // slab
    _ = try a.alloc(u8, 700); // spill — pushes total to 900
    // Next 200 would push total to 1100 > 1024 → OOM
    try std.testing.expectError(error.OutOfMemory, a.alloc(u8, 200));
    try std.testing.expectEqual(@as(usize, 900), arena.used());
}

test "TieredArena ArrayList growth crosses slab boundary cleanly" {
    var arena = try TieredArena.init(std.testing.allocator, 512, 1024 * 1024);
    defer arena.deinit();
    const a = arena.allocator();

    var list: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < 8192) : (i += 1) {
        try list.append(a, @truncate(i));
    }
    // Final ArrayList capacity ≥ 8192 — by now it has spilled past the slab.
    try std.testing.expect(arena.spillUsed() > 0);
    try std.testing.expectEqual(@as(usize, 8192), list.items.len);

    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.spillUsed());
    try std.testing.expectEqual(@as(usize, 0), arena.used());
}

test "TieredArena reset preserves high_water across cycles" {
    var arena = try TieredArena.init(std.testing.allocator, 256, 64 * 1024);
    defer arena.deinit();
    const a = arena.allocator();

    _ = try a.alloc(u8, 8 * 1024);
    arena.reset();
    try std.testing.expect(arena.highWater() >= 8 * 1024);

    _ = try a.alloc(u8, 64);
    arena.reset();
    // Peak from the prior cycle is preserved across resets.
    try std.testing.expect(arena.highWater() >= 8 * 1024);
}

test "TieredArena free is a no-op (resets reclaim)" {
    var arena = try TieredArena.init(std.testing.allocator, 1024, 64 * 1024);
    defer arena.deinit();
    const a = arena.allocator();

    const buf = try a.alloc(u8, 256);
    a.free(buf);
    // free didn't reclaim — bump pointer didn't move.
    try std.testing.expect(arena.used() >= 256);

    arena.reset();
    try std.testing.expectEqual(@as(usize, 0), arena.used());
}
