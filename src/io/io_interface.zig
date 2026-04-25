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

    // Connection lifecycle.
    socket: SocketOp,
    connect: ConnectOp,
    accept: AcceptOp,

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
    socket: anyerror!posix.fd_t,
    connect: anyerror!void,
    accept: anyerror!Accepted,
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
    _backend_state: [backend_state_size]u8 align(backend_state_align) = [_]u8{0} ** backend_state_size,

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
//   pub fn socket   (self: *@This(), op: SocketOp,   c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn connect  (self: *@This(), op: ConnectOp,  c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
//   pub fn accept   (self: *@This(), op: AcceptOp,   c: *Completion, ud: ?*anyopaque, cb: Callback) !void;
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
    const State = packed struct {
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
    // tag must be in both unions.
    for (op_tags) |o| {
        if (std.mem.eql(u8, o.name, "none")) continue;
        var found = false;
        for (res_tags) |r| {
            if (std.mem.eql(u8, o.name, r.name)) {
                found = true;
                break;
            }
        }
        try std.testing.expect(found);
    }
}
