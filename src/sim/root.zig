pub const virtual_peer = @import("virtual_peer.zig");
pub const VirtualPeer = virtual_peer.VirtualPeer;

pub const sim_peer = @import("sim_peer.zig");
pub const SimPeer = sim_peer.SimPeer;

pub const simulator = @import("simulator.zig");
pub const Simulator = simulator.Simulator;
pub const SimulatorOf = simulator.SimulatorOf;
pub const StubDriver = simulator.StubDriver;

// Pull subsystem source-side `test "..."` blocks into the test runner.
// Mirrors the pattern in `src/io/root.zig` and `src/dht/root.zig`. Wired
// into `mod_tests` via `_ = sim;` in `src/root.zig`'s test block.
test {
    _ = simulator;
    // virtual_peer.zig and sim_peer.zig have no inline tests today; their
    // behaviors are exercised via `tests/sim_*` integration suites. List
    // here once they grow inline coverage.
}
