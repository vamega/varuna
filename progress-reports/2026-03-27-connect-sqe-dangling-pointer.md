# Connect SQE Dangling Pointer (EAFNOSUPPORT from garbage sockaddr)

**Date:** 2026-03-27
**Status:** Fixed

## The Problem

The event loop's `addPeer` function created a connect SQE that referenced a stack-local `address` parameter:

```zig
pub fn addPeer(self: *EventLoop, address: std.net.Address) !u16 {
    // ...
    _ = try self.ring.connect(ud, fd, &address.any, address.getOsSockLen());
    //                                 ^^^^^^^^^^^^
    //                                 DANGLING: address is a function parameter on the stack
}
```

io_uring connect SQEs are asynchronous. The kernel reads the `sockaddr` after `addPeer` returns, when the SQE is processed during `submit_and_wait`. By that time, the stack frame is gone and the kernel reads garbage bytes at the `sockaddr` location.

## Symptom

`connect failed res=-97` where errno 97 = `EAFNOSUPPORT` (Address family not supported). The garbage bytes at the `family` field offset happened to not be `AF_INET` (2), so the kernel rejected the connect.

This was intermittent in theory (depends on what's on the stack after `addPeer` returns) but was 100% reproducible in practice because the same stack layout was used every time.

## The Fix

Use the address stored in the peer slot instead of the function parameter:

```zig
peer.* = Peer{ .address = address, ... };  // stored in slot
_ = try self.ring.connect(ud, fd, &peer.address.any, peer.address.getOsSockLen());
//                                 ^^^^^^^^^^^^^^^^^
//                                 STABLE: peer lives in the slot array for the connection's lifetime
```

## Key Learning

**Every pointer passed to an io_uring SQE must remain valid until the corresponding CQE is received.** This is fundamentally different from synchronous I/O where the buffer only needs to live for the syscall duration.

This applies to:
- `sockaddr*` in connect SQEs
- `buffer` pointers in read/write/send/recv SQEs
- `kernel_timespec*` in timeout SQEs (we had this same bug with `submitTimeout` -- fixed by storing the timespec in the EventLoop struct)
- `iovec` arrays in readv/writev SQEs

**Rule of thumb**: Never pass a pointer to a stack-local variable to an io_uring SQE. Always use heap or struct-member storage that outlives the SQE's lifetime.

## Code Reference

Fix in `src/io/event_loop.zig:addPeer` -- line ~190.
