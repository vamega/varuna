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
