//! IO Abstraction — public contract.
//!
//! The EventLoop is generic over its IO backend. Production code uses
//! `RealIO` (io_uring). Test code uses `SimIO` (in-process delivery under a
//! seeded clock). Both backends provide the same set of declarations and
//! methods listed below.
//!
//! Design choices (locked in 2026-04-25):
//!
//! 1. **Comptime duck typing, not vtables.** The `EventLoop` is parameterised
//!    on a comptime `IO: type`. Each backend is a distinct type with the same
//!    method names. There is no runtime dispatch.
//!
//! 2. **Caller-owned completions.** A `Completion` is a struct that the
//!    caller embeds in a longer-lived holder (e.g. a `Peer` slot). The
//!    backend writes results into the completion and invokes the callback.
//!    The backend never allocates a completion.
//!
//! 3. **Single concrete `Completion` type, opaque backend state.** Each
//!    backend stores its own private state in a fixed byte buffer at the end
//!    of the completion (`_backend_state`). This avoids propagating `Peer(IO)`
//!    generics through the codebase. Backends `comptime assert` that their
//!    state fits.
//!
//! 4. **One callback signature.** The callback receives the userdata, the
//!    completion pointer, and a `Result` tagged union (one variant per op).
//!    The callback returns `CallbackAction` (`.disarm` or `.rearm`).
//!
//! 5. **userdata in the completion.** A completion can only be in flight for
//!    one operation at a time — so a single userdata field is sufficient.
//!
//! 6. **`anyerror` on the result.** Each operation returns `anyerror!T`
//!    rather than a typed error union. This keeps the interface flat across
//!    backends; the kernel can return any errno, and the simulator can
//!    inject any error tag we choose. Callers that care about specific
//!    errors can switch on them.
//!
//! See `docs/io-abstraction-plan.md` for the full design rationale.

const std = @import("std");
const builtin = @import("builtin");
const posix = std.posix;
const linux = std.os.linux;

// ── Backend state size ────────────────────────────────────
//
// Each backend stores its private state in `Completion._backend_state`.
// The size must accommodate the largest backend state across all backends
// linked into the binary. RealIO needs ~32 bytes; SimIO needs ~64 bytes for
// the heap linkage and seeded delivery deadline.
//
// Backends `comptime assert` their state fits at startup. To extend, raise
// this constant and rebuild — no other changes are required.

pub const backend_state_size: usize = 64;
pub const backend_state_align: usize = @alignOf(*usize);

// ── Operation parameters ──────────────────────────────────
//
// `Operation` carries the parameters needed to (re)submit the call. The
// backend reads these on submit; the caller must keep referenced buffers
// valid until the callback fires. `none` is the default for fresh
// completions and after `disarm`.

pub const Operation = union(enum) {
    none: void,

    // Stream I/O (peer wire, RPC, HTTP tracker).
    recv: RecvOp,
    send: SendOp,

    // Datagram I/O (uTP, UDP tracker).
    recvmsg: RecvmsgOp,
    sendmsg: SendmsgOp,

    // Disk I/O.
    read: ReadOp,
    write: WriteOp,
    fsync: FsyncOp,
    close: CloseOp,
    fallocate: FallocateOp,
    truncate: TruncateOp,
    openat: OpenAtOp,
    mkdirat: MkdirAtOp,
    renameat: RenameAtOp,
    unlinkat: UnlinkAtOp,
    statx: StatxOp,
    getdents: GetdentsOp,
    open_copy_file_session: OpenCopyFileSessionOp,
    copy_file_chunk: CopyFileChunkOp,
    close_copy_file_session: CloseCopyFileSessionOp,
    fchown: FchownOp,
    fchmod: FchmodOp,

    // Connection lifecycle.
    socket: SocketOp,
    connect: ConnectOp,
    accept: AcceptOp,
    bind: BindOp,
    listen: ListenOp,
    setsockopt: SetsockoptOp,

    // Timers and readiness.
    timeout: TimeoutOp,
    poll: PollOp,

    // Cancellation by completion pointer.
    cancel: CancelOp,
};

pub const RecvOp = struct {
    fd: posix.fd_t,
    buf: []u8,
    flags: u32 = 0,
};

pub const SendOp = struct {
    fd: posix.fd_t,
    buf: []const u8,
    flags: u32 = 0,
};

pub const RecvmsgOp = struct {
    fd: posix.fd_t,
    msg: *posix.msghdr,
    flags: u32 = 0,
};

pub const SendmsgOp = struct {
    fd: posix.fd_t,
    msg: *const posix.msghdr_const,
    flags: u32 = 0,
};

pub const ReadOp = struct {
    fd: posix.fd_t,
    buf: []u8,
    offset: u64,
};

pub const WriteOp = struct {
    fd: posix.fd_t,
    buf: []const u8,
    offset: u64,
};

pub const FsyncOp = struct {
    fd: posix.fd_t,
    /// Mirrors IORING_FSYNC_DATASYNC. When set, sync data only (skip metadata).
    datasync: bool = true,
};

/// `close(2)` for fds returned by contract operations such as `openat`.
/// There is no Linux `closeat(2)` syscall: fd-relative lifecycle is modeled
/// by closing the fd produced by the earlier `openat` operation.
pub const CloseOp = struct {
    fd: posix.fd_t,
};

pub const FallocateOp = struct {
    fd: posix.fd_t,
    /// `mode` argument to `fallocate(2)`. The default `0` means "extend the
    /// file to `offset+len`, allocating any newly-needed blocks". Other
    /// modes (`FALLOC_FL_KEEP_SIZE`, `FALLOC_FL_PUNCH_HOLE`, etc.) are
    /// passed through unchanged.
    mode: i32 = 0,
    offset: u64,
    len: u64,
};

pub const TruncateOp = struct {
    fd: posix.fd_t,
    /// New file length in bytes. `ftruncate(2)` either grows the file to
    /// `length` (filling with zeros / sparse blocks) or shrinks it,
    /// discarding bytes past `length`.
    ///
    /// Used by `PieceStore.init` as the filesystem-portability fallback
    /// when fallocate returns `error.OperationNotSupported` (tmpfs <5.10,
    /// FAT32, certain FUSE FSes). On those filesystems we still want
    /// every file extended to its torrent-declared length so that
    /// per-piece writes against `offset+len` past the original EOF
    /// don't surprise the kernel.
    length: u64,
};

/// `openat(2)` — fd-relative open/create for directory-state machines.
///
/// `path` is sentinel-terminated because RealIO's async io_uring path
/// passes the pointer directly to the kernel; callers must keep the
/// buffer alive until the completion fires. String literals satisfy this
/// naturally. Sync fallback backends pass the same slice to `posix.openat`.
pub const OpenAtOp = struct {
    dir_fd: posix.fd_t,
    path: [:0]const u8,
    flags: posix.O,
    mode: posix.mode_t = 0,
};

/// `mkdirat(2)` — fd-relative directory creation. Same path lifetime
/// rule as `OpenAtOp`.
pub const MkdirAtOp = struct {
    dir_fd: posix.fd_t,
    path: [:0]const u8,
    mode: posix.mode_t,
};

/// `renameat2(2)` / `renameat(2)` — fd-relative rename. `flags = 0`
/// maps to POSIX `renameat`; nonzero flags are Linux-specific and are
/// supported only where the backend can issue `renameat2` semantics.
pub const RenameAtOp = struct {
    old_dir_fd: posix.fd_t,
    old_path: [:0]const u8,
    new_dir_fd: posix.fd_t,
    new_path: [:0]const u8,
    flags: u32 = 0,
};

/// `unlinkat(2)` — fd-relative file or directory removal. Pass
/// `posix.AT.REMOVEDIR` in `flags` for directories.
pub const UnlinkAtOp = struct {
    dir_fd: posix.fd_t,
    path: [:0]const u8,
    flags: u32 = 0,
};

/// `statx(2)` — fd-relative metadata lookup.
///
/// `path` and `buf` are caller-owned and must stay alive until the
/// completion fires. `flags` and `mask` map directly to the Linux statx
/// arguments (`linux.AT.*`, `linux.STATX_*`). The result variant is void on
/// success because the kernel fills `buf` asynchronously.
pub const StatxOp = struct {
    dir_fd: posix.fd_t,
    path: [:0]const u8,
    flags: u32 = 0,
    mask: u32 = linux.STATX_BASIC_STATS,
    buf: *linux.Statx,
};

/// `getdents64(2)`-shaped directory enumeration.
///
/// The buffer receives packed `linux.dirent64` records and the result is the
/// byte count written, or `0` at end-of-directory. RealIO uses the Linux
/// syscall directly because there is no stable io_uring getdents op exposed
/// by Zig 0.15.2; simulator and portability backends synthesize the same
/// Linux-shaped records so callers can share one parser.
pub const GetdentsOp = struct {
    fd: posix.fd_t,
    buf: []align(@alignOf(linux.dirent64)) u8,
};

pub const copy_file_session_state_size: usize = 128;
pub const copy_file_session_state_align: usize = @alignOf(*usize);

/// Opaque caller-owned state for backend-specific file-copy resources.
///
/// Callers own lifetime and sequencing through
/// `open_copy_file_session` / `copy_file_chunk` /
/// `close_copy_file_session`; backends own the contents. RealIO stores
/// pipe fds and splice state here, while backends that copy on a file
/// worker may store only a small open/closed state. At most one
/// operation may be in flight for a session at a time.
pub const CopyFileSession = struct {
    _backend_state: [copy_file_session_state_size]u8 align(copy_file_session_state_align) = @as([copy_file_session_state_size]u8, @splat(0)),

    pub fn backendStateAs(self: *CopyFileSession, comptime State: type) *State {
        comptime {
            std.debug.assert(@sizeOf(State) <= copy_file_session_state_size);
            std.debug.assert(@alignOf(State) <= copy_file_session_state_align);
        }
        return @ptrCast(@alignCast(&self._backend_state));
    }
};

pub const OpenCopyFileSessionOp = struct {
    session: *CopyFileSession,
};

/// Backend-appropriate file-to-file copy of at most `len` bytes.
///
/// This is deliberately semantic rather than syscall-shaped. The source
/// and destination must be regular-file fds, offsets are explicit, and
/// `len` must be nonzero. A successful result is the number of bytes
/// copied into the destination; `0` means source EOF. Backends must not
/// block the event-loop thread while moving file contents.
pub const CopyFileChunkOp = struct {
    session: *CopyFileSession,
    src_fd: posix.fd_t,
    src_offset: u64,
    dst_fd: posix.fd_t,
    dst_offset: u64,
    len: usize,
};

pub const CloseCopyFileSessionOp = struct {
    session: *CopyFileSession,
};

pub const FchownOp = struct {
    fd: posix.fd_t,
    uid: u32,
    gid: u32,
};

pub const FchmodOp = struct {
    fd: posix.fd_t,
    mode: posix.mode_t,
};

pub const SocketOp = struct {
    domain: u32,
    sock_type: u32,
    protocol: u32,
};

pub const ConnectOp = struct {
    fd: posix.fd_t,
    addr: std.net.Address,
    /// Optional deadline. If set, the backend chains a `link_timeout` so the
    /// connect completes with `error.ConnectionTimedOut` if the deadline
    /// passes first. SimIO models the same behaviour by checking the
    /// deadline before delivering.
    deadline_ns: ?u64 = null,
};

pub const AcceptOp = struct {
    fd: posix.fd_t,
    /// When true, the backend submits multishot accept (RealIO) or
    /// re-arms automatically (SimIO). The callback's `.rearm` return is
    /// honoured for non-multishot accepts.
    multishot: bool = false,
};

pub const BindOp = struct {
    fd: posix.fd_t,
    /// The local address the socket should be bound to. The backend
    /// reads `addr.any` plus `addr.getOsSockLen()` at submission time;
    /// the caller must keep the address value alive at least until the
    /// callback fires (a stack copy in the Op struct is fine — it lives
    /// inside `Completion.op`).
    addr: std.net.Address,
};

pub const ListenOp = struct {
    fd: posix.fd_t,
    backlog: u31 = 128,
};

pub const SetsockoptOp = struct {
    fd: posix.fd_t,
    /// `level` argument to `setsockopt(2)` (e.g. `SOL_SOCKET`,
    /// `IPPROTO_TCP`, `IPPROTO_IPV6`).
    level: u32,
    /// `optname` argument (e.g. `SO_REUSEADDR`, `TCP_NODELAY`,
    /// `IPV6_V6ONLY`, `SO_BINDTODEVICE`).
    optname: u32,
    /// Option value bytes. Caller-owned, must outlive the SQE submit
    /// (RealIO async path: the kernel reads the buffer asynchronously,
    /// so the slice must remain valid until the callback fires).
    optval: []const u8,
};

pub const TimeoutOp = struct {
    ns: u64,
};

pub const PollOp = struct {
    fd: posix.fd_t,
    /// POLL_IN, POLL_OUT, etc. Bitmask of `linux.POLL.*`.
    events: u32,
};

pub const CancelOp = struct {
    /// The completion to cancel. Backend matches it to an in-flight
    /// operation by completion pointer. Cancelling a not-in-flight
    /// completion is a no-op (delivers `error.OperationNotFound`).
    target: *Completion,
};

// ── Operation results ─────────────────────────────────────
//
// `Result` is a tagged union with one variant per `Operation`. The variant
// active in `Result` matches the variant submitted in `Operation`.

pub const Accepted = struct {
    fd: posix.fd_t,
    addr: std.net.Address,
};

pub const Result = union(enum) {
    recv: anyerror!usize,
    send: anyerror!usize,
    recvmsg: anyerror!usize,
    sendmsg: anyerror!usize,
    read: anyerror!usize,
    write: anyerror!usize,
    fsync: anyerror!void,
    close: anyerror!void,
    fallocate: anyerror!void,
    truncate: anyerror!void,
    openat: anyerror!posix.fd_t,
    mkdirat: anyerror!void,
    renameat: anyerror!void,
    unlinkat: anyerror!void,
    statx: anyerror!void,
    getdents: anyerror!usize,
    open_copy_file_session: anyerror!void,
    /// Bytes copied into the destination. `0` means EOF on the source side.
    copy_file_chunk: anyerror!usize,
    close_copy_file_session: anyerror!void,
    fchown: anyerror!void,
    fchmod: anyerror!void,
    socket: anyerror!posix.fd_t,
    connect: anyerror!void,
    accept: anyerror!Accepted,
    bind: anyerror!void,
    listen: anyerror!void,
    setsockopt: anyerror!void,
    timeout: anyerror!void,
    /// `revents` bitmask returned for poll completions.
    poll: anyerror!u32,
    cancel: anyerror!void,
};

// ── Callback contract ─────────────────────────────────────
//
// The callback signature is the same for every backend and every
// operation. Callbacks must not block, must not allocate, must not recurse,
// and must not free their own completion before returning.
//
// `userdata` is the value the caller stored on the completion (typically a
// `*EventLoop` or a `*Peer`). The callback dereferences it as needed and
// reaches the IO backend through whatever owner context it has.
//
// `completion` is the same pointer the caller submitted. After the callback
// returns `.disarm`, the backend will not touch the completion again until
// the caller re-submits it.
//
// `result` is a tagged union whose active variant matches the operation
// that was submitted.
//
// **In-flight clearing.** Backends clear `in_flight` on the completion
// *before* invoking the callback for the final CQE / delivery (multishot
// keeps it set until `IORING_CQE_F_MORE` clears). This means a callback
// may submit a new op on the same completion freely — for example the
// natural "header → body, then body → next header" recv pattern, where
// each chunk's callback re-submits a recv with a different buffer slice.
//
// The one rule: a callback may **either** submit a new op **or** return
// `.rearm` — not both. `.rearm` re-submits whatever is currently in
// `c.op`; if you've overwritten that during the callback (by submitting a
// new op), you must return `.disarm`. Returning `.rearm` after the
// callback already pushed a new submission would double-arm the
// completion and corrupt the backend's bookkeeping.

pub const CallbackAction = enum { disarm, rearm };

pub const Callback = *const fn (
    userdata: ?*anyopaque,
    completion: *Completion,
    result: Result,
) CallbackAction;

// ── Completion struct ─────────────────────────────────────
//
// `Completion` is the unit of submission and the unit of completion. The
// caller declares one (typically embedded in a `Peer` or `EventLoop` field),
// fills `op`, `userdata`, and `callback`, and passes it to the backend.
//
// The backend is responsible for `next` (intrusive queue linkage while in
// flight) and `_backend_state` (private bookkeeping). Callers should treat
// those as opaque.

pub const Completion = struct {
    op: Operation = .none,
    userdata: ?*anyopaque = null,
    callback: ?Callback = null,

    /// Intrusive queue linkage. The backend uses this to thread the
    /// completion onto its in-flight or pending lists. Reset to null when
    /// the completion is not in flight.
    next: ?*Completion = null,

    /// Opaque per-backend state. The backend casts the address of this
    /// field to its own state type. Sized to fit the largest backend state.
    /// Zero-initialised so that backends can safely read flags like
    /// `in_flight` on a fresh Completion without observing 0xaa-pattern
    /// debug fill.
    _backend_state: [backend_state_size]u8 align(backend_state_align) = @as([backend_state_size]u8, @splat(0)),

    /// Fluent helper: arm a completion in one call.
    pub fn arm(
        self: *Completion,
        op: Operation,
        userdata: ?*anyopaque,
        callback: Callback,
    ) void {
        self.op = op;
        self.userdata = userdata;
        self.callback = callback;
        self.next = null;
    }

    /// Cast the opaque backend state to the backend's concrete state type.
    /// Each backend uses this to read/write its private bookkeeping.
    pub fn backendStateAs(self: *Completion, comptime State: type) *State {
        comptime {
            std.debug.assert(@sizeOf(State) <= backend_state_size);
            std.debug.assert(@alignOf(State) <= backend_state_align);
        }
        return @ptrCast(@alignCast(&self._backend_state));
    }
};

/// Return a name slice from one packed `linux.dirent64` record.
pub fn direntName(entry: *align(1) const linux.dirent64) []const u8 {
    return std.mem.sliceTo(@as([*:0]const u8, @ptrCast(&entry.name)), 0);
}

/// Append one Linux-shaped dirent64 record to `buf`.
///
/// Returns the new byte offset, or null when the record does not fit.
pub fn appendDirent64(
    buf: []align(@alignOf(linux.dirent64)) u8,
    offset: usize,
    ino: u64,
    next_off: u64,
    entry_type: u8,
    name: []const u8,
) ?usize {
    if (name.len == 0) return null;
    const min_len = @offsetOf(linux.dirent64, "name") + name.len + 1;
    const reclen_usize = std.mem.alignForward(usize, min_len, @alignOf(linux.dirent64));
    if (reclen_usize > std.math.maxInt(u16)) return null;
    if (offset + reclen_usize > buf.len) return null;

    const entry: *align(1) linux.dirent64 = @ptrCast(&buf[offset]);
    entry.ino = ino;
    entry.off = next_off;
    entry.reclen = @intCast(reclen_usize);
    entry.type = entry_type;
    const name_ptr: [*]u8 = @ptrCast(&entry.name);
    @memcpy(name_ptr[0..name.len], name);
    name_ptr[name.len] = 0;
    @memset(buf[offset + min_len .. offset + reclen_usize], 0);
    return offset + reclen_usize;
}

/// Shared errno mapping for Linux syscall-shaped fallback paths in IO
/// backends.
pub fn linuxErrnoToError(e: linux.E) anyerror {
    return switch (e) {
        .SUCCESS => unreachable,
        .CONNREFUSED => error.ConnectionRefused,
        .CONNRESET => error.ConnectionResetByPeer,
        .NOTCONN => error.SocketNotConnected,
        .NETUNREACH => error.NetworkUnreachable,
        .HOSTUNREACH => error.HostUnreachable,
        .TIMEDOUT => error.ConnectionTimedOut,
        .PIPE => error.BrokenPipe,
        .CONNABORTED => error.ConnectionAborted,
        .CANCELED => error.OperationCanceled,
        .NOENT => error.FileNotFound,
        .EXIST => error.PathAlreadyExists,
        .NOTDIR => error.NotDir,
        .ALREADY => error.AlreadyCompleted,
        .ADDRINUSE => error.AddressInUse,
        .ADDRNOTAVAIL => error.AddressNotAvailable,
        .AFNOSUPPORT => error.AddressFamilyNotSupported,
        .DESTADDRREQ => error.DestinationAddressRequired,
        .AGAIN => error.WouldBlock,
        .BADF => error.BadFileDescriptor,
        .INTR => error.Interrupted,
        .INVAL => error.InvalidArgument,
        .IO => error.InputOutput,
        .NOSPC => error.NoSpaceLeft,
        .NOSYS => error.OperationNotSupported,
        .XDEV => error.RenameAcrossMountPoints,
        .ISDIR => error.IsDir,
        .MFILE => error.ProcessFdQuotaExceeded,
        .NFILE => error.SystemFdQuotaExceeded,
        else => posix.unexpectedErrno(e),
    };
}

comptime {
    // Catch accidental size regressions in the public ABI.
    std.debug.assert(@alignOf(Completion) >= backend_state_align);
}

// ── Backend method contract (documentation only) ──────────
//
// Every IO backend provides:
//
//   pub const Completion = io_interface.Completion;
//   pub const Operation = io_interface.Operation;
//   pub const Result = io_interface.Result;
//   pub const Callback = io_interface.Callback;
//   pub const CallbackAction = io_interface.CallbackAction;
//
//   pub fn init(...) !@This();
//   pub fn deinit(self: *@This()) void;
//   pub fn tick(self: *@This()) !void;
//
// Submission methods. Each method records the requested operation in the
// completion (overwriting `c.op`), arms `c.userdata` and `c.callback`, and
// hands the completion to the backend. The completion must remain valid
// until the callback fires with `.disarm`.
//
//   pub fn recv     (self: *@This(), op: RecvOp,     c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn send     (self: *@This(), op: SendOp,     c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn recvmsg  (self: *@This(), op: RecvmsgOp,  c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn sendmsg  (self: *@This(), op: SendmsgOp,  c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn read     (self: *@This(), op: ReadOp,     c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn write    (self: *@This(), op: WriteOp,    c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn fsync    (self: *@This(), op: FsyncOp,    c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn close    (self: *@This(), op: CloseOp,    c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn fallocate(self: *@This(), op: FallocateOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn truncate (self: *@This(), op: TruncateOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn openat   (self: *@This(), op: OpenAtOp,   c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn mkdirat  (self: *@This(), op: MkdirAtOp,  c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn renameat (self: *@This(), op: RenameAtOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn unlinkat (self: *@This(), op: UnlinkAtOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn statx    (self: *@This(), op: StatxOp,    c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn getdents (self: *@This(), op: GetdentsOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn open_copy_file_session (self: *@This(), op: OpenCopyFileSessionOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn copy_file_chunk        (self: *@This(), op: CopyFileChunkOp,        c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn close_copy_file_session(self: *@This(), op: CloseCopyFileSessionOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn fchown   (self: *@This(), op: FchownOp,   c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn fchmod   (self: *@This(), op: FchmodOp,   c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn socket   (self: *@This(), op: SocketOp,   c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn connect  (self: *@This(), op: ConnectOp,  c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn accept   (self: *@This(), op: AcceptOp,   c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn bind     (self: *@This(), op: BindOp,     c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn listen   (self: *@This(), op: ListenOp,   c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn setsockopt(self: *@This(), op: SetsockoptOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn timeout  (self: *@This(), op: TimeoutOp,  c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn poll     (self: *@This(), op: PollOp,     c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//
// Cancellation. `cancel` does not deliver via `c` itself — it tells the
// backend to abort the operation referenced by `op.target`. The cancelled
// op's callback fires with the appropriate cancel error.
//
//   pub fn cancel(self: *@This(), op: CancelOp, c: *Completion, ud: ?*anyopaque, cb: Callback) !void;

// ── Tests ─────────────────────────────────────────────────

test "Completion size and alignment are reasonable" {
    // Sanity check: a completion is small enough to embed liberally.
    try std.testing.expect(@sizeOf(Completion) <= 256);
    try std.testing.expect(@alignOf(Completion) >= @alignOf(*usize));
}

test "io_interface exposes only async startup operations" {
    const Self = @This();
    try std.testing.expect(!@hasDecl(Self, "socketBlocking"));
    try std.testing.expect(!@hasDecl(Self, "bindBlocking"));
    try std.testing.expect(!@hasDecl(Self, "listenBlocking"));
    try std.testing.expect(!@hasDecl(Self, "setsockoptBlocking"));
    try std.testing.expect(!@hasDecl(Self, "bindDeviceBlocking"));
}

test "Completion.arm fills the public fields" {
    var c = Completion{};
    const buf: [8]u8 = undefined;
    const cb: Callback = struct {
        fn cb(_: ?*anyopaque, _: *Completion, _: Result) CallbackAction {
            return .disarm;
        }
    }.cb;

    c.arm(.{ .recv = .{ .fd = 7, .buf = @constCast(&buf) } }, null, cb);
    try std.testing.expectEqual(@as(?*anyopaque, null), c.userdata);
    try std.testing.expect(c.callback != null);
    try std.testing.expect(c.next == null);
    switch (c.op) {
        .recv => |r| {
            try std.testing.expectEqual(@as(posix.fd_t, 7), r.fd);
            try std.testing.expectEqual(@as(usize, 8), r.buf.len);
        },
        else => try std.testing.expect(false),
    }
}

test "Completion.backendStateAs round-trips through opaque storage" {
    // Use a regular (non-packed) struct so alignment stays within
    // `backend_state_align`. A `packed` struct of u32+u64+bool ends up with a
    // u104/u128 backing integer whose alignment exceeds the contract.
    const State = struct {
        seq: u32,
        deadline_ns: u64,
        in_flight: bool,
    };
    var c = Completion{};
    const s = c.backendStateAs(State);
    s.* = .{ .seq = 42, .deadline_ns = 1_000_000, .in_flight = true };

    const s2 = c.backendStateAs(State);
    try std.testing.expectEqual(@as(u32, 42), s2.seq);
    try std.testing.expectEqual(@as(u64, 1_000_000), s2.deadline_ns);
    try std.testing.expect(s2.in_flight);
}

test "Operation tag and Result tag are kept in lockstep" {
    // If a new operation is added without a matching Result variant the
    // dispatch contract breaks silently. The next assertion fails to compile
    // on tag-mismatch and forces both unions to evolve together.
    const op_tags = std.meta.fields(@typeInfo(Operation).@"union".tag_type.?);
    const res_tags = std.meta.fields(@typeInfo(Result).@"union".tag_type.?);

    // `Operation` has a `none` variant that `Result` does not — every other
    // tag must be in both unions. `inline for` is required because
    // `EnumField.value: comptime_int` makes the slice comptime-only.
    inline for (op_tags) |o| {
        if (!std.mem.eql(u8, o.name, "none")) {
            var found = false;
            inline for (res_tags) |r| {
                if (std.mem.eql(u8, o.name, r.name)) {
                    found = true;
                }
            }
            try std.testing.expect(found);
        }
    }
}
