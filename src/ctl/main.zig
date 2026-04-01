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

    // Parse global flags: --username, --password
    var api_username: []const u8 = cfg.daemon.api_username;
    var api_password: []const u8 = cfg.daemon.api_password;
    var cmd_start: usize = 1;
    while (cmd_start < args.len) {
        if (std.mem.eql(u8, args[cmd_start], "--username") and cmd_start + 1 < args.len) {
            api_username = args[cmd_start + 1];
            cmd_start += 2;
        } else if (std.mem.eql(u8, args[cmd_start], "--password") and cmd_start + 1 < args.len) {
            api_password = args[cmd_start + 1];
            cmd_start += 2;
        } else {
            break;
        }
    }

    if (cmd_start >= args.len) {
        try printUsage(stdout, api_host, api_port);
        try stdout.flush();
        return;
    }

    // Login first to get SID
    const sid = doLogin(allocator, stdout, api_host, api_port, api_username, api_password) catch |err| {
        try stdout.print("error: login failed ({s})\n", .{@errorName(err)});
        try stdout.flush();
        return;
    };
    defer if (sid) |s| allocator.free(s);

    if (sid == null) {
        try stdout.print("error: authentication failed (bad credentials?)\n", .{});
        try stdout.flush();
        return;
    }

    const command = args[cmd_start];

    if (std.mem.eql(u8, command, "list")) {
        try doGet(allocator, stdout, api_host, api_port, "/api/v2/torrents/info", sid);
    } else if (std.mem.eql(u8, command, "status")) {
        if (cmd_start + 1 >= args.len) {
            try stdout.print("usage: varuna-ctl status <hash>\n", .{});
        } else {
            try doGet(allocator, stdout, api_host, api_port, "/api/v2/torrents/info", sid);
        }
    } else if (std.mem.eql(u8, command, "add")) {
        if (cmd_start + 1 >= args.len) {
            try stdout.print("usage: varuna-ctl add <torrent-file|--magnet URI> [--save-path <dir>]\n", .{});
        } else {
            // Parse flags
            var save_path: ?[]const u8 = null;
            var magnet_uri: ?[]const u8 = null;
            var torrent_file: ?[]const u8 = null;

            var i: usize = cmd_start + 1;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--save-path") and i + 1 < args.len) {
                    save_path = args[i + 1];
                    i += 1;
                } else if (std.mem.eql(u8, args[i], "--magnet") and i + 1 < args.len) {
                    magnet_uri = args[i + 1];
                    i += 1;
                } else if (std.mem.startsWith(u8, args[i], "magnet:")) {
                    // Direct magnet URI without --magnet flag
                    magnet_uri = args[i];
                } else if (torrent_file == null) {
                    torrent_file = args[i];
                }
            }

            if (magnet_uri) |magnet| {
                // Add via magnet link
                var body_buf = std.ArrayList(u8).empty;
                defer body_buf.deinit(allocator);
                try body_buf.print(allocator, "urls={s}", .{magnet});

                var path = std.ArrayList(u8).empty;
                defer path.deinit(allocator);
                try path.appendSlice(allocator, "/api/v2/torrents/add");
                if (save_path) |sp| {
                    try path.print(allocator, "?savepath={s}", .{sp});
                }
                try doPost(allocator, stdout, api_host, api_port, path.items, body_buf.items, sid);
            } else if (torrent_file) |tf| {
                // Add via .torrent file
                const torrent_bytes = try std.fs.cwd().readFileAlloc(allocator, tf, 16 * 1024 * 1024);
                defer allocator.free(torrent_bytes);

                var path = std.ArrayList(u8).empty;
                defer path.deinit(allocator);
                try path.appendSlice(allocator, "/api/v2/torrents/add");
                if (save_path) |sp| {
                    try path.print(allocator, "?savepath={s}", .{sp});
                }
                try doPost(allocator, stdout, api_host, api_port, path.items, torrent_bytes, sid);
            } else {
                try stdout.print("usage: varuna-ctl add <torrent-file|--magnet URI> [--save-path <dir>]\n", .{});
            }
        }
    } else if (std.mem.eql(u8, command, "pause")) {
        if (cmd_start + 1 >= args.len) {
            try stdout.print("usage: varuna-ctl pause <hash>\n", .{});
        } else {
            var body = std.ArrayList(u8).empty;
            defer body.deinit(allocator);
            try body.print(allocator, "hashes={s}", .{args[cmd_start + 1]});
            try doPost(allocator, stdout, api_host, api_port, "/api/v2/torrents/pause", body.items, sid);
        }
    } else if (std.mem.eql(u8, command, "resume")) {
        if (cmd_start + 1 >= args.len) {
            try stdout.print("usage: varuna-ctl resume <hash>\n", .{});
        } else {
            var body = std.ArrayList(u8).empty;
            defer body.deinit(allocator);
            try body.print(allocator, "hashes={s}", .{args[cmd_start + 1]});
            try doPost(allocator, stdout, api_host, api_port, "/api/v2/torrents/resume", body.items, sid);
        }
    } else if (std.mem.eql(u8, command, "delete")) {
        if (cmd_start + 1 >= args.len) {
            try stdout.print("usage: varuna-ctl delete <hash> [--delete-files]\n", .{});
        } else {
            // Check for --delete-files flag
            var delete_files = false;
            var i: usize = cmd_start + 2;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--delete-files")) {
                    delete_files = true;
                }
            }
            var body = std.ArrayList(u8).empty;
            defer body.deinit(allocator);
            try body.print(allocator, "hashes={s}&deleteFiles={s}", .{
                args[cmd_start + 1],
                if (delete_files) @as([]const u8, "true") else @as([]const u8, "false"),
            });
            try doPost(allocator, stdout, api_host, api_port, "/api/v2/torrents/delete", body.items, sid);
        }
    } else if (std.mem.eql(u8, command, "version")) {
        try doGet(allocator, stdout, api_host, api_port, "/api/v2/app/webapiVersion", sid);
    } else if (std.mem.eql(u8, command, "stats")) {
        try doGet(allocator, stdout, api_host, api_port, "/api/v2/transfer/info", sid);
    } else if (std.mem.eql(u8, command, "set-dl-limit")) {
        if (cmd_start + 2 >= args.len) {
            try stdout.print("usage: varuna-ctl set-dl-limit <hash|global> <bytes-per-sec>\n", .{});
        } else {
            const target = args[cmd_start + 1];
            const limit = args[cmd_start + 2];
            if (std.mem.eql(u8, target, "global")) {
                var body_buf = std.ArrayList(u8).empty;
                defer body_buf.deinit(allocator);
                try body_buf.print(allocator, "dl_limit={s}", .{limit});
                try doPost(allocator, stdout, api_host, api_port, "/api/v2/app/setPreferences", body_buf.items, sid);
            } else {
                var body_buf = std.ArrayList(u8).empty;
                defer body_buf.deinit(allocator);
                try body_buf.print(allocator, "hashes={s}&limit={s}", .{ target, limit });
                try doPost(allocator, stdout, api_host, api_port, "/api/v2/torrents/setDownloadLimit", body_buf.items, sid);
            }
        }
    } else if (std.mem.eql(u8, command, "set-ul-limit")) {
        if (cmd_start + 2 >= args.len) {
            try stdout.print("usage: varuna-ctl set-ul-limit <hash|global> <bytes-per-sec>\n", .{});
        } else {
            const target = args[cmd_start + 1];
            const limit = args[cmd_start + 2];
            if (std.mem.eql(u8, target, "global")) {
                var body_buf = std.ArrayList(u8).empty;
                defer body_buf.deinit(allocator);
                try body_buf.print(allocator, "up_limit={s}", .{limit});
                try doPost(allocator, stdout, api_host, api_port, "/api/v2/app/setPreferences", body_buf.items, sid);
            } else {
                var body_buf = std.ArrayList(u8).empty;
                defer body_buf.deinit(allocator);
                try body_buf.print(allocator, "hashes={s}&limit={s}", .{ target, limit });
                try doPost(allocator, stdout, api_host, api_port, "/api/v2/torrents/setUploadLimit", body_buf.items, sid);
            }
        }
    } else if (std.mem.eql(u8, command, "get-dl-limit")) {
        if (cmd_start + 1 >= args.len) {
            try stdout.print("usage: varuna-ctl get-dl-limit <hash|global>\n", .{});
        } else {
            const target = args[cmd_start + 1];
            if (std.mem.eql(u8, target, "global")) {
                try doGet(allocator, stdout, api_host, api_port, "/api/v2/app/preferences", sid);
            } else {
                var body_buf = std.ArrayList(u8).empty;
                defer body_buf.deinit(allocator);
                try body_buf.print(allocator, "hashes={s}", .{target});
                try doPost(allocator, stdout, api_host, api_port, "/api/v2/torrents/downloadLimit", body_buf.items, sid);
            }
        }
    } else if (std.mem.eql(u8, command, "get-ul-limit")) {
        if (cmd_start + 1 >= args.len) {
            try stdout.print("usage: varuna-ctl get-ul-limit <hash|global>\n", .{});
        } else {
            const target = args[cmd_start + 1];
            if (std.mem.eql(u8, target, "global")) {
                try doGet(allocator, stdout, api_host, api_port, "/api/v2/app/preferences", sid);
            } else {
                var body_buf = std.ArrayList(u8).empty;
                defer body_buf.deinit(allocator);
                try body_buf.print(allocator, "hashes={s}", .{target});
                try doPost(allocator, stdout, api_host, api_port, "/api/v2/torrents/uploadLimit", body_buf.items, sid);
            }
        }
    } else if (std.mem.eql(u8, command, "move")) {
        if (cmd_start + 2 >= args.len) {
            try stdout.print("usage: varuna-ctl move <hash> <new-path>\n", .{});
        } else {
            var body_buf = std.ArrayList(u8).empty;
            defer body_buf.deinit(allocator);
            try body_buf.print(allocator, "hashes={s}&location={s}", .{ args[cmd_start + 1], args[cmd_start + 2] });
            try doPost(allocator, stdout, api_host, api_port, "/api/v2/torrents/setLocation", body_buf.items, sid);
        }
    } else if (std.mem.eql(u8, command, "conn-diag")) {
        if (cmd_start + 1 >= args.len) {
            try stdout.print("usage: varuna-ctl conn-diag <hash>\n", .{});
        } else {
            var path_buf = std.ArrayList(u8).empty;
            defer path_buf.deinit(allocator);
            try path_buf.print(allocator, "/api/v2/torrents/connDiagnostics?hash={s}", .{args[cmd_start + 1]});
            try doGet(allocator, stdout, api_host, api_port, path_buf.items, sid);
        }
    } else if (std.mem.eql(u8, command, "add-tracker")) {
        if (cmd_start + 2 >= args.len) {
            try stdout.print("usage: varuna-ctl add-tracker <hash> <url> [<url2> ...]\n", .{});
        } else {
            const hash = args[cmd_start + 1];
            // Collect all URLs after hash, join with %0A (newline-encoded)
            var urls_buf = std.ArrayList(u8).empty;
            defer urls_buf.deinit(allocator);
            var i: usize = cmd_start + 2;
            while (i < args.len) : (i += 1) {
                if (i > cmd_start + 2) try urls_buf.appendSlice(allocator, "%0A");
                try urls_buf.appendSlice(allocator, args[i]);
            }
            var body_buf = std.ArrayList(u8).empty;
            defer body_buf.deinit(allocator);
            try body_buf.print(allocator, "hash={s}&urls={s}", .{ hash, urls_buf.items });
            try doPost(allocator, stdout, api_host, api_port, "/api/v2/torrents/addTrackers", body_buf.items, sid);
        }
    } else if (std.mem.eql(u8, command, "remove-tracker")) {
        if (cmd_start + 2 >= args.len) {
            try stdout.print("usage: varuna-ctl remove-tracker <hash> <url> [<url2> ...]\n", .{});
        } else {
            const hash = args[cmd_start + 1];
            // Collect all URLs after hash, join with | (pipe-separated)
            var urls_buf = std.ArrayList(u8).empty;
            defer urls_buf.deinit(allocator);
            var i: usize = cmd_start + 2;
            while (i < args.len) : (i += 1) {
                if (i > cmd_start + 2) try urls_buf.appendSlice(allocator, "%7C");
                try urls_buf.appendSlice(allocator, args[i]);
            }
            var body_buf = std.ArrayList(u8).empty;
            defer body_buf.deinit(allocator);
            try body_buf.print(allocator, "hash={s}&urls={s}", .{ hash, urls_buf.items });
            try doPost(allocator, stdout, api_host, api_port, "/api/v2/torrents/removeTrackers", body_buf.items, sid);
        }
    } else if (std.mem.eql(u8, command, "edit-tracker")) {
        if (cmd_start + 3 >= args.len) {
            try stdout.print("usage: varuna-ctl edit-tracker <hash> <old-url> <new-url>\n", .{});
        } else {
            var body_buf = std.ArrayList(u8).empty;
            defer body_buf.deinit(allocator);
            try body_buf.print(allocator, "hash={s}&origUrl={s}&newUrl={s}", .{ args[cmd_start + 1], args[cmd_start + 2], args[cmd_start + 3] });
            try doPost(allocator, stdout, api_host, api_port, "/api/v2/torrents/editTracker", body_buf.items, sid);
        }
    } else if (std.mem.eql(u8, command, "ban")) {
        if (cmd_start + 1 >= args.len) {
            try stdout.print("usage: varuna-ctl ban <ip> [--reason <text>]\n", .{});
        } else {
            const ip = args[cmd_start + 1];
            // Parse optional --reason flag (reserved for future use)
            var i: usize = cmd_start + 2;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--reason") and i + 1 < args.len) {
                    i += 1; // skip the reason value
                }
            }
            var body_buf = std.ArrayList(u8).empty;
            defer body_buf.deinit(allocator);
            try body_buf.print(allocator, "peers={s}:0", .{ip});
            try doPost(allocator, stdout, api_host, api_port, "/api/v2/transfer/banPeers", body_buf.items, sid);
        }
    } else if (std.mem.eql(u8, command, "unban")) {
        if (cmd_start + 1 >= args.len) {
            try stdout.print("usage: varuna-ctl unban <ip>\n", .{});
        } else {
            var body_buf = std.ArrayList(u8).empty;
            defer body_buf.deinit(allocator);
            try body_buf.print(allocator, "ips={s}", .{args[cmd_start + 1]});
            try doPost(allocator, stdout, api_host, api_port, "/api/v2/transfer/unbanPeers", body_buf.items, sid);
        }
    } else if (std.mem.eql(u8, command, "banlist")) {
        // Always outputs JSON from API (--json flag accepted for compatibility)
        try doGet(allocator, stdout, api_host, api_port, "/api/v2/transfer/bannedPeers", sid);
    } else if (std.mem.eql(u8, command, "import-banlist")) {
        if (cmd_start + 1 >= args.len) {
            try stdout.print("usage: varuna-ctl import-banlist <file> [--format auto|dat|p2p|cidr]\n", .{});
        } else {
            const file_path = args[cmd_start + 1];
            var format: []const u8 = "auto";
            var i: usize = cmd_start + 2;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--format") and i + 1 < args.len) {
                    format = args[i + 1];
                    i += 1;
                }
            }

            // Read the file and POST it
            const file_data = std.fs.cwd().readFileAlloc(allocator, file_path, 64 * 1024 * 1024) catch |err| {
                try stdout.print("error: could not read file: {s}\n", .{@errorName(err)});
                try stdout.flush();
                return;
            };
            defer allocator.free(file_data);

            // Build body with format parameter followed by file content
            var body_buf = std.ArrayList(u8).empty;
            defer body_buf.deinit(allocator);
            try body_buf.print(allocator, "format={s}&file=", .{format});
            try body_buf.appendSlice(allocator, file_data);
            try doPost(allocator, stdout, api_host, api_port, "/api/v2/transfer/importBanList", body_buf.items, sid);
        }
    } else {
        try stdout.print("unknown command: {s}\n\n", .{command});
        try printUsage(stdout, api_host, api_port);
    }

    try stdout.flush();
}

/// Login to the daemon API and return the SID cookie value.
/// Returns null if credentials are rejected, error on connection failure.
fn doLogin(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    host: []const u8,
    port: u16,
    username: []const u8,
    password: []const u8,
) !?[]u8 {
    _ = stdout;
    var ring = varuna.io.ring.Ring.init(16) catch return error.IoUringUnavailable;
    defer ring.deinit();

    const addr = std.net.Address.parseIp4(host, port) catch return error.InvalidAddress;

    const fd = try ring.socket(addr.any.family, std.posix.SOCK.STREAM | std.posix.SOCK.CLOEXEC, std.posix.IPPROTO.TCP);
    defer std.posix.close(fd);

    try ring.connect_timeout(fd, &addr.any, addr.getOsSockLen(), 5);

    // Build login body
    var body_buf = std.ArrayList(u8).empty;
    defer body_buf.deinit(allocator);
    try body_buf.print(allocator, "username={s}&password={s}", .{ username, password });

    // Build HTTP POST
    var request = std.ArrayList(u8).empty;
    defer request.deinit(allocator);
    try request.print(allocator, "POST /api/v2/auth/login HTTP/1.1\r\nHost: {s}\r\nContent-Length: {}\r\nConnection: close\r\n\r\n", .{ host, body_buf.items.len });
    try request.appendSlice(allocator, body_buf.items);

    try ring.send_all(fd, request.items);

    // Read response
    var response_buf: [8192]u8 = undefined;
    const n = try ring.recv(fd, &response_buf);
    const response = response_buf[0..n];

    // Check for successful login (body should be "Ok.")
    const header_end = std.mem.indexOf(u8, response, "\r\n\r\n") orelse return null;
    const resp_body = response[header_end + 4 ..];
    if (!std.mem.eql(u8, resp_body, "Ok.")) return null;

    // Extract SID from Set-Cookie header
    const headers = response[0..header_end];
    return extractSidFromSetCookie(allocator, headers);
}

/// Extract SID value from a Set-Cookie header in the response.
fn extractSidFromSetCookie(allocator: std.mem.Allocator, headers: []const u8) ?[]u8 {
    var line_start: usize = 0;
    while (line_start < headers.len) {
        const line_end = std.mem.indexOfPos(u8, headers, line_start, "\r\n") orelse headers.len;
        const line = headers[line_start..line_end];

        // Look for "Set-Cookie:" header
        if (line.len > 11 and std.ascii.eqlIgnoreCase(line[0..11], "Set-Cookie:")) {
            const value = std.mem.trimLeft(u8, line[11..], " ");
            // Parse "SID=<value>; HttpOnly; path=/"
            if (std.mem.startsWith(u8, value, "SID=")) {
                const sid_start = 4;
                const sid_end = std.mem.indexOfScalar(u8, value[sid_start..], ';') orelse (value.len - sid_start);
                const sid = value[sid_start .. sid_start + sid_end];
                return allocator.dupe(u8, sid) catch return null;
            }
        }

        if (line_end >= headers.len) break;
        line_start = line_end + 2;
    }
    return null;
}

fn doGet(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    host: []const u8,
    port: u16,
    path: []const u8,
    sid: ?[]const u8,
) !void {
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

    // Build HTTP GET with Cookie header
    var request = std.ArrayList(u8).empty;
    defer request.deinit(allocator);
    try request.print(allocator, "GET {s} HTTP/1.1\r\nHost: {s}\r\n", .{ path, host });
    if (sid) |s| {
        try request.print(allocator, "Cookie: SID={s}\r\n", .{s});
    }
    try request.appendSlice(allocator, "Connection: close\r\n\r\n");

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

fn doPost(
    allocator: std.mem.Allocator,
    stdout: *std.Io.Writer,
    host: []const u8,
    port: u16,
    path: []const u8,
    body: []const u8,
    sid: ?[]const u8,
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

    // Build HTTP POST with Cookie header
    var request = std.ArrayList(u8).empty;
    defer request.deinit(allocator);
    try request.print(allocator, "POST {s} HTTP/1.1\r\nHost: {s}\r\nContent-Length: {}\r\n", .{ path, host, body.len });
    if (sid) |s| {
        try request.print(allocator, "Cookie: SID={s}\r\n", .{s});
    }
    try request.appendSlice(allocator, "Connection: close\r\n\r\n");
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
    try stdout.print("options:\n", .{});
    try stdout.print("  --username <user>              API username (default: admin)\n", .{});
    try stdout.print("  --password <pass>              API password (default: adminadmin)\n", .{});
    try stdout.print("\ncommands:\n", .{});
    try stdout.print("  list                           list all torrents\n", .{});
    try stdout.print("  add <torrent-file>             add torrent\n", .{});
    try stdout.print("  status <hash>                  torrent details\n", .{});
    try stdout.print("  pause <hash>                   pause torrent\n", .{});
    try stdout.print("  resume <hash>                  resume torrent\n", .{});
    try stdout.print("  delete <hash> [--delete-files] delete torrent (optionally remove data)\n", .{});
    try stdout.print("  set-dl-limit <hash|global> <N> set download limit (bytes/sec, 0=off)\n", .{});
    try stdout.print("  set-ul-limit <hash|global> <N> set upload limit (bytes/sec, 0=off)\n", .{});
    try stdout.print("  get-dl-limit <hash|global>     get download limit\n", .{});
    try stdout.print("  get-ul-limit <hash|global>     get upload limit\n", .{});
    try stdout.print("  move <hash> <path>             move torrent data to new path\n", .{});
    try stdout.print("  conn-diag <hash>               connection diagnostics\n", .{});
    try stdout.print("  add-tracker <hash> <url> ...    add tracker URL(s)\n", .{});
    try stdout.print("  remove-tracker <hash> <url> ... remove tracker URL(s)\n", .{});
    try stdout.print("  edit-tracker <hash> <old> <new> replace a tracker URL\n", .{});
    try stdout.print("  ban <ip> [--reason <text>]      ban a peer IP\n", .{});
    try stdout.print("  unban <ip>                     unban a peer IP\n", .{});
    try stdout.print("  banlist [--json]               list banned peers\n", .{});
    try stdout.print("  import-banlist <file>           import ipfilter file\n", .{});
    try stdout.print("  version                        daemon API version\n", .{});
    try stdout.print("  stats                          global transfer stats\n", .{});
    try stdout.print("\ndaemon: http://{s}:{}\n", .{ host, port });
}
