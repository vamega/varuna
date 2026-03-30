/// Minimal SQLite3 bindings for resume state persistence.
/// Links against system libsqlite3. Install libsqlite3-dev for headers,
/// or use these direct function declarations.
const std = @import("std");

pub const SQLITE_OK = 0;
pub const SQLITE_ROW = 100;
pub const SQLITE_DONE = 101;
pub const SQLITE_OPEN_READWRITE = 0x00000002;
pub const SQLITE_OPEN_CREATE = 0x00000004;
pub const SQLITE_OPEN_FULLMUTEX = 0x00010000;

pub const Db = opaque {};
pub const Stmt = opaque {};

pub extern "sqlite3" fn sqlite3_open_v2(
    filename: [*:0]const u8,
    ppDb: *?*Db,
    flags: c_int,
    zVfs: ?[*:0]const u8,
) c_int;

pub extern "sqlite3" fn sqlite3_close(db: *Db) c_int;

pub extern "sqlite3" fn sqlite3_exec(
    db: *Db,
    sql: [*:0]const u8,
    callback: ?*const fn (?*anyopaque, c_int, [*c][*c]u8, [*c][*c]u8) callconv(.c) c_int,
    arg: ?*anyopaque,
    errmsg: ?*?[*:0]u8,
) c_int;

pub extern "sqlite3" fn sqlite3_prepare_v2(
    db: *Db,
    sql: [*:0]const u8,
    nByte: c_int,
    ppStmt: *?*Stmt,
    pzTail: ?*?[*:0]const u8,
) c_int;

pub extern "sqlite3" fn sqlite3_step(stmt: *Stmt) c_int;
pub extern "sqlite3" fn sqlite3_finalize(stmt: *Stmt) c_int;
pub extern "sqlite3" fn sqlite3_reset(stmt: *Stmt) c_int;

pub extern "sqlite3" fn sqlite3_bind_blob(
    stmt: *Stmt,
    col: c_int,
    value: [*]const u8,
    n: c_int,
    destructor: ?*const fn (?*anyopaque) callconv(.c) void,
) c_int;

pub extern "sqlite3" fn sqlite3_bind_int(stmt: *Stmt, col: c_int, value: c_int) c_int;
pub extern "sqlite3" fn sqlite3_bind_int64(stmt: *Stmt, col: c_int, value: i64) c_int;

pub extern "sqlite3" fn sqlite3_column_int(stmt: *Stmt, col: c_int) c_int;
pub extern "sqlite3" fn sqlite3_column_int64(stmt: *Stmt, col: c_int) i64;
pub extern "sqlite3" fn sqlite3_bind_text(
    stmt: *Stmt,
    col: c_int,
    value: [*]const u8,
    n: c_int,
    destructor: ?*const fn (?*anyopaque) callconv(.c) void,
) c_int;

pub extern "sqlite3" fn sqlite3_column_blob(stmt: *Stmt, col: c_int) ?[*]const u8;
pub extern "sqlite3" fn sqlite3_column_bytes(stmt: *Stmt, col: c_int) c_int;
pub extern "sqlite3" fn sqlite3_column_text(stmt: *Stmt, col: c_int) ?[*:0]const u8;

pub extern "sqlite3" fn sqlite3_errmsg(db: *Db) [*:0]const u8;
pub extern "sqlite3" fn sqlite3_free(ptr: ?*anyopaque) void;

pub const SQLITE_TRANSIENT: ?*const fn (?*anyopaque) callconv(.c) void = @ptrFromInt(@as(usize, std.math.maxInt(usize)));
