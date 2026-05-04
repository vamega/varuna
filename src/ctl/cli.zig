const std = @import("std");

pub const Format = enum {
    human,
    json,
};

pub const Defaults = struct {
    username: []const u8,
    password: []const u8,
};

pub const GlobalOptions = struct {
    username: []const u8,
    password: []const u8,
    format: Format = .human,
    command_index: usize = 1,
};

pub const DebugView = enum {
    peers,
    conn_diagnostics,
    trackers,
    properties,
    maindata,
};

pub const DiagnosticRequest = struct {
    view: DebugView,
    hash: ?[]const u8 = null,
    rid: ?[]const u8 = null,
};

pub fn parseGlobalOptions(args: []const []const u8, defaults: Defaults) !GlobalOptions {
    var parsed = GlobalOptions{
        .username = defaults.username,
        .password = defaults.password,
    };

    var i: usize = 1;
    while (i < args.len) {
        if (std.mem.eql(u8, args[i], "--username")) {
            if (i + 1 >= args.len) return error.MissingUsername;
            parsed.username = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, args[i], "--password")) {
            if (i + 1 >= args.len) return error.MissingPassword;
            parsed.password = args[i + 1];
            i += 2;
        } else if (std.mem.eql(u8, args[i], "--format")) {
            if (i + 1 >= args.len) return error.MissingFormat;
            parsed.format = parseFormat(args[i + 1]) orelse return error.InvalidFormat;
            i += 2;
        } else {
            break;
        }
    }

    parsed.command_index = i;
    return parsed;
}

fn parseFormat(value: []const u8) ?Format {
    if (std.mem.eql(u8, value, "human")) return .human;
    if (std.mem.eql(u8, value, "json")) return .json;
    return null;
}

pub fn buildDebugGetPath(
    allocator: std.mem.Allocator,
    view: DebugView,
    hash: ?[]const u8,
    rid: ?[]const u8,
) !std.ArrayList(u8) {
    var path = std.ArrayList(u8).empty;
    errdefer path.deinit(allocator);

    switch (view) {
        .peers => {
            const h = hash orelse return error.MissingHash;
            try path.appendSlice(allocator, "/api/v2/sync/torrentPeers?hash=");
            try appendQueryValue(allocator, &path, h);
            try path.appendSlice(allocator, "&rid=");
            try appendQueryValue(allocator, &path, rid orelse "0");
        },
        .conn_diagnostics => {
            const h = hash orelse return error.MissingHash;
            try path.appendSlice(allocator, "/api/v2/torrents/connDiagnostics?hash=");
            try appendQueryValue(allocator, &path, h);
        },
        .trackers => {
            const h = hash orelse return error.MissingHash;
            try path.appendSlice(allocator, "/api/v2/torrents/trackers?hash=");
            try appendQueryValue(allocator, &path, h);
        },
        .properties => {
            const h = hash orelse return error.MissingHash;
            try path.appendSlice(allocator, "/api/v2/torrents/properties?hash=");
            try appendQueryValue(allocator, &path, h);
        },
        .maindata => {
            try path.appendSlice(allocator, "/api/v2/sync/maindata?rid=");
            try appendQueryValue(allocator, &path, rid orelse "0");
        },
    }

    return path;
}

pub fn parseRidOption(args: []const []const u8, start_index: usize) !?[]const u8 {
    var rid: ?[]const u8 = null;
    var i = start_index;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--rid")) {
            if (i + 1 >= args.len) return error.MissingRid;
            rid = args[i + 1];
            i += 1;
        } else {
            return error.UnknownOption;
        }
    }
    return rid;
}

pub fn parseDiagnosticRequest(args: []const []const u8, command_index: usize) !?DiagnosticRequest {
    if (command_index >= args.len) return null;

    const command = args[command_index];
    if (std.mem.eql(u8, command, "peers")) {
        const hash = argsValue(args, command_index + 1) orelse return error.MissingHash;
        return .{
            .view = .peers,
            .hash = hash,
            .rid = try parseRidOption(args, command_index + 2),
        };
    }

    if (std.mem.eql(u8, command, "conn-diagnostics") or
        std.mem.eql(u8, command, "diagnostics") or
        std.mem.eql(u8, command, "conn-diag"))
    {
        const hash = argsValue(args, command_index + 1) orelse return error.MissingHash;
        try rejectTrailingArgs(args, command_index + 2);
        return .{
            .view = .conn_diagnostics,
            .hash = hash,
        };
    }

    if (std.mem.eql(u8, command, "trackers")) {
        const hash = argsValue(args, command_index + 1) orelse return error.MissingHash;
        try rejectTrailingArgs(args, command_index + 2);
        return .{
            .view = .trackers,
            .hash = hash,
        };
    }

    if (std.mem.eql(u8, command, "properties")) {
        const hash = argsValue(args, command_index + 1) orelse return error.MissingHash;
        try rejectTrailingArgs(args, command_index + 2);
        return .{
            .view = .properties,
            .hash = hash,
        };
    }

    if (std.mem.eql(u8, command, "maindata")) {
        return .{
            .view = .maindata,
            .rid = try parseRidOption(args, command_index + 1),
        };
    }

    return null;
}

fn argsValue(args: []const []const u8, index: usize) ?[]const u8 {
    if (index >= args.len) return null;
    if (std.mem.startsWith(u8, args[index], "--")) return null;
    return args[index];
}

fn rejectTrailingArgs(args: []const []const u8, start_index: usize) !void {
    if (start_index < args.len) return error.UnknownOption;
}

fn appendQueryValue(allocator: std.mem.Allocator, path: *std.ArrayList(u8), value: []const u8) !void {
    const hex = "0123456789ABCDEF";
    for (value) |byte| {
        if (isUnreservedQueryByte(byte)) {
            try path.append(allocator, byte);
        } else {
            try path.append(allocator, '%');
            try path.append(allocator, hex[byte >> 4]);
            try path.append(allocator, hex[byte & 0x0f]);
        }
    }
}

fn isUnreservedQueryByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == '.' or byte == '~';
}

test "buildDebugGetPath percent-encodes hash and rid query parameters" {
    var path = try buildDebugGetPath(std.testing.allocator, .peers, "aa bb&cc", "7");
    defer path.deinit(std.testing.allocator);

    try std.testing.expectEqualStrings("/api/v2/sync/torrentPeers?hash=aa%20bb%26cc&rid=7", path.items);
}

test "buildDebugGetPath uses rid zero defaults for sync endpoints" {
    var peers_path = try buildDebugGetPath(std.testing.allocator, .peers, "deadbeef", null);
    defer peers_path.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/api/v2/sync/torrentPeers?hash=deadbeef&rid=0", peers_path.items);

    var maindata_path = try buildDebugGetPath(std.testing.allocator, .maindata, null, null);
    defer maindata_path.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/api/v2/sync/maindata?rid=0", maindata_path.items);
}

test "parseGlobalOptions accepts format before command and preserves command start" {
    const args = [_][]const u8{ "varuna-ctl", "--format", "json", "--username", "alice", "list" };

    const parsed = try parseGlobalOptions(&args, .{
        .username = "admin",
        .password = "adminadmin",
    });

    try std.testing.expectEqual(Format.json, parsed.format);
    try std.testing.expectEqualStrings("alice", parsed.username);
    try std.testing.expectEqualStrings("adminadmin", parsed.password);
    try std.testing.expectEqual(@as(usize, 5), parsed.command_index);
}

test "parseGlobalOptions rejects unknown format value" {
    const args = [_][]const u8{ "varuna-ctl", "--format", "xml", "list" };

    try std.testing.expectError(error.InvalidFormat, parseGlobalOptions(&args, .{
        .username = "admin",
        .password = "adminadmin",
    }));
}

test "parseDiagnosticRequest parses peers rid and builds torrentPeers path" {
    const args = [_][]const u8{ "varuna-ctl", "peers", "aa bb", "--rid", "9" };

    const request = (try parseDiagnosticRequest(&args, 1)).?;
    try std.testing.expectEqual(DebugView.peers, request.view);
    try std.testing.expectEqualStrings("aa bb", request.hash.?);
    try std.testing.expectEqualStrings("9", request.rid.?);

    var path = try buildDebugGetPath(std.testing.allocator, request.view, request.hash, request.rid);
    defer path.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("/api/v2/sync/torrentPeers?hash=aa%20bb&rid=9", path.items);
}

test "parseDiagnosticRequest parses diagnostics aliases" {
    const commands = [_][]const u8{ "conn-diagnostics", "diagnostics", "conn-diag" };
    for (commands) |command| {
        const args = [_][]const u8{ "varuna-ctl", command, "deadbeef" };

        const request = (try parseDiagnosticRequest(&args, 1)).?;
        try std.testing.expectEqual(DebugView.conn_diagnostics, request.view);
        try std.testing.expectEqualStrings("deadbeef", request.hash.?);
        try std.testing.expectEqual(@as(?[]const u8, null), request.rid);

        var path = try buildDebugGetPath(std.testing.allocator, request.view, request.hash, request.rid);
        defer path.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("/api/v2/torrents/connDiagnostics?hash=deadbeef", path.items);
    }
}

test "parseDiagnosticRequest parses trackers properties and maindata" {
    {
        const args = [_][]const u8{ "varuna-ctl", "trackers", "deadbeef" };
        const request = (try parseDiagnosticRequest(&args, 1)).?;
        var path = try buildDebugGetPath(std.testing.allocator, request.view, request.hash, request.rid);
        defer path.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("/api/v2/torrents/trackers?hash=deadbeef", path.items);
    }
    {
        const args = [_][]const u8{ "varuna-ctl", "properties", "deadbeef" };
        const request = (try parseDiagnosticRequest(&args, 1)).?;
        var path = try buildDebugGetPath(std.testing.allocator, request.view, request.hash, request.rid);
        defer path.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("/api/v2/torrents/properties?hash=deadbeef", path.items);
    }
    {
        const args = [_][]const u8{ "varuna-ctl", "maindata", "--rid", "12" };
        const request = (try parseDiagnosticRequest(&args, 1)).?;
        var path = try buildDebugGetPath(std.testing.allocator, request.view, request.hash, request.rid);
        defer path.deinit(std.testing.allocator);
        try std.testing.expectEqualStrings("/api/v2/sync/maindata?rid=12", path.items);
    }
}

test "parseDiagnosticRequest rejects missing hash and unknown options" {
    {
        const args = [_][]const u8{ "varuna-ctl", "peers", "--rid", "1" };
        try std.testing.expectError(error.MissingHash, parseDiagnosticRequest(&args, 1));
    }
    {
        const args = [_][]const u8{ "varuna-ctl", "trackers", "deadbeef", "--rid", "1" };
        try std.testing.expectError(error.UnknownOption, parseDiagnosticRequest(&args, 1));
    }
    {
        const args = [_][]const u8{ "varuna-ctl", "maindata", "--rid" };
        try std.testing.expectError(error.MissingRid, parseDiagnosticRequest(&args, 1));
    }
}

test "parseDiagnosticRequest ignores non diagnostic commands" {
    const args = [_][]const u8{ "varuna-ctl", "list" };

    try std.testing.expectEqual(@as(?DiagnosticRequest, null), try parseDiagnosticRequest(&args, 1));
}
