const std = @import("std");
const posix = std.posix;
const varuna = @import("varuna");
const Bitfield = varuna.bitfield.Bitfield;
const PieceTracker = varuna.torrent.piece_tracker.PieceTracker;

// ── Long-running soak test framework ─────────────────────────
//
// This test harness runs a simulated multi-torrent daemon workload for
// an extended period and monitors for resource leaks.  It tracks:
//
//   - Allocator stats (bytes allocated, freed, current live)
//   - File descriptor count
//   - Event loop responsiveness (tick latency)
//
// Run via: zig build soak-test
//
// The soak test does NOT require network access or an actual tracker.
// It exercises the in-process allocator, bitfield, and piece tracker
// subsystems under sustained load to catch slow leaks.

const soak_duration_secs: u64 = 10; // Default 10 seconds
const tick_interval_ms: u64 = 10; // Simulate 100 ticks/sec
const num_torrents: usize = 8;
const pieces_per_torrent: u32 = 1000;
const piece_length: u32 = 256 * 1024; // 256 KB

/// Resource snapshot at a point in time.
const ResourceSnapshot = struct {
    timestamp_ms: i64,
    allocator_bytes_used: usize,
    fd_count: usize,
    tick_latency_us: i64,
};

/// Count open file descriptors for the current process.
fn countOpenFds() usize {
    var dir = std.fs.openDirAbsolute("/proc/self/fd", .{ .iterate = true }) catch return 0;
    defer dir.close();

    var count: usize = 0;
    var iter = dir.iterate();
    while (iter.next() catch null) |_| {
        count += 1;
    }
    return count;
}

/// Run a single soak iteration: allocate, manipulate, and free resources
/// for multiple simulated torrents.  Returns the peak bytes allocated
/// during the iteration.
fn soakIteration(
    allocator: std.mem.Allocator,
    iteration: usize,
) !void {
    // Simulate multi-torrent workload: create piece trackers, bitfields,
    // claim pieces, complete them, and tear down.
    var trackers: [num_torrents]PieceTracker = undefined;
    var bitfields: [num_torrents]Bitfield = undefined;

    // Setup phase
    for (0..num_torrents) |i| {
        bitfields[i] = try Bitfield.init(allocator, pieces_per_torrent);
        trackers[i] = try PieceTracker.init(
            allocator,
            pieces_per_torrent,
            piece_length,
            piece_length,
            &bitfields[i],
            0,
        );
    }
    defer {
        for (0..num_torrents) |i| {
            trackers[i].deinit(allocator);
            bitfields[i].deinit(allocator);
        }
    }

    // Work phase: claim and complete pieces, simulating download progress
    const pieces_to_process = @min(50, pieces_per_torrent);
    for (0..pieces_to_process) |_| {
        for (0..num_torrents) |i| {
            if (trackers[i].claimPiece(null)) |piece_idx| {
                _ = trackers[i].completePiece(piece_idx, piece_length);
            }
        }
    }

    // Verify no piece tracker corruption
    for (0..num_torrents) |i| {
        const completed = trackers[i].completedCount();
        if (completed > pieces_per_torrent) {
            std.debug.print("SOAK FAIL: torrent {d} iteration {d}: completed {d} > total {d}\n", .{
                i, iteration, completed, pieces_per_torrent,
            });
            return error.PieceTrackerCorruption;
        }
    }
}

/// Run the allocator stress test: repeated alloc/free cycles with
/// varying sizes to detect fragmentation-induced leaks.
fn allocatorStressTest(allocator: std.mem.Allocator) !void {
    const sizes = [_]usize{ 16, 64, 256, 1024, 4096, 16384, 65536, 262144 };
    var bufs: [sizes.len][]u8 = undefined;

    for (0..100) |_| {
        // Allocate
        for (sizes, 0..) |size, i| {
            bufs[i] = try allocator.alloc(u8, size);
        }
        // Free in reverse order
        var i: usize = sizes.len;
        while (i > 0) {
            i -= 1;
            allocator.free(bufs[i]);
        }
    }

    // Interleaved alloc/free (catches use-after-free patterns)
    for (0..100) |_| {
        for (sizes, 0..) |size, i| {
            bufs[i] = try allocator.alloc(u8, size);
        }
        // Free even indices
        for (0..sizes.len) |i| {
            if (i % 2 == 0) {
                allocator.free(bufs[i]);
                bufs[i] = &.{};
            }
        }
        // Reallocate even indices
        for (sizes, 0..) |size, i| {
            if (i % 2 == 0) {
                bufs[i] = try allocator.alloc(u8, size);
            }
        }
        // Free all
        for (sizes, 0..) |_, i| {
            allocator.free(bufs[i]);
        }
    }
}

/// Run the bitfield stress test: repeated init/set/import/deinit cycles.
fn bitfieldStressTest(allocator: std.mem.Allocator) !void {
    for (0..200) |cycle| {
        const piece_count: u32 = @intCast((cycle % 10 + 1) * 100);
        var bf = try Bitfield.init(allocator, piece_count);
        defer bf.deinit(allocator);

        // Set random pieces
        var i: u32 = 0;
        while (i < piece_count) : (i += 7) {
            try bf.set(i);
        }

        // Import a full bitfield
        const full = try allocator.alloc(u8, Bitfield.byteCount(piece_count));
        defer allocator.free(full);
        @memset(full, 0xFF);
        bf.importBitfield(full);

        // Verify count is correct
        if (bf.count > piece_count) {
            return error.BitfieldCountOverflow;
        }
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{
        .enable_memory_limit = true,
    }){};
    defer {
        const status = gpa.deinit();
        if (status == .leak) {
            std.debug.print("SOAK FAIL: GeneralPurposeAllocator detected memory leak!\n", .{});
            std.process.exit(1);
        }
    }
    const allocator = gpa.allocator();

    const start_fd_count = countOpenFds();
    const start_time = std.time.milliTimestamp();
    const duration_ms: i64 = @intCast(soak_duration_secs * 1000);

    var snapshots = std.ArrayList(ResourceSnapshot).empty;
    defer snapshots.deinit(allocator);

    std.debug.print("=== Varuna Soak Test ===\n", .{});
    std.debug.print("Duration: {d}s | Torrents: {d} | Pieces/torrent: {d}\n", .{
        soak_duration_secs, num_torrents, pieces_per_torrent,
    });
    std.debug.print("Initial FDs: {d}\n\n", .{start_fd_count});

    var iteration: usize = 0;
    var max_latency_us: i64 = 0;

    while (std.time.milliTimestamp() - start_time < duration_ms) {
        const tick_start = std.time.microTimestamp();

        // Run soak iteration
        try soakIteration(allocator, iteration);

        // Run sub-tests periodically
        if (iteration % 10 == 0) {
            try allocatorStressTest(allocator);
        }
        if (iteration % 20 == 0) {
            try bitfieldStressTest(allocator);
        }

        const tick_end = std.time.microTimestamp();
        const latency = tick_end - tick_start;
        if (latency > max_latency_us) max_latency_us = latency;

        // Take snapshot every second
        if (iteration % 100 == 0) {
            const fd_count = countOpenFds();
            try snapshots.append(allocator, .{
                .timestamp_ms = std.time.milliTimestamp() - start_time,
                .allocator_bytes_used = gpa.total_requested_bytes,
                .fd_count = fd_count,
                .tick_latency_us = latency,
            });
        }

        iteration += 1;

        // Brief yield to keep this from being a pure CPU burn
        std.Thread.sleep(tick_interval_ms * std.time.ns_per_ms);
    }

    const end_fd_count = countOpenFds();
    const elapsed_ms = std.time.milliTimestamp() - start_time;

    // ── Report ──────────────────────────────────────────────
    std.debug.print("\n=== Soak Test Results ===\n", .{});
    std.debug.print("Elapsed: {d}ms | Iterations: {d}\n", .{ elapsed_ms, iteration });
    std.debug.print("Max tick latency: {d}us\n", .{max_latency_us});
    std.debug.print("FD count: start={d} end={d} delta={d}\n", .{
        start_fd_count,
        end_fd_count,
        @as(i64, @intCast(end_fd_count)) - @as(i64, @intCast(start_fd_count)),
    });

    // Analyze snapshots for trends
    if (snapshots.items.len >= 2) {
        const first = snapshots.items[0];
        const last = snapshots.items[snapshots.items.len - 1];

        std.debug.print("\nAllocator bytes: first={d} last={d}\n", .{
            first.allocator_bytes_used,
            last.allocator_bytes_used,
        });

        // Check for FD leaks
        if (end_fd_count > start_fd_count + 5) {
            std.debug.print("WARNING: FD count increased by {d} (possible leak)\n", .{
                end_fd_count - start_fd_count,
            });
        }
    }

    // ── Assertions ──────────────────────────────────────────
    // FD leak check: allow a small delta for transient state
    if (end_fd_count > start_fd_count + 10) {
        std.debug.print("FAIL: FD leak detected ({d} -> {d})\n", .{ start_fd_count, end_fd_count });
        std.process.exit(1);
    }

    // Tick responsiveness: no single tick should take > 500ms (debug mode is slow)
    if (max_latency_us > 500_000) {
        std.debug.print("FAIL: tick latency exceeded 500ms (max={d}us)\n", .{max_latency_us});
        std.process.exit(1);
    }

    // ── Phase 4: Socket create/close cycle ────────────────
    // Verify that rapidly creating and closing sockets does not leak fds.
    {
        std.debug.print("\n--- Socket create/close cycle ---\n", .{});
        const before_fds = countOpenFds();
        for (0..100) |_| {
            const fd = posix.socket(posix.AF.INET, posix.SOCK.STREAM | posix.SOCK.CLOEXEC | posix.SOCK.NONBLOCK, posix.IPPROTO.TCP) catch continue;
            posix.close(fd);
        }
        const after_fds = countOpenFds();
        if (after_fds > before_fds + 2) {
            std.debug.print("FAIL: socket cycle leaked {d} fds\n", .{after_fds - before_fds});
            std.process.exit(1);
        }
        std.debug.print("  socket cycle: {d} fds before, {d} after (OK)\n", .{ before_fds, after_fds });
    }

    // ── Phase 5: PieceTracker add/remove cycle ──────────────
    // Rapidly create and destroy PieceTrackers to catch allocation leaks.
    {
        std.debug.print("\n--- PieceTracker create/destroy cycle ---\n", .{});
        const before_fds = countOpenFds();
        for (0..50) |_| {
            var initial_bf = try Bitfield.init(allocator, 100);
            defer initial_bf.deinit(allocator);
            var pt = try PieceTracker.init(allocator, 100, 256 * 1024, 100 * 256 * 1024, &initial_bf, 0);
            pt.deinit(allocator);
        }
        const after_fds = countOpenFds();
        if (after_fds > before_fds + 2) {
            std.debug.print("FAIL: tracker cycle leaked {d} fds\n", .{after_fds - before_fds});
            std.process.exit(1);
        }
        std.debug.print("  tracker cycle: {d} create/destroy, no fd leak (OK)\n", .{@as(u32, 50)});
    }

    std.debug.print("\nSOAK TEST PASSED\n", .{});
}
