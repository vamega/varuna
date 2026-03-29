const std = @import("std");

/// Session-based authentication matching qBittorrent's auth flow.
/// Sessions are identified by a random 32-character hex string (SID).
/// Sessions expire after a configurable inactivity timeout.
pub const SessionStore = struct {
    const max_sessions = 10;
    const sid_len = 32;

    sessions: [max_sessions]?Session = [_]?Session{null} ** max_sessions,
    session_timeout_secs: i64 = 3600, // 1 hour default

    const Session = struct {
        sid: [sid_len]u8,
        last_active: i64,
    };

    /// Create a new session, returning the SID hex string.
    /// If max sessions are reached, evicts the oldest one.
    pub fn createSession(self: *SessionStore) [sid_len]u8 {
        const now = std.time.timestamp();

        // Find a free slot or the oldest session
        var target: usize = 0;
        var oldest_time: i64 = std.math.maxInt(i64);

        for (self.sessions, 0..) |session, i| {
            if (session == null) {
                target = i;
                break;
            }
            if (session.?.last_active < oldest_time) {
                oldest_time = session.?.last_active;
                target = i;
            }
        }

        var sid: [sid_len]u8 = undefined;
        generateSessionId(&sid);

        self.sessions[target] = .{
            .sid = sid,
            .last_active = now,
        };

        return sid;
    }

    /// Validate a session ID. Returns true if valid and not expired.
    /// Refreshes the session's last_active timestamp on success.
    pub fn validateSession(self: *SessionStore, sid: []const u8) bool {
        if (sid.len != sid_len) return false;
        const now = std.time.timestamp();

        for (&self.sessions) |*slot| {
            if (slot.*) |*session| {
                if (std.mem.eql(u8, &session.sid, sid)) {
                    if (now - session.last_active > self.session_timeout_secs) {
                        // Expired
                        slot.* = null;
                        return false;
                    }
                    session.last_active = now;
                    return true;
                }
            }
        }
        return false;
    }

    /// Remove a session (logout).
    pub fn removeSession(self: *SessionStore, sid: []const u8) void {
        if (sid.len != sid_len) return;
        for (&self.sessions) |*slot| {
            if (slot.*) |session| {
                if (std.mem.eql(u8, &session.sid, sid)) {
                    slot.* = null;
                    return;
                }
            }
        }
    }

    /// Count active (non-expired) sessions.
    pub fn activeCount(self: *const SessionStore) usize {
        const now = std.time.timestamp();
        var count: usize = 0;
        for (self.sessions) |session| {
            if (session) |s| {
                if (now - s.last_active <= self.session_timeout_secs) {
                    count += 1;
                }
            }
        }
        return count;
    }
};

fn generateSessionId(buf: *[SessionStore.sid_len]u8) void {
    const charset = "0123456789abcdef";
    var random_bytes: [SessionStore.sid_len / 2]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    for (random_bytes, 0..) |byte, i| {
        buf[i * 2] = charset[byte >> 4];
        buf[i * 2 + 1] = charset[byte & 0x0f];
    }
}

/// Extract the SID value from a Cookie header line.
/// Expects the raw header data (all headers), searches for Cookie: ...SID=xxx...
pub fn extractSidFromHeaders(data: []const u8) ?[]const u8 {
    // Search through header lines for Cookie header
    var line_start: usize = 0;
    while (line_start < data.len) {
        const line_end = std.mem.indexOfPos(u8, data, line_start, "\r\n") orelse data.len;
        const line = data[line_start..line_end];

        // Check for "Cookie:" header (case-insensitive on the header name)
        if (line.len > 7 and std.ascii.eqlIgnoreCase(line[0..7], "Cookie:")) {
            // Parse cookie value: "Cookie: SID=abc123; other=val"
            const cookie_value = std.mem.trimLeft(u8, line[7..], " ");
            return extractSidFromCookieValue(cookie_value);
        }

        if (line_end >= data.len) break;
        line_start = line_end + 2;
        // Stop at end of headers
        if (line.len == 0) break;
    }
    return null;
}

fn extractSidFromCookieValue(cookie: []const u8) ?[]const u8 {
    // Parse "SID=abc123" or "SID=abc123; other=val"
    var iter = std.mem.splitSequence(u8, cookie, "; ");
    while (iter.next()) |pair| {
        if (pair.len > 4 and std.mem.eql(u8, pair[0..4], "SID=")) {
            return pair[4..];
        }
    }
    return null;
}

// ── Tests ─────────────────────────────────────────────────

test "create and validate session" {
    var store = SessionStore{};
    const sid = store.createSession();

    try std.testing.expect(store.validateSession(&sid));
    try std.testing.expect(!store.validateSession("not-a-valid-sid-at-all-too-short"));
    try std.testing.expect(!store.validateSession("xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx"));
}

test "remove session invalidates it" {
    var store = SessionStore{};
    const sid = store.createSession();

    try std.testing.expect(store.validateSession(&sid));
    store.removeSession(&sid);
    try std.testing.expect(!store.validateSession(&sid));
}

test "expired session is rejected" {
    var store = SessionStore{ .session_timeout_secs = 0 };
    const sid = store.createSession();

    // With 0 timeout, any session created in the past is expired
    // Force expiry by setting last_active to the past
    for (&store.sessions) |*slot| {
        if (slot.*) |*session| {
            session.last_active -= 1;
        }
    }
    try std.testing.expect(!store.validateSession(&sid));
}

test "max sessions evicts oldest" {
    var store = SessionStore{};

    // Fill all slots
    var sids: [SessionStore.max_sessions][SessionStore.sid_len]u8 = undefined;
    for (0..SessionStore.max_sessions) |i| {
        sids[i] = store.createSession();
        // Stagger timestamps so oldest is deterministic
        for (&store.sessions) |*slot| {
            if (slot.*) |*session| {
                if (std.mem.eql(u8, &session.sid, &sids[i])) {
                    session.last_active = @as(i64, @intCast(i));
                }
            }
        }
    }

    // Create one more -- should evict the oldest (index 0)
    const new_sid = store.createSession();
    try std.testing.expect(store.validateSession(&new_sid));
    try std.testing.expect(!store.validateSession(&sids[0]));
    // Most recent should still be valid
    try std.testing.expect(store.validateSession(&sids[SessionStore.max_sessions - 1]));
}

test "extract SID from headers" {
    const headers = "Host: localhost\r\nCookie: SID=abcdef0123456789abcdef0123456789\r\nAccept: */*\r\n\r\n";
    const sid = extractSidFromHeaders(headers);
    try std.testing.expect(sid != null);
    try std.testing.expectEqualStrings("abcdef0123456789abcdef0123456789", sid.?);
}

test "extract SID from cookie with multiple values" {
    const headers = "Cookie: other=123; SID=abcdef0123456789abcdef0123456789; foo=bar\r\n\r\n";
    const sid = extractSidFromHeaders(headers);
    try std.testing.expect(sid != null);
    try std.testing.expectEqualStrings("abcdef0123456789abcdef0123456789", sid.?);
}

test "no cookie header returns null" {
    const headers = "Host: localhost\r\nAccept: */*\r\n\r\n";
    try std.testing.expect(extractSidFromHeaders(headers) == null);
}

test "active count tracks sessions" {
    var store = SessionStore{};
    try std.testing.expectEqual(@as(usize, 0), store.activeCount());

    _ = store.createSession();
    try std.testing.expectEqual(@as(usize, 1), store.activeCount());

    const sid2 = store.createSession();
    try std.testing.expectEqual(@as(usize, 2), store.activeCount());

    store.removeSession(&sid2);
    try std.testing.expectEqual(@as(usize, 1), store.activeCount());
}
