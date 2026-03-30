const std = @import("std");
const varuna = @import("varuna");

var stdout_buffer: [4096]u8 = undefined;

fn getStdout() *std.Io.Writer {
    var writer = std.fs.File.stdout().writer(&stdout_buffer);
    return &writer.interface;
}

fn printResult(
    stdout: *std.Io.Writer,
    name: []const u8,
    iterations: usize,
    elapsed_ns: u64,
    bytes_processed: ?u64,
    checksum: u64,
) !void {
    const per_iteration_ns = @divTrunc(elapsed_ns, iterations);
    try stdout.print("{s}: iterations={}, ns_per_iteration={}", .{ name, iterations, per_iteration_ns });
    if (bytes_processed) |total_bytes| {
        const elapsed_secs_x1000 = elapsed_ns / 1_000_000;
        if (elapsed_secs_x1000 > 0) {
            const mb_per_sec = (total_bytes * 1000) / elapsed_secs_x1000 / (1024 * 1024);
            try stdout.print(", throughput={} MB/s", .{mb_per_sec});
        }
    }
    try stdout.print(", checksum={}\n", .{checksum});
    try stdout.flush();
}

fn benchKernelParser(stdout: *std.Io.Writer) !void {
    var timer = try std.time.Timer.start();
    const iterations: usize = 100_000;

    var checksum: u64 = 0;
    for (0..iterations) |_| {
        const parsed = try varuna.runtime.kernel.parseRelease("6.6.87.2-microsoft-standard-WSL2");
        checksum +%= parsed.patch;
    }

    try printResult(stdout, "kernel_parser", iterations, timer.read(), null, checksum);
}

fn benchBencodeParse(stdout: *std.Io.Writer) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Build a pure bencode dictionary for parsing throughput (not valid torrent metadata)
    var input_buf = std.ArrayList(u8).empty;
    defer input_buf.deinit(allocator);

    try input_buf.appendSlice(allocator, "d");
    for (0..200) |i| {
        const key = try std.fmt.allocPrint(allocator, "{:0>4}", .{i});
        defer allocator.free(key);
        try input_buf.print(allocator, "{}:{s}i{}e", .{ key.len, key, i * 1024 });
    }
    try input_buf.appendSlice(allocator, "e");

    const input = input_buf.items;
    const iterations: usize = 10_000;

    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        const value = try varuna.torrent.bencode.parse(allocator, input);
        checksum +%= @intCast(value.dict.len);
        varuna.torrent.bencode.freeValue(allocator, value);
    }

    const total_bytes: u64 = @as(u64, iterations) * input.len;
    try printResult(stdout, "bencode_parse", iterations, timer.read(), total_bytes, checksum);
}

fn benchSha1Generic(
    stdout: *std.Io.Writer,
    comptime HashFn: type,
    comptime name: []const u8,
    buffer: []const u8,
    iterations: usize,
) !void {
    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        var digest: [20]u8 = undefined;
        HashFn.hash(buffer, &digest, .{});
        checksum +%= digest[0];
    }

    const total_bytes: u64 = @as(u64, iterations) * buffer.len;
    try printResult(stdout, name, iterations, timer.read(), total_bytes, checksum);
}

fn benchSha1DirectShaNi(
    stdout: *std.Io.Writer,
    comptime name: []const u8,
    buffer: []const u8,
    iterations: usize,
) !void {
    const Sha1 = varuna.crypto.Sha1;
    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        // Use the direct SHA-NI round function — no detection, no switch
        var d = Sha1.init(.{});
        var off: usize = 0;
        while (off + 64 <= buffer.len) : (off += 64) {
            d.roundDirectShaNi(@ptrCast(buffer[off..][0..64]));
        }
        // Handle remaining bytes via full update for correctness
        if (off < buffer.len) d.update(buffer[off..]);
        var digest: [20]u8 = undefined;
        d.final(&digest);
        checksum +%= digest[0];
    }
    const total_bytes: u64 = @as(u64, iterations) * buffer.len;
    try printResult(stdout, name, iterations, timer.read(), total_bytes, checksum);
}

fn benchSha1Noop(
    stdout: *std.Io.Writer,
    comptime name: []const u8,
    buffer: []const u8,
    iterations: usize,
) !void {
    // Measures memory bandwidth — read the buffer, return a fixed hash
    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        // Touch every byte to measure read bandwidth
        var sum: u8 = 0;
        for (buffer) |b| sum +%= b;
        checksum +%= sum;
    }
    const total_bytes: u64 = @as(u64, iterations) * buffer.len;
    try printResult(stdout, name, iterations, timer.read(), total_bytes, checksum);
}

fn benchSha1(stdout: *std.Io.Writer) !void {
    const Sha1 = varuna.crypto.Sha1;
    const StdSha1 = std.crypto.hash.Sha1;

    const piece_256k: usize = 256 * 1024;
    const piece_1m: usize = 1024 * 1024;
    var buffer_256k: [piece_256k]u8 = undefined;
    var buffer_1m: [piece_1m]u8 = undefined;
    for (&buffer_256k, 0..) |*byte, i| byte.* = @truncate(i *% 7 +% 13);
    for (&buffer_1m, 0..) |*byte, i| byte.* = @truncate(i *% 7 +% 13);

    const iterations_256k: usize = 2000;
    const iterations_1m: usize = 500;

    // Report runtime-detected acceleration backend
    try stdout.print("sha1_accel={s}, hw_enabled={}\n", .{ @tagName(Sha1.accel()), Sha1.hasShaNi() });
    try stdout.flush();

    // --- 256KB ---
    try benchSha1Noop(stdout, "sha1_noop_256kb", &buffer_256k, iterations_256k);
    try benchSha1Generic(stdout, StdSha1, "sha1_std_256kb", &buffer_256k, iterations_256k);
    try benchSha1Generic(stdout, Sha1, "sha1_varuna_256kb", &buffer_256k, iterations_256k);
    try benchSha1DirectShaNi(stdout, "sha1_direct_shani_256kb", &buffer_256k, iterations_256k);

    // --- 1MB ---
    try benchSha1Noop(stdout, "sha1_noop_1mb", &buffer_1m, iterations_1m);
    try benchSha1Generic(stdout, StdSha1, "sha1_std_1mb", &buffer_1m, iterations_1m);
    try benchSha1Generic(stdout, Sha1, "sha1_varuna_1mb", &buffer_1m, iterations_1m);
    try benchSha1DirectShaNi(stdout, "sha1_direct_shani_1mb", &buffer_1m, iterations_1m);
}

fn benchMetainfoParse(stdout: *std.Io.Writer) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Use same structure as the working tests
    const input =
        "d8:announce14:http://tracker" ++
        "4:infod6:lengthi1048576e4:name8:test.bin12:piece lengthi16384e" ++
        "6:pieces1280:" ++ ("A" ** 1280) ++ "ee";

    const iterations: usize = 1_000;

    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;
    for (0..iterations) |_| {
        const info = try varuna.torrent.metainfo.parse(allocator, input);
        checksum +%= info.piece_length;
        varuna.torrent.metainfo.freeMetainfo(allocator, info);
    }

    const total_bytes: u64 = @as(u64, iterations) * input.len;
    try printResult(stdout, "metainfo_parse", iterations, timer.read(), total_bytes, checksum);
}

fn benchBitfieldOps(stdout: *std.Io.Writer) !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const piece_count: u32 = 10_000;
    var bf = try varuna.bitfield.Bitfield.init(allocator, piece_count);
    defer bf.deinit(allocator);

    const iterations: usize = 1_000;

    var timer = try std.time.Timer.start();
    var checksum: u64 = 0;
    for (0..iterations) |iter| {
        // Simulate scanning for a claimable piece (rarest-first inner loop)
        var i: u32 = 0;
        while (i < piece_count) : (i += 1) {
            if (!bf.has(i)) {
                checksum +%= i;
                break;
            }
        }
        // Set a piece to simulate progress
        bf.set(@intCast(iter % piece_count)) catch {};
    }

    const total_ops: u64 = @as(u64, iterations) * piece_count;
    try printResult(stdout, "bitfield_scan_10k", iterations, timer.read(), total_ops, checksum);
}

pub fn main() !void {
    var writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &writer.interface;

    try benchKernelParser(stdout);
    try benchBencodeParse(stdout);
    try benchSha1(stdout);
    try benchMetainfoParse(stdout);
    try benchBitfieldOps(stdout);
}
