const std = @import("std");
const addr_mod = @import("../net/address.zig");

pub const max_candidates_per_torrent: usize = 512;
const retry_base_secs: i64 = 30;
const retry_max_secs: i64 = 5 * 60;

pub const PeerCandidateSource = enum(u8) {
    tracker,
    dht,
    pex,
    manual,
};

pub const PeerCandidate = struct {
    address: std.net.Address,
    swarm_hash: [20]u8,
    source: PeerCandidateSource,
    first_seen: i64,
    last_seen: i64,
    last_attempt_at: i64 = 0,
    next_retry_at: i64 = 0,
    attempts: u8 = 0,
};

pub const PeerCandidateList = struct {
    entries: std.ArrayList(PeerCandidate) = .empty,

    pub fn deinit(self: *PeerCandidateList, allocator: std.mem.Allocator) void {
        self.entries.deinit(allocator);
    }

    pub fn count(self: *const PeerCandidateList) usize {
        return self.entries.items.len;
    }

    pub fn add(
        self: *PeerCandidateList,
        allocator: std.mem.Allocator,
        address: std.net.Address,
        swarm_hash: [20]u8,
        source: PeerCandidateSource,
        now: i64,
    ) !bool {
        if (self.find(address, swarm_hash)) |idx| {
            var entry = &self.entries.items[idx];
            entry.last_seen = now;
            entry.source = mergeSource(entry.source, source);
            return false;
        }

        if (self.entries.items.len >= max_candidates_per_torrent) {
            _ = self.entries.swapRemove(self.evictIndex());
        }

        try self.entries.append(allocator, .{
            .address = address,
            .swarm_hash = swarm_hash,
            .source = source,
            .first_seen = now,
            .last_seen = now,
        });
        return true;
    }

    pub fn markAttempt(self: *PeerCandidateList, idx: usize, now: i64) void {
        var entry = &self.entries.items[idx];
        entry.last_attempt_at = now;
        if (entry.attempts < std.math.maxInt(u8)) entry.attempts += 1;
        entry.next_retry_at = now + retryDelaySecs(entry.attempts);
    }

    pub fn find(self: *const PeerCandidateList, address: std.net.Address, swarm_hash: [20]u8) ?usize {
        for (self.entries.items, 0..) |entry, idx| {
            if (!std.mem.eql(u8, entry.swarm_hash[0..], swarm_hash[0..])) continue;
            if (addr_mod.addressEql(&entry.address, &address)) return idx;
        }
        return null;
    }

    pub fn nextConnectableIndex(self: *const PeerCandidateList, now: i64) ?usize {
        for (self.entries.items, 0..) |entry, idx| {
            if (entry.next_retry_at <= now) return idx;
        }
        return null;
    }

    fn evictIndex(self: *const PeerCandidateList) usize {
        var best_idx: usize = 0;
        for (self.entries.items[1..], 1..) |entry, idx| {
            const best = self.entries.items[best_idx];
            if (entry.attempts > best.attempts or
                (entry.attempts == best.attempts and entry.last_seen < best.last_seen))
            {
                best_idx = idx;
            }
        }
        return best_idx;
    }
};

fn mergeSource(existing: PeerCandidateSource, incoming: PeerCandidateSource) PeerCandidateSource {
    if (existing == .manual or incoming == .manual) return .manual;
    if (existing == .tracker or incoming == .tracker) return .tracker;
    if (existing == .dht or incoming == .dht) return .dht;
    return .pex;
}

fn retryDelaySecs(attempts: u8) i64 {
    const shift: u6 = @intCast(@min(attempts -| 1, 4));
    const delay = retry_base_secs * (@as(i64, 1) << shift);
    return @min(delay, retry_max_secs);
}
