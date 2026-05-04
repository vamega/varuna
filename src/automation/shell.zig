//! Small Zig automation helpers for repository-local scripts.
//!
//! Inspired by TigerBeetle's `src/shell.zig` scripting helper
//! (https://github.com/tigerbeetle/tigerbeetle, Apache-2.0). This is not a
//! copy: Varuna keeps a narrower surface focused on process execution,
//! temporary working directories, and local HTTP-style harnesses.
//!
//! Keep this file independent from Varuna's daemon modules. Automation code is
//! allowed to use blocking stdlib I/O; daemon code is not.

const std = @import("std");

const Shell = @This();

allocator: std.mem.Allocator,
arena: std.heap.ArenaAllocator,
root: []const u8,
env: std.process.EnvMap,

pub const RunResult = struct {
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

pub const RunOptions = struct {
    cwd: ?[]const u8 = null,
    max_output_bytes: usize = 16 * 1024 * 1024,
};

pub fn init(allocator: std.mem.Allocator) !Shell {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();

    const root = try std.fs.cwd().realpathAlloc(arena.allocator(), ".");
    var env = try std.process.getEnvMap(allocator);
    errdefer env.deinit();

    return .{
        .allocator = allocator,
        .arena = arena,
        .root = root,
        .env = env,
    };
}

pub fn deinit(self: *Shell) void {
    self.env.deinit();
    self.arena.deinit();
    self.* = undefined;
}

pub fn fmt(self: *Shell, comptime format: []const u8, args: anytype) ![]const u8 {
    return try std.fmt.allocPrint(self.arena.allocator(), format, args);
}

pub fn path(self: *Shell, parts: []const []const u8) ![]const u8 {
    return try std.fs.path.join(self.arena.allocator(), parts);
}

pub fn envOpt(self: *Shell, name: []const u8) ?[]const u8 {
    return self.env.get(name);
}

pub fn envInt(self: *Shell, comptime T: type, name: []const u8, default: T) !T {
    const raw = self.envOpt(name) orelse return default;
    return try std.fmt.parseInt(T, raw, 10);
}

pub fn envString(self: *Shell, name: []const u8, default: []const u8) []const u8 {
    return self.envOpt(name) orelse default;
}

pub fn makePath(_: *Shell, path_name: []const u8) !void {
    try std.fs.cwd().makePath(path_name);
}

pub fn removeTree(_: *Shell, path_name: []const u8) void {
    std.fs.cwd().deleteTree(path_name) catch {};
}

pub fn createTempDir(self: *Shell, prefix: []const u8) ![]const u8 {
    const now = std.time.nanoTimestamp();
    const path_name = try self.fmt("/tmp/{s}-{d}", .{ prefix, now });
    try std.fs.cwd().makePath(path_name);
    return path_name;
}

pub fn writeFile(_: *Shell, path_name: []const u8, bytes: []const u8) !void {
    var file = try std.fs.cwd().createFile(path_name, .{ .truncate = true });
    defer file.close();
    try file.writeAll(bytes);
}

pub fn appendFile(_: *Shell, path_name: []const u8, bytes: []const u8) !void {
    var file = try std.fs.cwd().openFile(path_name, .{ .mode = .write_only });
    defer file.close();
    try file.seekFromEnd(0);
    try file.writeAll(bytes);
}

pub fn fileExists(_: *Shell, path_name: []const u8) bool {
    std.fs.cwd().access(path_name, .{}) catch return false;
    return true;
}

pub fn exec(self: *Shell, argv: []const []const u8, options: RunOptions) !void {
    const result = try self.execCapture(argv, options);
    defer result.deinit(self.allocator);
}

pub fn execCapture(self: *Shell, argv: []const []const u8, options: RunOptions) !RunResult {
    printCommand(argv);
    const result = try std.process.Child.run(.{
        .allocator = self.allocator,
        .argv = argv,
        .cwd = options.cwd,
        .env_map = &self.env,
        .max_output_bytes = options.max_output_bytes,
    });
    errdefer {
        self.allocator.free(result.stdout);
        self.allocator.free(result.stderr);
    }

    try checkTerm(argv, result.term, result.stderr);
    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

pub fn spawnLogged(
    self: *Shell,
    argv: []const []const u8,
    cwd: ?[]const u8,
    stdout_log_path: []const u8,
    stderr_log_path: []const u8,
) !ManagedProcess {
    printCommand(argv);
    const argv_owned = try self.arena.allocator().dupe([]const u8, argv);
    var child = std.process.Child.init(argv_owned, self.allocator);
    child.cwd = cwd;
    child.env_map = &self.env;
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;

    try child.spawn();
    errdefer _ = child.kill() catch {};

    const stdout_path = try self.arena.allocator().dupe(u8, stdout_log_path);
    const stderr_path = try self.arena.allocator().dupe(u8, stderr_log_path);

    const stdout_file = child.stdout.?;
    const stderr_file = child.stderr.?;
    child.stdout = null;
    child.stderr = null;

    const stdout_thread = try std.Thread.spawn(.{}, drainToFile, .{ stdout_file, stdout_path });
    errdefer stdout_thread.join();
    const stderr_thread = try std.Thread.spawn(.{}, drainToFile, .{ stderr_file, stderr_path });
    errdefer stderr_thread.join();

    return .{
        .child = child,
        .stdout_thread = stdout_thread,
        .stderr_thread = stderr_thread,
        .alive = true,
        .joined = false,
    };
}

pub fn waitForTcp(self: *Shell, host: []const u8, port: u16, timeout_ms: u64) !void {
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    while (std.time.milliTimestamp() < deadline) {
        if (std.net.tcpConnectToHost(self.allocator, host, port)) |stream| {
            stream.close();
            return;
        } else |_| {
            std.Thread.sleep(50 * std.time.ns_per_ms);
        }
    }
    return error.Timeout;
}

pub fn nowSeconds() f64 {
    return @as(f64, @floatFromInt(std.time.nanoTimestamp())) / @as(f64, @floatFromInt(std.time.ns_per_s));
}

pub const ManagedProcess = struct {
    child: std.process.Child,
    stdout_thread: std.Thread,
    stderr_thread: std.Thread,
    alive: bool,
    joined: bool,

    pub fn stop(self: *ManagedProcess) void {
        if (self.alive) {
            _ = self.child.kill() catch {};
            self.alive = false;
        }
        if (!self.joined) {
            self.stdout_thread.join();
            self.stderr_thread.join();
            self.joined = true;
        }
    }

    pub fn wait(self: *ManagedProcess) !std.process.Child.Term {
        const term = try self.child.wait();
        self.alive = false;
        if (!self.joined) {
            self.stdout_thread.join();
            self.stderr_thread.join();
            self.joined = true;
        }
        return term;
    }
};

fn drainToFile(input_file: std.fs.File, output_path: []const u8) void {
    var input = input_file;
    defer input.close();

    var output = std.fs.cwd().createFile(output_path, .{ .truncate = true }) catch return;
    defer output.close();

    var buf: [8192]u8 = undefined;
    while (true) {
        const n = input.read(&buf) catch return;
        if (n == 0) return;
        output.writeAll(buf[0..n]) catch return;
    }
}

fn printCommand(argv: []const []const u8) void {
    std.debug.print("$", .{});
    for (argv) |arg| {
        std.debug.print(" {s}", .{arg});
    }
    std.debug.print("\n", .{});
}

fn checkTerm(argv: []const []const u8, term: std.process.Child.Term, stderr: []const u8) !void {
    switch (term) {
        .Exited => |code| {
            if (code == 0) return;
            std.debug.print("command exited with code {d}: {s}\n{s}\n", .{ code, argv[0], stderr });
            return error.CommandFailed;
        },
        .Signal => |signal| {
            std.debug.print("command killed by signal {d}: {s}\n{s}\n", .{ signal, argv[0], stderr });
            return error.CommandFailed;
        },
        .Stopped => |signal| {
            std.debug.print("command stopped by signal {d}: {s}\n{s}\n", .{ signal, argv[0], stderr });
            return error.CommandFailed;
        },
        .Unknown => |status| {
            std.debug.print("command ended with unknown status {d}: {s}\n{s}\n", .{ status, argv[0], stderr });
            return error.CommandFailed;
        },
    }
}
