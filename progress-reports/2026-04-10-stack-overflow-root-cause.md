# Stack Overflow Root Cause and Fix

**Date:** 2026-04-10

## Root Cause

The demo_swarm SEGV was a **stack overflow** caused by `findByRecvIdRemote` in `src/net/utp_manager.zig`. GDB disassembly revealed:

```asm
mov $0x2e440f0,%r10d      ; allocate 48,562,416 bytes (~46 MB) on the stack
sub %r10,%rsp             ; rsp -= 46 MB  
test %esp,-0x1000(...)    ; probe stack guard page → SIGSEGV
```

The Zig compiler (debug mode, no optimizations) generated a 46 MB stack frame because:
- `addressEql` took `std.net.Address` by value (128-byte union)
- Called inside a loop iterating 4096 uTP connection slots
- Each iteration materialized two 128-byte Address copies on the stack
- Debug mode doesn't optimize/inline, creating worst-case stack usage

The 32 MB thread stack was insufficient for this function.

## Fix

Changed `addressEql` signature from by-value to by-pointer:
```zig
// Before (128-byte copies per call):
pub fn addressEql(a: std.net.Address, b: std.net.Address) bool

// After (8-byte pointer per call):  
pub fn addressEql(a: *const std.net.Address, b: *const std.net.Address) bool
```

Updated all 8 call sites across dht/, io/, and net/ subsystems.

Also heap-allocated EventLoop in main.zig to further reduce stack pressure.

## Remaining Issue

After the stack overflow fix, both daemons survive MSE handshakes and extension exchange. A separate timing-dependent crash occurs in `checkPeerTimeouts → removePeer → cleanupPeer` when peer handshakes take too long and the timeout fires before the handshake completes. This disappears under GDB (slower execution avoids the timeout race). This is a pre-existing issue unrelated to the io_uring migration.

## Key Code References
- Fix: `src/net/address.zig:6` (addressEql signature)
- Stack overflow site: `src/net/utp_manager.zig:227` (findByRecvIdRemote)
- EventLoop heap allocation: `src/main.zig:69`
