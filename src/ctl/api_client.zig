const std = @import("std");
const varuna = @import("varuna");

const http = varuna.io.http_parse;
const CtlIO = varuna.io.epoll_posix_io.EpollPosixIO;
const HttpExecutor = varuna.io.http_executor.HttpExecutorOf(CtlIO);

pub const Response = struct {
    status: u16,
    headers: []u8,
    body: []u8,

    pub fn deinit(self: Response, allocator: std.mem.Allocator) void {
        allocator.free(self.headers);
        allocator.free(self.body);
    }

    pub fn headerValue(self: Response, name: []const u8) ?[]const u8 {
        return http.findHeaderValue(self.headers, name);
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    host: []const u8,
    port: u16,
    sid: ?[]u8 = null,

    pub fn init(allocator: std.mem.Allocator, host: []const u8, port: u16) Client {
        return .{
            .allocator = allocator,
            .host = host,
            .port = port,
        };
    }

    pub fn deinit(self: *Client) void {
        if (self.sid) |sid| self.allocator.free(sid);
        self.sid = null;
    }

    pub fn login(self: *Client, username: []const u8, password: []const u8) !bool {
        var body = std.ArrayList(u8).empty;
        defer body.deinit(self.allocator);
        try body.print(self.allocator, "username={s}&password={s}", .{ username, password });

        const response = try self.request(.{
            .method = "POST",
            .path = "/api/v2/auth/login",
            .body = body.items,
            .content_type = "application/x-www-form-urlencoded",
            .authenticated = false,
        });
        defer response.deinit(self.allocator);

        if (!std.mem.eql(u8, response.body, "Ok.")) return false;
        const sid = extractSidFromSetCookie(self.allocator, response.headers) orelse return false;
        if (self.sid) |old| self.allocator.free(old);
        self.sid = sid;
        return true;
    }

    pub const RequestOptions = struct {
        method: []const u8,
        path: []const u8,
        body: []const u8 = "",
        content_type: ?[]const u8 = null,
        authenticated: bool = true,
        extra_headers: []const http.Header = &.{},
    };

    pub fn request(self: *Client, options: RequestOptions) !Response {
        var cookie_buf = std.ArrayList(u8).empty;
        defer cookie_buf.deinit(self.allocator);
        var cookie: ?[]const u8 = null;
        if (options.authenticated) {
            if (self.sid) |sid| {
                try cookie_buf.print(self.allocator, "SID={s}", .{sid});
                cookie = cookie_buf.items;
            }
        }

        var url_buf: [HttpExecutor.max_url_len]u8 = undefined;
        const url = try std.fmt.bufPrint(&url_buf, "http://{s}:{d}{s}", .{ self.host, self.port, options.path });
        if (self.host.len > HttpExecutor.max_host_len) return error.HostTooLong;

        var job = HttpExecutor.Job{
            .context = undefined,
            .on_complete = SyncRequest.onComplete,
            .url_len = @intCast(url.len),
            .host_len = @intCast(self.host.len),
            .body = options.body,
        };
        @memcpy(job.url[0..url.len], url);
        @memcpy(job.host[0..self.host.len], self.host);
        job.setMethodOn(options.method);
        if (options.content_type) |content_type| job.setContentType(content_type);
        if (cookie) |cookie_value| job.setCookie(cookie_value);
        try setExtraHeaders(&job, options.extra_headers);

        var request_ctx = SyncRequest{ .allocator = self.allocator };
        job.context = &request_ctx;

        var io = try CtlIO.init(self.allocator, .{ .file_pool_workers = 0 });
        defer io.deinit();
        const executor = try HttpExecutor.create(self.allocator, &io, .{
            .max_concurrent = 1,
            .max_per_host = 1,
        });
        defer executor.destroy();

        try executor.submit(job);

        while (!request_ctx.done) {
            executor.tick();
            if (request_ctx.done) break;
            try io.tick(1);
        }

        if (request_ctx.err) |err| return err;
        return request_ctx.response orelse error.EmptyResponse;
    }
};

const SyncRequest = struct {
    allocator: std.mem.Allocator,
    done: bool = false,
    response: ?Response = null,
    err: ?anyerror = null,

    fn onComplete(context: *anyopaque, result: HttpExecutor.RequestResult) void {
        const self: *SyncRequest = @ptrCast(@alignCast(context));
        self.done = true;
        if (result.err) |err| {
            self.err = err;
            return;
        }

        const headers = self.allocator.dupe(u8, result.headers orelse "") catch |err| {
            self.err = err;
            return;
        };
        const body = self.allocator.dupe(u8, result.body orelse "") catch |err| {
            self.allocator.free(headers);
            self.err = err;
            return;
        };

        self.response = .{
            .status = result.status,
            .headers = headers,
            .body = body,
        };
    }
};

fn setExtraHeaders(job: *HttpExecutor.Job, headers: []const http.Header) !void {
    if (headers.len > HttpExecutor.max_extra_headers) return error.TooManyHeaders;
    for (headers, 0..) |header, i| {
        if (header.name.len == 0) continue;
        var line_buf: [HttpExecutor.max_header_len]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "{s}: {s}", .{ header.name, header.value });
        job.extra_headers[i] = HttpExecutor.ExtraHeader.set(line);
    }
}

fn extractSidFromSetCookie(allocator: std.mem.Allocator, headers: []const u8) ?[]u8 {
    var line_start: usize = 0;
    while (line_start < headers.len) {
        const line_end = std.mem.indexOfPos(u8, headers, line_start, "\r\n") orelse headers.len;
        const line = headers[line_start..line_end];

        if (line.len > "Set-Cookie:".len and std.ascii.eqlIgnoreCase(line[0.."Set-Cookie:".len], "Set-Cookie:")) {
            const value = std.mem.trimLeft(u8, line["Set-Cookie:".len..], " ");
            if (std.mem.startsWith(u8, value, "SID=")) {
                const sid_tail = value["SID=".len..];
                const sid_end = std.mem.indexOfScalar(u8, sid_tail, ';') orelse sid_tail.len;
                return allocator.dupe(u8, sid_tail[0..sid_end]) catch null;
            }
        }

        if (line_end >= headers.len) break;
        line_start = line_end + 2;
    }
    return null;
}

test "extractSidFromSetCookie returns SID value" {
    const sid = extractSidFromSetCookie(
        std.testing.allocator,
        "HTTP/1.1 200 OK\r\nSet-Cookie: SID=abc123; HttpOnly; path=/\r\n",
    ).?;
    defer std.testing.allocator.free(sid);

    try std.testing.expectEqualStrings("abc123", sid);
}
