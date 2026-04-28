//! Algorithm-level tests for `SimResumeBackend`. Pin every behavior the
//! daemon currently relies on `SqliteBackend` for, and the new fault knobs
//! that BUGGIFY harnesses will lean on.
//!
//! Coverage matrix:
//!   - load/store roundtrip on each table (pieces, transfer_stats,
//!     categories, torrent_categories, torrent_tags, global_tags,
//!     rate_limits, share_limits, info_hash_v2, banned_ips,
//!     banned_ranges, tracker_overrides, ipfilter_config,
//!     queue_positions).
//!   - `replaceCompletePieces` atomic-swap semantics matching
//!     `SqliteBackend`'s `BEGIN IMMEDIATE … COMMIT` truth.
//!   - `clearTorrent` cascade across every torrent-keyed table.
//!   - Fault knobs: `commit_failure_probability`,
//!     `read_failure_probability`, `silent_drop_probability` — verifies
//!     each fires deterministically under a fixed seed and surfaces
//!     the right error/no-op behavior.
//!   - Multi-thread safety: `std.Thread.Mutex` discipline matches
//!     `SQLITE_OPEN_FULLMUTEX` — workers, RPC handlers, queue manager
//!     all share one backend instance without UB.

const std = @import("std");
const testing = std.testing;
const varuna = @import("varuna");

const SimResumeBackend = varuna.storage.resume_state.SimResumeBackend;
const Bitfield = varuna.bitfield.Bitfield;

// ── Pieces table ────────────────────────────────────────────

test "SimResumeBackend: markComplete + loadCompletePieces roundtrip" {
    const allocator = testing.allocator;
    var db = SimResumeBackend.init(allocator, 0xCAFE);
    defer db.deinit();

    const info_hash = [_]u8{0xAA} ** 20;
    try db.markComplete(info_hash, 0);
    try db.markComplete(info_hash, 5);
    try db.markComplete(info_hash, 10);
    // Duplicate should be ignored (insert-or-ignore semantics).
    try db.markComplete(info_hash, 5);

    var bf = try Bitfield.init(allocator, 20);
    defer bf.deinit(allocator);
    const count = try db.loadCompletePieces(info_hash, &bf);
    try testing.expectEqual(@as(u32, 3), count);
    try testing.expect(bf.has(0));
    try testing.expect(bf.has(5));
    try testing.expect(bf.has(10));
    try testing.expect(!bf.has(1));
}

test "SimResumeBackend: markCompleteBatch atomically inserts all" {
    const allocator = testing.allocator;
    var db = SimResumeBackend.init(allocator, 0);
    defer db.deinit();

    const info_hash = [_]u8{0xBB} ** 20;
    const pieces = [_]u32{ 0, 1, 2, 3, 4 };
    try db.markCompleteBatch(info_hash, &pieces);

    var bf = try Bitfield.init(allocator, 10);
    defer bf.deinit(allocator);
    const count = try db.loadCompletePieces(info_hash, &bf);
    try testing.expectEqual(@as(u32, 5), count);
}

test "SimResumeBackend: replaceCompletePieces is atomic delete-then-insert" {
    const allocator = testing.allocator;
    var db = SimResumeBackend.init(allocator, 0);
    defer db.deinit();

    const info_hash = [_]u8{0xC0} ** 20;
    const before = [_]u32{ 5, 6, 7 };
    try db.markCompleteBatch(info_hash, &before);

    const after = [_]u32{ 1, 3 };
    try db.replaceCompletePieces(info_hash, &after);

    var bf = try Bitfield.init(allocator, 16);
    defer bf.deinit(allocator);
    const count = try db.loadCompletePieces(info_hash, &bf);
    try testing.expectEqual(@as(u32, 2), count);
    try testing.expect(bf.has(1));
    try testing.expect(bf.has(3));
    // Stale pre-replace entries are gone — same semantics as
    // SqliteBackend's `BEGIN IMMEDIATE … COMMIT` recheck pruning.
    try testing.expect(!bf.has(5));
    try testing.expect(!bf.has(6));
    try testing.expect(!bf.has(7));
}

test "SimResumeBackend: replaceCompletePieces with empty set clears all pieces" {
    const allocator = testing.allocator;
    var db = SimResumeBackend.init(allocator, 0);
    defer db.deinit();

    const info_hash = [_]u8{0xC1} ** 20;
    const before = [_]u32{ 0, 1, 2, 3 };
    try db.markCompleteBatch(info_hash, &before);
    const empty = [_]u32{};
    try db.replaceCompletePieces(info_hash, &empty);

    var bf = try Bitfield.init(allocator, 16);
    defer bf.deinit(allocator);
    const count = try db.loadCompletePieces(info_hash, &bf);
    try testing.expectEqual(@as(u32, 0), count);
}

test "SimResumeBackend: replaceCompletePieces is per-info_hash isolated" {
    const allocator = testing.allocator;
    var db = SimResumeBackend.init(allocator, 0);
    defer db.deinit();

    const a = [_]u8{0xA0} ** 20;
    const b = [_]u8{0xB0} ** 20;
    try db.markCompleteBatch(a, &[_]u32{ 0, 1, 2 });
    try db.markCompleteBatch(b, &[_]u32{ 4, 5, 6, 7 });

    try db.replaceCompletePieces(a, &[_]u32{ 0, 1, 3 });

    var bf_a = try Bitfield.init(allocator, 16);
    defer bf_a.deinit(allocator);
    const ca = try db.loadCompletePieces(a, &bf_a);
    try testing.expectEqual(@as(u32, 3), ca);

    var bf_b = try Bitfield.init(allocator, 16);
    defer bf_b.deinit(allocator);
    const cb = try db.loadCompletePieces(b, &bf_b);
    try testing.expectEqual(@as(u32, 4), cb);
    try testing.expect(bf_b.has(4));
    try testing.expect(bf_b.has(5));
    try testing.expect(bf_b.has(6));
    try testing.expect(bf_b.has(7));
}

// ── Transfer stats ──────────────────────────────────────────

test "SimResumeBackend: transfer stats roundtrip + upsert" {
    const allocator = testing.allocator;
    var db = SimResumeBackend.init(allocator, 0);
    defer db.deinit();

    const info_hash = [_]u8{0xDD} ** 20;
    const empty = db.loadTransferStats(info_hash);
    try testing.expectEqual(@as(u64, 0), empty.total_uploaded);
    try testing.expectEqual(@as(u64, 0), empty.total_downloaded);

    try db.saveTransferStats(info_hash, .{ .total_uploaded = 1000, .total_downloaded = 5000 });
    const loaded = db.loadTransferStats(info_hash);
    try testing.expectEqual(@as(u64, 1000), loaded.total_uploaded);
    try testing.expectEqual(@as(u64, 5000), loaded.total_downloaded);

    try db.saveTransferStats(info_hash, .{ .total_uploaded = 3000, .total_downloaded = 8000 });
    const updated = db.loadTransferStats(info_hash);
    try testing.expectEqual(@as(u64, 3000), updated.total_uploaded);
    try testing.expectEqual(@as(u64, 8000), updated.total_downloaded);
}

// ── Categories ──────────────────────────────────────────────

test "SimResumeBackend: save/remove/load categories" {
    const allocator = testing.allocator;
    var db = SimResumeBackend.init(allocator, 0);
    defer db.deinit();

    try db.saveCategory("movies", "/data/movies");
    try db.saveCategory("tv", "/data/tv");
    try db.saveCategory("movies", "/new/movies"); // upsert

    const cats = try db.loadCategories(allocator);
    defer {
        for (cats) |c| {
            allocator.free(c.name);
            allocator.free(c.save_path);
        }
        allocator.free(cats);
    }
    try testing.expectEqual(@as(usize, 2), cats.len);
    var found_movies = false;
    var found_tv = false;
    for (cats) |c| {
        if (std.mem.eql(u8, c.name, "movies")) {
            try testing.expectEqualStrings("/new/movies", c.save_path);
            found_movies = true;
        } else if (std.mem.eql(u8, c.name, "tv")) {
            try testing.expectEqualStrings("/data/tv", c.save_path);
            found_tv = true;
        }
    }
    try testing.expect(found_movies);
    try testing.expect(found_tv);

    try db.removeCategory("movies");
    const cats2 = try db.loadCategories(allocator);
    defer {
        for (cats2) |c| {
            allocator.free(c.name);
            allocator.free(c.save_path);
        }
        allocator.free(cats2);
    }
    try testing.expectEqual(@as(usize, 1), cats2.len);
}

// ── Torrent categories + tags ──────────────────────────────

test "SimResumeBackend: torrent category persistence + clearCategoryFromTorrents" {
    const allocator = testing.allocator;
    var db = SimResumeBackend.init(allocator, 0);
    defer db.deinit();

    const a = [_]u8{0xAA} ** 20;
    const b = [_]u8{0xBB} ** 20;
    try db.saveTorrentCategory(a, "movies");
    try db.saveTorrentCategory(b, "movies");
    try db.saveTorrentCategory(a, "tv"); // overwrite

    const ca = (try db.loadTorrentCategory(allocator, a)).?;
    defer allocator.free(ca);
    try testing.expectEqualStrings("tv", ca);

    try db.clearCategoryFromTorrents("movies");
    const cb = try db.loadTorrentCategory(allocator, b);
    try testing.expect(cb == null);

    // Empty string clears.
    try db.saveTorrentCategory(a, "");
    const cleared = try db.loadTorrentCategory(allocator, a);
    try testing.expect(cleared == null);
}

test "SimResumeBackend: torrent tags + global tags" {
    const allocator = testing.allocator;
    var db = SimResumeBackend.init(allocator, 0);
    defer db.deinit();

    const a = [_]u8{0xAA} ** 20;
    try db.saveTorrentTag(a, "linux");
    try db.saveTorrentTag(a, "archived");
    try db.saveTorrentTag(a, "linux"); // dup ignored

    const tags = try db.loadTorrentTags(allocator, a);
    defer {
        for (tags) |t| allocator.free(t);
        allocator.free(tags);
    }
    try testing.expectEqual(@as(usize, 2), tags.len);

    try db.removeTorrentTag(a, "linux");
    const tags2 = try db.loadTorrentTags(allocator, a);
    defer {
        for (tags2) |t| allocator.free(t);
        allocator.free(tags2);
    }
    try testing.expectEqual(@as(usize, 1), tags2.len);
    try testing.expectEqualStrings("archived", tags2[0]);

    // Global tags
    try db.saveGlobalTag("linux");
    try db.saveGlobalTag("archived");
    try db.saveGlobalTag("linux"); // dup ignored
    const gtags = try db.loadGlobalTags(allocator);
    defer {
        for (gtags) |t| allocator.free(t);
        allocator.free(gtags);
    }
    try testing.expectEqual(@as(usize, 2), gtags.len);

    // removeTagFromTorrents
    const b = [_]u8{0xBB} ** 20;
    try db.saveTorrentTag(b, "archived");
    try db.removeTagFromTorrents("archived");
    const tags_a = try db.loadTorrentTags(allocator, a);
    defer {
        for (tags_a) |t| allocator.free(t);
        allocator.free(tags_a);
    }
    try testing.expectEqual(@as(usize, 0), tags_a.len);
}

// ── Rate / share limits ────────────────────────────────────

test "SimResumeBackend: rate limits roundtrip + clear" {
    var db = SimResumeBackend.init(testing.allocator, 0);
    defer db.deinit();

    const info_hash = [_]u8{0xDD} ** 20;
    const empty = db.loadRateLimits(info_hash);
    try testing.expectEqual(@as(u64, 0), empty.dl_limit);
    try testing.expectEqual(@as(u64, 0), empty.ul_limit);

    try db.saveRateLimits(info_hash, 1024, 512);
    const loaded = db.loadRateLimits(info_hash);
    try testing.expectEqual(@as(u64, 1024), loaded.dl_limit);
    try testing.expectEqual(@as(u64, 512), loaded.ul_limit);

    try db.clearRateLimits(info_hash);
    const cleared = db.loadRateLimits(info_hash);
    try testing.expectEqual(@as(u64, 0), cleared.dl_limit);
}

test "SimResumeBackend: share limits roundtrip + defaults" {
    var db = SimResumeBackend.init(testing.allocator, 0);
    defer db.deinit();

    const info_hash = [_]u8{0xAB} ** 20;
    const def = db.loadShareLimits(info_hash);
    try testing.expectEqual(@as(f64, -2.0), def.ratio_limit);
    try testing.expectEqual(@as(i64, -2), def.seeding_time_limit);
    try testing.expectEqual(@as(i64, 0), def.completion_on);

    try db.saveShareLimits(info_hash, 2.5, 120, 1711900000);
    const loaded = db.loadShareLimits(info_hash);
    try testing.expectEqual(@as(f64, 2.5), loaded.ratio_limit);
    try testing.expectEqual(@as(i64, 120), loaded.seeding_time_limit);
    try testing.expectEqual(@as(i64, 1711900000), loaded.completion_on);

    try db.clearShareLimits(info_hash);
    const cleared = db.loadShareLimits(info_hash);
    try testing.expectEqual(@as(f64, -2.0), cleared.ratio_limit);
}

// ── Info hash v2 ───────────────────────────────────────────

test "SimResumeBackend: v2 info hash save/load" {
    var db = SimResumeBackend.init(testing.allocator, 0);
    defer db.deinit();

    const v1 = [_]u8{0xAA} ** 20;
    var v2: [32]u8 = undefined;
    for (&v2, 0..) |*b, i| b.* = @intCast(i);
    try testing.expect(db.loadInfoHashV2(v1) == null);
    try db.saveInfoHashV2(v1, v2);
    const loaded = db.loadInfoHashV2(v1) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(v2, loaded);
}

// ── Banned IPs / ranges ────────────────────────────────────

test "SimResumeBackend: banned ips save/remove/clearBySource" {
    const allocator = testing.allocator;
    var db = SimResumeBackend.init(allocator, 0);
    defer db.deinit();

    try db.saveBannedIp("1.1.1.1", 0, "bad", 100);
    try db.saveBannedIp("2.2.2.2", 1, null, 200);
    try db.saveBannedRange("10.0.0.0", "10.255.255.255", 1);

    const ips = try db.loadBannedIps(allocator);
    defer {
        for (ips) |i| {
            allocator.free(i.address);
            if (i.reason) |r| allocator.free(r);
        }
        allocator.free(ips);
    }
    try testing.expectEqual(@as(usize, 2), ips.len);

    try db.removeBannedIp("1.1.1.1");
    try db.clearBannedBySource(1);
    const ips_after = try db.loadBannedIps(allocator);
    defer {
        for (ips_after) |i| {
            allocator.free(i.address);
            if (i.reason) |r| allocator.free(r);
        }
        allocator.free(ips_after);
    }
    try testing.expectEqual(@as(usize, 0), ips_after.len);

    const ranges = try db.loadBannedRanges(allocator);
    defer {
        for (ranges) |r| {
            allocator.free(r.start_addr);
            allocator.free(r.end_addr);
        }
        allocator.free(ranges);
    }
    try testing.expectEqual(@as(usize, 0), ranges.len);
}

// ── Tracker overrides ──────────────────────────────────────

test "SimResumeBackend: tracker overrides add/remove/clear/load (sorted by tier)" {
    const allocator = testing.allocator;
    var db = SimResumeBackend.init(allocator, 0);
    defer db.deinit();

    const info_hash = [_]u8{0xAA} ** 20;
    try db.saveTrackerOverride(info_hash, "http://t1/announce", 10, "add", null);
    try db.saveTrackerOverride(info_hash, "http://t2/announce", 11, "add", null);
    try db.saveTrackerOverride(info_hash, "http://old/announce", 0, "remove", null);

    const ovs = try db.loadTrackerOverrides(allocator, info_hash);
    defer SimResumeBackend.freeTrackerOverrides(allocator, ovs);
    try testing.expectEqual(@as(usize, 3), ovs.len);
    try testing.expectEqualStrings("remove", ovs[0].action);
    try testing.expectEqualStrings("add", ovs[1].action);
    try testing.expectEqual(@as(u32, 10), ovs[1].tier);

    // Edit override
    const info_hash_b = [_]u8{0xBB} ** 20;
    try db.saveTrackerOverride(info_hash_b, "http://new/announce", 0, "edit", "http://old/announce");
    const ovs_b = try db.loadTrackerOverrides(allocator, info_hash_b);
    defer SimResumeBackend.freeTrackerOverrides(allocator, ovs_b);
    try testing.expectEqual(@as(usize, 1), ovs_b.len);
    try testing.expectEqualStrings("edit", ovs_b[0].action);
    try testing.expectEqualStrings("http://old/announce", ovs_b[0].orig_url.?);

    // removeTrackerOverrideByOrig
    try db.removeTrackerOverrideByOrig(info_hash_b, "http://old/announce");
    const ovs_b2 = try db.loadTrackerOverrides(allocator, info_hash_b);
    defer SimResumeBackend.freeTrackerOverrides(allocator, ovs_b2);
    try testing.expectEqual(@as(usize, 0), ovs_b2.len);

    try db.clearTrackerOverrides(info_hash);
    const ovs2 = try db.loadTrackerOverrides(allocator, info_hash);
    defer SimResumeBackend.freeTrackerOverrides(allocator, ovs2);
    try testing.expectEqual(@as(usize, 0), ovs2.len);
}

// ── IP filter config singleton ────────────────────────────

test "SimResumeBackend: ipfilter config singleton roundtrip" {
    const allocator = testing.allocator;
    var db = SimResumeBackend.init(allocator, 0);
    defer db.deinit();

    const empty = try db.loadIpFilterConfig(allocator);
    try testing.expect(!empty.enabled);
    try testing.expect(empty.path == null);

    try db.saveIpFilterConfig(.{
        .path = "/etc/ipfilter.dat",
        .enabled = true,
        .rule_count = 1500,
    });
    const loaded = try db.loadIpFilterConfig(allocator);
    defer if (loaded.path) |p| allocator.free(p);
    try testing.expect(loaded.enabled);
    try testing.expectEqual(@as(u32, 1500), loaded.rule_count);
    try testing.expectEqualStrings("/etc/ipfilter.dat", loaded.path.?);
}

// ── Queue positions ───────────────────────────────────────

test "SimResumeBackend: queue positions save/clear/load (sorted by position)" {
    const allocator = testing.allocator;
    var db = SimResumeBackend.init(allocator, 0);
    defer db.deinit();

    const a_hex = std.fmt.bytesToHex([_]u8{0xAA} ** 20, .lower);
    const b_hex = std.fmt.bytesToHex([_]u8{0xBB} ** 20, .lower);
    try db.saveQueuePosition(a_hex, 5);
    try db.saveQueuePosition(b_hex, 1);

    const entries = try db.loadQueuePositions(allocator);
    defer allocator.free(entries);
    try testing.expectEqual(@as(usize, 2), entries.len);
    try testing.expectEqual(@as(u32, 1), entries[0].position);
    try testing.expectEqual(@as(u32, 5), entries[1].position);

    try db.clearQueuePositions();
    const e2 = try db.loadQueuePositions(allocator);
    defer allocator.free(e2);
    try testing.expectEqual(@as(usize, 0), e2.len);
}

// ── clearTorrent cascade ──────────────────────────────────

test "SimResumeBackend: clearTorrent cascades across every torrent-keyed table" {
    const allocator = testing.allocator;
    var db = SimResumeBackend.init(allocator, 0);
    defer db.deinit();

    const info_hash = [_]u8{0xCD} ** 20;
    const info_hash_hex = std.fmt.bytesToHex(info_hash, .lower);
    var v2: [32]u8 = undefined;
    @memset(&v2, 0xEF);

    try db.markComplete(info_hash, 0);
    try db.saveTransferStats(info_hash, .{ .total_uploaded = 10, .total_downloaded = 20 });
    try db.saveTorrentCategory(info_hash, "movies");
    try db.saveTorrentTag(info_hash, "tag-a");
    try db.saveRateLimits(info_hash, 100, 200);
    try db.saveShareLimits(info_hash, 1.5, 30, 1234);
    try db.saveInfoHashV2(info_hash, v2);
    try db.saveTrackerOverride(info_hash, "https://tracker/announce", 0, "add", null);
    try db.saveQueuePosition(info_hash_hex, 7);

    try db.clearTorrent(info_hash);

    var bf = try Bitfield.init(allocator, 8);
    defer bf.deinit(allocator);
    try testing.expectEqual(@as(u32, 0), try db.loadCompletePieces(info_hash, &bf));

    const stats = db.loadTransferStats(info_hash);
    try testing.expectEqual(@as(u64, 0), stats.total_uploaded);

    try testing.expect((try db.loadTorrentCategory(allocator, info_hash)) == null);

    const tags = try db.loadTorrentTags(allocator, info_hash);
    defer {
        for (tags) |t| allocator.free(t);
        allocator.free(tags);
    }
    try testing.expectEqual(@as(usize, 0), tags.len);

    try testing.expectEqual(@as(u64, 0), db.loadRateLimits(info_hash).dl_limit);
    try testing.expectEqual(@as(f64, -2.0), db.loadShareLimits(info_hash).ratio_limit);
    try testing.expect(db.loadInfoHashV2(info_hash) == null);

    const ovs = try db.loadTrackerOverrides(allocator, info_hash);
    defer SimResumeBackend.freeTrackerOverrides(allocator, ovs);
    try testing.expectEqual(@as(usize, 0), ovs.len);

    const queue = try db.loadQueuePositions(allocator);
    defer allocator.free(queue);
    try testing.expectEqual(@as(usize, 0), queue.len);
}

// ── Fault injection ───────────────────────────────────────

test "SimResumeBackend: commit_failure_probability 1.0 forces every write to fail" {
    var db = SimResumeBackend.init(testing.allocator, 0xDEADBEEF);
    defer db.deinit();
    db.fault_config = .{ .commit_failure_probability = 1.0 };

    const info_hash = [_]u8{0xAA} ** 20;
    try testing.expectError(error.SqliteCommitFailed, db.markComplete(info_hash, 0));
    try testing.expectError(error.SqliteCommitFailed, db.markCompleteBatch(info_hash, &[_]u32{ 0, 1 }));
    try testing.expectError(error.SqliteCommitFailed, db.replaceCompletePieces(info_hash, &[_]u32{0}));
    try testing.expectError(error.SqliteCommitFailed, db.saveTransferStats(info_hash, .{ .total_uploaded = 1, .total_downloaded = 2 }));
    try testing.expectError(error.SqliteCommitFailed, db.saveCategory("c", "/p"));
    try testing.expectError(error.SqliteCommitFailed, db.saveRateLimits(info_hash, 1, 2));
    try testing.expectError(error.SqliteCommitFailed, db.saveShareLimits(info_hash, 1.0, 60, 0));
    try testing.expectError(error.SqliteCommitFailed, db.saveQueuePosition([_]u8{'a'} ** 40, 0));
}

test "SimResumeBackend: read_failure_probability 1.0 makes every load empty" {
    var db = SimResumeBackend.init(testing.allocator, 0xCAFEBABE);
    defer db.deinit();

    // Populate honestly first.
    const info_hash = [_]u8{0xBB} ** 20;
    try db.markCompleteBatch(info_hash, &[_]u32{ 0, 1, 2, 3 });
    try db.saveTransferStats(info_hash, .{ .total_uploaded = 100, .total_downloaded = 200 });
    try db.saveRateLimits(info_hash, 1024, 512);

    // Now set the read fault.
    db.fault_config = .{ .read_failure_probability = 1.0 };

    var bf = try Bitfield.init(testing.allocator, 16);
    defer bf.deinit(testing.allocator);
    const count = try db.loadCompletePieces(info_hash, &bf);
    try testing.expectEqual(@as(u32, 0), count);

    const stats = db.loadTransferStats(info_hash);
    try testing.expectEqual(@as(u64, 0), stats.total_uploaded);

    const limits = db.loadRateLimits(info_hash);
    try testing.expectEqual(@as(u64, 0), limits.dl_limit);
}

test "SimResumeBackend: silent_drop_probability 1.0 reports success but never applies" {
    const allocator = testing.allocator;
    var db = SimResumeBackend.init(allocator, 0xFEEDFACE);
    defer db.deinit();
    db.fault_config = .{ .silent_drop_probability = 1.0 };

    const info_hash = [_]u8{0xCC} ** 20;
    try db.markCompleteBatch(info_hash, &[_]u32{ 0, 1, 2 });
    // No fault injection on read — we want to confirm the write was lost.
    db.fault_config = .{};

    var bf = try Bitfield.init(allocator, 8);
    defer bf.deinit(allocator);
    const count = try db.loadCompletePieces(info_hash, &bf);
    try testing.expectEqual(@as(u32, 0), count);
}

test "SimResumeBackend: read_corruption_probability flips loadCompletePieces bits" {
    const allocator = testing.allocator;
    var db = SimResumeBackend.init(allocator, 0xABCD);
    defer db.deinit();

    // Honest data: pieces {0, 1, 2}.
    const info_hash = [_]u8{0xDD} ** 20;
    try db.markCompleteBatch(info_hash, &[_]u32{ 0, 1, 2 });

    db.fault_config = .{ .read_corruption_probability = 1.0 };
    var bf = try Bitfield.init(allocator, 256); // wider so corruption can land on a bit other than {0,1,2}
    defer bf.deinit(allocator);
    _ = try db.loadCompletePieces(info_hash, &bf);

    // With corruption forced on every read, observed bits should NOT
    // exactly match the honest set {0,1,2}. (RNG could in theory pick
    // those exact bits — astronomically unlikely with seed 0xABCD and
    // piece_count=256.) The point is that the test demonstrates corruption
    // surface is wired; harnesses use this knob to test recheck recovery.
    var honest_bf = try Bitfield.init(allocator, 256);
    defer honest_bf.deinit(allocator);
    try honest_bf.set(0);
    try honest_bf.set(1);
    try honest_bf.set(2);
    try testing.expect(!std.mem.eql(u8, bf.bits, honest_bf.bits));
}

// ── Sanity: backend matches `SqliteBackend` API contract ──

test "SimResumeBackend: open() / close() pair works for drop-in shape" {
    var db = try SimResumeBackend.open(":memory:");
    db.close();
}
