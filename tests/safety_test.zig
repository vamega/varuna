const std = @import("std");
const varuna = @import("varuna");
const address = varuna.net.address;
const utp = varuna.net.utp;

// ── Compile-time and runtime safety tests ───────────────────
//
// These tests catch regressions from past production bugs:
// - 46MB stack overflow from passing std.net.Address (112 bytes) by value
//   in a 4096-iteration loop
// - UAF from UtpSocket.out_buf leaving pointer fields as garbage when
//   initialized with `= undefined`
// - Struct size regressions that silently degrade performance or blow stacks

// ═══════════════════════════════════════════════════════════════
// 1. Large parameter size detection
// ═══════════════════════════════════════════════════════════════

test "std.net.Address is not passed by value in addressEql" {
    // addressEql must take pointers to avoid 112-byte copies in hot loops.
    // Passing std.net.Address by value caused a 46MB stack overflow.
    const fn_info = @typeInfo(@TypeOf(address.addressEql)).@"fn";
    inline for (fn_info.params) |p| {
        // Pointers are 8 bytes; the raw Address union is 112 bytes.
        // Anything <= 16 bytes is fine (pointer, small struct).
        try std.testing.expect(@sizeOf(p.type.?) <= 16);
    }
}

test "addressEql parameters are const pointers" {
    // Verify the function signature is actually *const std.net.Address,
    // not just a small struct that happens to be <= 16 bytes.
    const fn_info = @typeInfo(@TypeOf(address.addressEql)).@"fn";
    inline for (fn_info.params) |p| {
        const param_info = @typeInfo(p.type.?);
        // Must be a pointer type (not a value type that happens to be small).
        try std.testing.expect(param_info == .pointer);
    }
}

// ═══════════════════════════════════════════════════════════════
// 2. Struct initialization safety
// ═══════════════════════════════════════════════════════════════

test "UtpSocket out_buf initializes packet_buf to null" {
    // A past bug had `out_buf: [128]OutPacket = undefined` which left
    // pointer fields (packet_buf) as garbage, causing UAF on deinit.
    // Default initialization must set packet_buf to null for every slot.
    const sock = utp.UtpSocket{};
    for (&sock.out_buf) |*pkt| {
        try std.testing.expect(pkt.packet_buf == null);
    }
}

test "UtpSocket out_buf default fields are zero-initialized" {
    // Verify all OutPacket fields start in a safe, known state.
    const sock = utp.UtpSocket{};
    for (&sock.out_buf) |*pkt| {
        try std.testing.expectEqual(@as(u16, 0), pkt.seq_nr);
        try std.testing.expectEqual(@as(u16, 0), pkt.payload_len);
        try std.testing.expectEqual(@as(u32, 0), pkt.send_time_us);
        try std.testing.expectEqual(@as(u8, 0), pkt.retransmit_count);
        try std.testing.expect(!pkt.acked);
        try std.testing.expect(!pkt.needs_resend);
    }
}

// ═══════════════════════════════════════════════════════════════
// 3. Struct size regression tests
// ═══════════════════════════════════════════════════════════════

test "UtpSocket size stays under 8KB" {
    // UtpSocket lives on the stack in several call paths.
    // If it grows past 8KB, we risk stack pressure or need heap allocation.
    try std.testing.expect(@sizeOf(utp.UtpSocket) < 8192);
}

test "std.net.Address size is documented" {
    // std.net.Address is a 112-byte union containing sockaddr_in, sockaddr_in6,
    // and sockaddr_un. If this changes upstream, audit all by-value usage.
    try std.testing.expect(@sizeOf(std.net.Address) <= 128);
}

test "OutPacket size stays reasonable" {
    // OutPacket is stored in a [128] array inside UtpSocket.
    // Keep it under 64 bytes to prevent UtpSocket bloat.
    try std.testing.expect(@sizeOf(utp.OutPacket) <= 64);
}

// ═══════════════════════════════════════════════════════════════
// 4. fd leak detection helper
// ═══════════════════════════════════════════════════════════════

/// Count open file descriptors via /proc/self/fd.
/// Useful for detecting fd leaks in tests that create sockets, files, etc.
/// Returns 0 if /proc is unavailable (non-Linux or restricted).
pub fn countOpenFds() usize {
    var dir = std.fs.openDirAbsolute("/proc/self/fd", .{ .iterate = true }) catch return 0;
    defer dir.close();
    var count: usize = 0;
    var it = dir.iterate();
    while (it.next() catch null) |_| count += 1;
    return count;
}

test "countOpenFds returns nonzero on Linux" {
    // On Linux with /proc mounted, we always have at least stdin/stdout/stderr.
    const fds = countOpenFds();
    try std.testing.expect(fds >= 3);
}

test "countOpenFds detects new file descriptors" {
    const before = countOpenFds();
    // Open a file to create a new fd.
    const f = std.fs.openFileAbsolute("/dev/null", .{}) catch return;
    const after = countOpenFds();
    f.close();
    const after_close = countOpenFds();

    // We should see one more fd while the file is open.
    try std.testing.expect(after > before);
    // After closing, count should drop back.
    try std.testing.expect(after_close < after);
}

// ═══════════════════════════════════════════════════════════════
// 5. Thread count helper
// ═══════════════════════════════════════════════════════════════

/// Count threads in the current process via /proc/self/task.
/// Useful for detecting thread leaks in tests that spawn workers.
/// Returns 0 if /proc is unavailable (non-Linux or restricted).
pub fn countThreads() usize {
    var dir = std.fs.openDirAbsolute("/proc/self/task", .{ .iterate = true }) catch return 0;
    defer dir.close();
    var count: usize = 0;
    var it = dir.iterate();
    while (it.next() catch null) |_| count += 1;
    return count;
}

test "countThreads returns at least 1" {
    // The main thread always exists.
    const threads = countThreads();
    try std.testing.expect(threads >= 1);
}
