const std = @import("std");
const varuna = @import("varuna");

pub fn main() !void {
    var gpa_state = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();

    const args = try std.process.argsAlloc(allocator);
    defer std.process.argsFree(allocator, args);

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.fs.File.stdout().writer(&stdout_buffer);
    const stdout = &stdout_writer.interface;

    const cfg = varuna.config.loadDefault(allocator);
    const api_port = cfg.daemon.api_port;
    const api_host = cfg.daemon.api_bind;

    if (args.len <= 1) {
        try printUsage(stdout, api_host, api_port);
        try stdout.flush();
        return;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "list")) {
        try doGet(allocator, stdout, api_host, api_port, "/api/v2/torrents/info");
    } else if (std.mem.eql(u8, command, "status")) {
        if (args.len < 3) {
            try stdout.print("usage: varuna-ctl status <hash>\n", .{});
        } else {
            try doGet(allocator, stdout, api_host, api_port, "/api/v2/torrents/info");
        }
    } else if (std.mem.eql(u8, command, "add")) {
        if (args.len < 3) {
            try stdout.print("usage: varuna-ctl add <torrent-file> [--save-path <dir>]\n", .{});
        } else {
            const torrent_bytes = try std.fs.cwd().readFileAlloc(allocator, args[2], 16 * 1024 * 1024);
            defer allocator.free(torrent_bytes);

            // Parse --save-path
            var save_path: ?[]const u8 = null;
            var i: usize = 3;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--save-path") and i + 1 < args.len) {
                    save_path = args[i + 1];
                    i += 1;
                }
            }

            var path = std.ArrayList(u8).empty;
            defer path.deinit(allocator);
            try path.appendSlice(allocator, "/api/v2/torrents/add");
            if (save_path) |sp| {
                try path.print(allocator, "?savepath={s}", .{sp});
            }
            try doPost(allocator, stdout, api_host, api_port, path.items, torrent_bytes);
        }
    } else if (std.mem.eql(u8, command, "pause")) {
        if (args.len < 3) {
            try stdout.print("usage: varuna-ctl pause <hash>\n", .{});
        } else {
            var body = std.ArrayList(u8).empty;
            defer body.deinit(allocator);
            try body.print(allocator, "hashes={s}", .{args[2]});
            try doPost(allocator, stdout, api_host, api_port, "/api/v2/torrents/pause", body.items);
        }
    } else if (std.mem.eql(u8, command, "resume")) {
        if (args.len < 3) {
            try stdout.print("usage: varuna-ctl resume <hash>\n", .{});
        } else {
            var body = std.ArrayList(u8).empty;
            defer body.deinit(allocator);
            try body.print(allocator, "hashes={s}", .{args[2]});
            try doPost(allocator, stdout, api_host, api_port, "/api/v2/torrents/resume", body.items);
        }
    } else if (std.mem.eql(u8, command, "delete")) {
        if (args.len < 3) {
            try stdout.print("usage: varuna-ctl delete <hash> [--delete-files]\n", .{});
        } else {
            var body = std.ArrayList(u8).empty;
            defer body.deinit(allocator);
            try body.print(allocator, "hashes={s}", .{args[2]});
            try doPost(allocator, stdout, api_host, api_port, "/api/v2/torrents/delete", body.items);
        }
    } else if (std.mem.eql(u8, command, "version")) {
        try doGet(allocator, stdout, api_host, api_port, "/api/v2/app/webapiVersion");
    } else if (std.mem.eql(u8, command, "stats")) {
        try doGet(allocator, stdout, api_host, api_port, "/api/v2/transfer/info");
    } else {
        try stdout.print("unknown command: {s}\n\n", .{command});
        try printUsage(stdout, api_host, api_port);
    }

    try stdout.flush();
}

fn doGet(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    host: []const u8,
    port: u16,
    path: []const u8,
) !void {
    var ring = varuna.io.ring.Ring.init(16) catch {
        try stdout.print("error: io_uring unavailable\n", .{});
        return;
    };
    defer ring.deinit();

    var http = varuna.io.http.HttpClient.init(allocator, &ring);
    var url = std.ArrayList(u8).empty;
    defer url.deinit(allocator);
    try url.print(allocator, "http://{s}:{}{s}", .{ host, port, path });

    var response = http.get(url.items) catch |err| {
        try stdout.print("error: could not reach daemon ({s})\n", .{@errorName(err)});
        return;
    };
    defer response.deinit();

    try stdout.print("{s}\n", .{response.body});
}

fn doPost(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    host: []const u8,
    port: u16,
    path: []const u8,
    body: []const u8,
) !void {
    // Build a raw HTTP POST request and send via io_uring
    var ring = varuna.io.ring.Ring.init(16) catch {
        try stdout.print("error: io_uring unavailable\n", .{});
        return;
    };
    defer ring.deinit();

    const addr = std.net.Address.parseIp4(host, port) catch {
        try stdout.print("error: invalid daemon address\n", .{});
        return;
    };

    const fd = ring.socket(addr.any.family, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.TCP) catch {
        try stdout.print("error: could not create socket\n", .{});
        return;
    };
    defer std.posix.close(fd);

    ring.connect_timeout(fd, &addr.any, addr.getOsSockLen(), 5) catch {
        try stdout.print("error: could not connect to daemon\n", .{});
        return;
    };

    // Build HTTP POST
    var request = std.ArrayList(u8).empty;
    defer request.deinit(allocator);
    try request.print(allocator, "POST {s} HTTP/1.1\r\nHost: {s}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", .{ path, host, body.len });
    try request.appendSlice(allocator, body);

    ring.send_all(fd, request.items) catch {
        try stdout.print("error: failed to send request\n", .{});
        return;
    };

    // Read response
    var response_buf: [8192]u8 = undefined;
    const n = ring.recv(fd, &response_buf) catch {
        try stdout.print("error: failed to read response\n", .{});
        return;
    };
    const response = response_buf[0..n];

    // Extract body
    if (std.mem.indexOf(u8, response, "\r\n\r\n")) |body_start| {
        try stdout.print("{s}\n", .{response[body_start + 4 ..]});
    } else {
        try stdout.print("{s}\n", .{response});
    }
}

fn printUsage(stdout: *std.Io.Writer, host: []const u8, port: u16) !void {
    try stdout.print("varuna-ctl: control the varuna daemon\n\n", .{});
    try stdout.print("commands:\n", .{});
    try stdout.print("  list                           list all torrents\n", .{});
    try stdout.print("  add <torrent-file>             add torrent\n", .{});
    try stdout.print("  status <hash>                  torrent details\n", .{});
    try stdout.print("  pause <hash>                   pause torrent\n", .{});
    try stdout.print("  resume <hash>                  resume torrent\n", .{});
    try stdout.print("  delete <hash>                  delete torrent\n", .{});
    try stdout.print("  version                        daemon API version\n", .{});
    try stdout.print("  stats                          global transfer stats\n", .{});
    try stdout.print("\ndaemon: http://{s}:{}\n", .{ host, port });
}
