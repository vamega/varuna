//! Re-export of the process-wide `Clock` abstraction. The canonical
//! definition lives in `src/runtime/clock.zig`; we keep a shim here so
//! existing `@import("clock.zig")` / `io.Clock` consumers (EventLoop,
//! peer handlers, sim tests) continue to compile during the migration
//! that scatters Clock-aware callers across `dht/`, `rpc/`, etc.
//!
//! See `src/runtime/clock.zig` for the type and design notes.

const runtime_clock = @import("../runtime/clock.zig");

pub const Clock = runtime_clock.Clock;
