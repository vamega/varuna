# DHT Stack Overflow, Bootstrap Retry, and Heap Init Fixes

## What was done

Fixed three bugs that prevented the DHT from functioning correctly. After the
initial DHT integration (BEP 5 + BEP 32), the daemon crashed on startup and
then, once crash-fixed, the DHT would get stuck at 2 nodes and never bootstrap.

### Bug 1: Stack overflow (daemon crashes on startup)

`DhtEngine` allocated as a local variable in `main()` caused a stack overflow.
The struct is ~900 KB:
- `RoutingTable`: 160 KBuckets × 8 NodeInfos × ~144 bytes = ~182 KB
- `active_lookups: [16]?Lookup`: each Lookup has `peers: [256]std.net.Address`
  (256 × 112 = 28 KB) and `candidates: [64]Candidate` (~14 KB) → 16 × ~42 KB = ~672 KB
- `pending: [256]?PendingQuery` = ~38 KB

Combined with the EventLoop on the stack and glibc's `getaddrinfo()` (which can
use several MB of stack internally), the 8 MB default thread stack was exceeded.

**Fix**: Set `daemon_exe.stack_size = 32 * 1024 * 1024` in `build.zig` via the
`Compile.stack_size` field (passes `--stack N` to the Zig linker). Also added
`DhtEngine.create()` which heap-allocates and initializes via explicit field
assignment, avoiding large struct temporaries on the stack.

### Bug 2: Bootstrap gets permanently stuck

When the initial `find_node` lookup (for our own ID) completed without finding
K=8 nodes (all timeouts, sparse routing responses), `bootstrap_pending` stayed
`true` forever. The tick logic `if (!bootstrapped and !bootstrap_pending)` then
skipped calling `startBootstrap()` on all future ticks.

**Fix**: In `DhtEngine.tick()`, reset `bootstrap_pending` to `false` if no
active lookups are currently running. This allows the next tick to retry:

```zig
if (self.bootstrap_pending) {
    const has_active = for (self.active_lookups) |lk| {
        if (lk != null) break true;
    } else false;
    if (!has_active) self.bootstrap_pending = false;
}
```

### Bug 3: Heap allocation without stack temporaries

`DhtEngine.create()` initializes each field individually via pointer assignment.
Large nullable arrays (`pending[256]`, `active_lookups[16]`) are initialized via
explicit `for` loops rather than array-literal assignment, which avoids the
compiler creating large stack temporaries for the RHS expression.

## What was learned

- Zig's `Compile.stack_size` field (not `ExecutableOptions.stack_size`) is the
  correct way to set the ELF stack size hint in Zig 0.15.
- glibc `getaddrinfo()` can consume 1-4 MB of stack for DNS resolution. Combined
  with a large local struct in main(), this exceeds the default 8 MB stack.
- `ulimit -s unlimited` is a useful diagnostic: if it fixes a crash, it's
  stack overflow.
- DHT bootstrap "stuck at 2 nodes" was a control-flow deadlock, not a network
  issue. The retry logic was correct but the state machine had no recovery path.
- Zig array-literal assignment (`self.x = [_]T{val} ** N`) may or may not create
  a stack temporary depending on optimization level. Explicit loops are safer for
  large arrays when heap-allocated objects are being initialized.

## Remaining issues

- DHT nodes fluctuate between 100-120. A full DHT implementation would have
  160 K-buckets fully populated, but BEP 5's iterative lookup converges on a
  subset of the network sufficient for peer discovery.
- Node ID and routing table are not persisted to SQLite (see `src/dht/persistence.zig`).
  Each restart re-bootstraps from scratch.
- Download starts slow (~500 KB/s) and peaks at ~12 MiB/s once the tracker
  re-announces and more peer connections are established. Early speed depends on
  the initially returned peer batch quality.

## Code references
- `build.zig:115` — `daemon_exe.stack_size = 32 * 1024 * 1024`
- `src/dht/dht.zig:103-140` — `DhtEngine.create()` heap init
- `src/dht/dht.zig:178-192` — bootstrap retry fix in `tick()`
- `src/main.zig:87-114` — uses `DhtEngine.create()` instead of stack allocation
