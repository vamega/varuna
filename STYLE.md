# Varuna Style

## Design Goals

Safety. Correctness. Testability. Performance. In that order.

**Safety** means the process cannot corrupt data on disk or send malformed wire messages,
regardless of what peers or the OS do. Assertions are the primary tool. A bug that crashes
the daemon is always preferable to one that silently corrupts a file.

**Correctness** means BitTorrent protocol compliance, full piece verification, and
deterministic behavior under all peer inputs — including malicious ones. Correctness cannot
be assumed; it must be demonstrated by tests that include invalid inputs, protocol
violations, and fault injection.

**Testability** means the full download stack — peer wire, piece verification, disk I/O —
can be exercised in a single-threaded deterministic simulation with no real network, no real
disk, and no wall-clock time. If a code path cannot be exercised by the simulator it is a
design defect, not a test gap.

**Performance** means predictable latency and throughput under load. The primary tool is
static allocation: a system with known memory usage at startup has predictable behavior
under load. Allocator churn on the data plane is a correctness issue as much as a
performance issue — it makes behavior harder to reason about.

---

## The IO Abstraction

The central architectural principle: **the event loop is generic over its IO backend**.

Production code uses `io_uring`. Test code uses `SimIO`, an in-process backend that
delivers completions in a controlled order under a seeded random number generator. Both
implement the same comptime interface. There are no vtables, no runtime dispatch, no `if
(sim_mode)` branches in production code.

```zig
// An IO backend provides these operations.
// The EventLoop is EventLoop(IO: type) — generic over the backend.
pub fn EventLoop(comptime IO: type) type {
    return struct {
        io: IO,
        clock: Clock,
        // ...
    };
}
```

### Completion ownership

Completions are **caller-owned structs**, never heap-allocated by the loop. The caller
declares a `Completion` on the stack or embeds one in a longer-lived struct, submits it to
the loop, and the loop invokes the callback when the operation finishes. The loop holds only
a pointer into the caller's memory — it never allocates.

```zig
// Good: completion embedded in peer slot (static lifetime)
const Peer = struct {
    recv_completion: IO.Completion = .{},
    send_completion: IO.Completion = .{},
    // ...
};

// Bad: allocating a completion on the heap
const c = try allocator.create(IO.Completion);
```

### Intrusive queues

All internal queues embed linkage in the element type. The queue owns no memory; the
element owns its own queue node. This is the only queue design permitted on the data plane.

```zig
// The next pointer lives in the element, not in a separately allocated node.
const PendingWrite = struct {
    next: ?*PendingWrite = null,
    // ...
};
```

### Callback contract

Every completion callback returns a `CallbackAction`:

```zig
pub const CallbackAction = enum { disarm, rearm };
```

`.disarm` means the operation is complete; the completion is returned to the caller.
`.rearm` means submit the same operation again immediately (useful for persistent recvs).
The loop never rearms a completion without the callback's explicit instruction.

Callbacks must not block, allocate, or recurse. They may submit new operations to the loop.

### SimIO

`SimIO` is a first-class backend, not a test hack. It maintains an in-process queue of
pending operations and delivers completions in an order controlled by the simulator. Every
operation that real `io_uring` performs — recv, send, read, write, timeout — has a `SimIO`
equivalent that returns results through the same callback path.

`SimIO` can:
- Deliver completions out of submission order (simulates kernel reordering)
- Inject errors on any operation (EIO, ENOSPC, ECONNRESET)
- Deliver a recv completion with partial data (simulates fragmented TCP segments)
- Deliver a write completion with success but store corrupted data (simulates bad disk)
- Refuse to deliver a completion at all (simulates a hung peer or full send buffer)

All fault decisions are driven by a seeded `std.rand.DefaultPrng`. Any failing test prints
its seed. Re-running with the same seed reproduces the failure exactly.

### Migration patterns (Stage 2 lessons)

Patterns that fell out of the Stage 2 migration (Apr 2026) and the bugs they catch:

1. **Single Completion per long-lived "slot"** for serial state machines. The Completion
   embeds in the slot struct (Peer, RequestSlot, etc.); `@fieldParentPtr("completion", c)`
   recovers the slot pointer from the Completion in the callback; pointer arithmetic on the
   parent slice yields the slot index. Use this when the underlying state machine is fully
   serial (handshake → header → body, or DNS → connect → TLS → send → recv).

2. **Heap-allocated tracking struct with embedded Completion** for fan-out parallel ops
   where multiple ops are in flight against the same logical entity. Per-op `allocator.create`
   is acceptable on cold paths (recheck reads, RPC per-client gen-stamped ops). On hot paths
   (PendingSend for tracked peer wire sends), use a fixed-size pool (see `PendingSendPool`)
   pre-allocated at init — stable addresses, zero alloc churn, bound auditable at startup.

3. **`io.connect(.{ .deadline_ns = ... })`** replaces manual `IOSQE_IO_LINK + link_timeout`
   on a sentinel `ud + 1`. The backend does the chaining; callers just specify the deadline.

4. **`io.poll(POLL.IN)` with `.rearm`** replaces sentinel-userdata schemes for eventfd-driven
   plumbing (DNS thread completion, signalfd, anything where a fd becomes readable on a
   signal you don't control).

5. **`Completion._backend_state` defaults to all-zero, never `undefined`.** In Debug,
   `undefined` fills with `0xaa`, which a backend's RealState would observe as `in_flight = true`
   on a fresh completion. Explicit zero-init at the contract level prevents this.

6. **`dispatchCqe` clears `in_flight` *before* invoking the callback** (multishot still
   preserves the flag because the kernel will deliver more CQEs). A callback that re-arms
   the same completion in the natural "header → body → next header" pattern would otherwise
   trip `AlreadyInFlight` against itself.

7. **When running two backends side-by-side during a migration, the unused backend's
   `tick` must be non-blocking.** Stage 2 had `EventLoop` blocking on the legacy ring's
   `submit_and_wait(1)` while the new ring drained non-blocking. Once the migration drained
   the legacy ring of all SQEs, the blocking call deadlocked indefinitely. The fix was
   swapping which ring blocks — but the general lesson is: **the backend you're tearing
   down still has to be drainable correctly during the tear-down**. Future migrations of
   similar shape should plan the wait swap up front, not as a fire drill.

---

## Memory

**No dynamic allocation after init on the data plane.** The data plane is: peer wire
protocol, piece assembly, piece verification, disk I/O, and the event loop itself.

Everything the data plane needs is sized and allocated during `EventLoop.init`:
- The peer table (`max_connections` fixed slots)
- Per-peer recv scratch buffer (`max_connections × max_control_message_size`)
- Piece buffer pool (`max_connections × 2 × max_piece_size`)
- Completion structs embedded in peer slots
- io_uring ring (fixed SQE/CQE count)

After init, no allocator is called on any data-plane path. The high-water mark is known
and auditable before the first peer connects.

**The control plane** (RPC, tracker announces, DHT, metainfo parsing) uses a bump allocator
with a hard upper bound. The bump pointer is reset after each operation completes. If an
operation would exceed the bound, it fails with an explicit error — it does not grow past
the limit.

**Metainfo** (file paths, tracker URLs, piece hashes) lives in an arena per session,
allocated once on torrent load and freed on torrent remove. Piece hashes for completed
torrents are freed; they are not needed for seeding. See `docs/piece-hash-lifecycle.md`.

The rule for new code: **ask what the upper bound is before writing `allocator.alloc`**. If
there is a finite upper bound, the allocation belongs in `init`. If there is no bound, the
code belongs on the control plane behind a bump allocator.

---

## Assertions

Assertions are not defensive programming. They are a precise statement of what the
programmer believes to be true. A violated assertion means the programmer's model of the
system is wrong — and the only correct response is to crash.

**Density**: every function should have at least two assertions. Assert preconditions on
entry and postconditions before returning. Assert invariants at the boundary between
components.

**Pair assertions**: for every invariant you care about, find two places to assert it. If
data is written to a buffer, assert the length before writing and assert the content after.
If a piece passes verification, assert the hash matched before marking it complete and
assert it is marked complete before releasing the piece buffer.

**Positive and negative space**: assert what you expect to be true AND that the alternative
is not true. A function that validates a REQUEST message should assert the piece index is in
range AND that the block offset plus length does not exceed the piece size. Both conditions.

**Split compound assertions**: `assert(a); assert(b);` not `assert(a and b)`. The split
form tells you which condition failed.

**Compile-time assertions**: use `comptime assert` to document and enforce struct layout,
size invariants, and configuration constants. These are checked before the program runs and
cost nothing at runtime.

```zig
// Good
comptime assert(@sizeOf(PeerMessage) == 17);
comptime assert(max_block_size <= max_piece_size);

// Good: split
assert(piece_index < piece_count);
assert(block_offset + block_length <= piece_size);

// Bad: compound
assert(piece_index < piece_count and block_offset + block_length <= piece_size);
```

**Assertions are not a substitute for understanding.** Build a precise mental model first.
Encode that model as assertions. Use the simulator to find the cases where your model is
wrong.

---

## Simulation-First Testing

Every non-trivial behavior in the system should have a simulation test before it has a
production code path. The sequence is:

1. Write a `SimSwarm` configuration that exercises the behavior.
2. Write assertions on the outcome.
3. Implement the production code path.
4. Run the sim under randomized fault injection (BUGGIFY) to stress the assertions.

A test that only exercises the happy path is a smoke test, not a correctness test. Every
sim test should include at least one fault scenario: a corrupt block, a peer that
disconnects mid-transfer, a disk write that fails and is retried.

### What SimPeer can do

A `SimPeer` is a scriptable peer implementing the BitTorrent wire protocol in process,
driven by the same simulator tick that drives the EventLoop. Behaviors compose:

```zig
pub const SimPeer = struct {
    behavior: Behavior,

    pub const Behavior = union(enum) {
        honest: void,
        slow: struct { bytes_per_tick: u32 },
        corrupt: struct { probability: f32 },  // flip bits in block data
        wrong_data: void,                      // correct piece index, wrong bytes
        silent_after: struct { blocks: u32 },  // stop responding, hold connection open
        disconnect_after: struct { blocks: u32 },
        lie_bitfield: void,                    // claim pieces not held
    };
};
```

### Seeded randomness

Every simulator instance takes a seed. All fault decisions — whether to corrupt this block,
whether to drop this connection, in what order to deliver completions — derive from a single
`std.rand.DefaultPrng` initialized from that seed.

```zig
// Tests print the seed on failure.
// Reproduce with: zig build test-sim -- --seed=0xDEADBEEF
```

### What a good sim test proves

A sim test for smart ban should prove:
1. With one corrupt peer in a swarm, the piece eventually completes (liveness).
2. The corrupt peer is banned before the piece is abandoned (correctness).
3. Honest peers in the same swarm are not banned (no false positives).
4. The above holds for at least N different random seeds (not just the happy case).

A test that only proves (1) is a smoke test.

---

## Layered Testing Strategy

Complex protocol behaviour gets split into three test types. Each asserts a different
property; none of them are redundant. The general rule is **safety properties are
fault-invariant; liveness properties are not** — so the layering is built around which
property each test is asserting.

### 1. Algorithm test — pure data flow, no faults, deterministic

Asserts that the algorithm computes the right answer on the right inputs. No async hashing,
no `removePeer` reaping, no socket timing — just the bare data structure being driven through
its state space.

Canonical example: `tests/sim_smart_ban_protocol_test.zig` runs the smart-ban Phase 0
trust-points decay/recovery + ban-at-threshold logic against scripted SimPeers, all in
process, all synchronous. Locks in the *what*: trust goes 0 → -2 → -4 → -6 → -8 across
four hash failures; banning fires at `<= -7`; honest peers' trust never drops.

### 2. Integration test — real EventLoop, sim-driven, deterministic, multiple seeds

Asserts that the algorithm fires correctly when integrated with the production code paths
that depend on it. Real `EventLoopOf(SimIO)`, real hasher thread, real disk-write pipeline,
real `BanList`. No fault injection. Multiple seeds for ordering coverage.

Canonical example: `tests/sim_smart_ban_eventloop_test.zig` runs 5 honest + 1 corrupt
SimPeers against `EventLoopOf(SimIO)` over 8 seeds. Asserts pieces 1..3 verify, piece 0
stays incomplete, corrupt peer is banned, no honest peer is banned. Locks in the
*that-it-fires-end-to-end*.

### 3. Safety-under-faults test — real EventLoop, BUGGIFY + FaultConfig, many seeds

Asserts safety invariants — properties that hold by construction across every possible
fault sequence — *not* liveness. Uses both per-tick heap-probe (`SimIO.injectRandomFault`)
and per-op `FaultConfig` probabilities to inject errors at random times into random
in-flight operations. Many seeds. The vacuous-pass guard ensures real coverage.

Canonical example: `tests/sim_smart_ban_eventloop_test.zig` "BUGGIFY" test runs the same
scenario over 32 seeds with randomized faults. Asserts only:
- No honest peer is wrongly banned (provable: `penalizePeerTrust` is the only `bl.banIp`
  caller; it only runs on hash failure; honest peers don't send bad data).
- No honest peer accumulates hashfails.
- The test exits cleanly (no panic, no leak).
- A meaningful majority of seeds DO observe an actual ban (vacuous-pass guard: rejects the
  pathology where every seed silently severs the corrupt peer's connection before its
  bytes reach the EL).

Liveness is *not* asserted here. Under randomized faults, the corrupt peer's socket can
legitimately die before its 4th hash-fail; the ban won't fire; the test must not flag
that as a failure. Asserting liveness under randomized faults requires either (a)
deterministic fault profiles per seed (defeats BUGGIFY's purpose), (b) a fault-aware
liveness window per seed (test fragility), or (c) running until convergence under
adversarial fault timing (test flakiness). None are good. Pin to safety.

### When to write which

A new protocol behaviour gets all three layers, in order. The algorithm test is fastest to
write and locks the spec; the integration test surfaces wiring issues; the safety-under-
faults test catches recovery-path bugs that only show up when the system is being kicked
around. Skipping any layer leaves a class of bug uncovered. The "different fault profiles
exercise different recovery paths" property of layer 3 is deliberate — the seeds where the
ban *doesn't* fire still exercise meaningful cleanup paths (half-banned peer mid-fail), so
don't tighten the vacuous-pass threshold to require 100% bans.

---

## Safety Rules

### Control flow

Use simple, explicit control flow. No recursion — every call stack must be statically
bounded. Bencode parsing, Merkle tree traversal, and other tree-shaped problems must use
an explicit stack, not recursive function calls.

Centralize control flow. A parent function handles branching; helper functions are pure
computations without branches. Push `if`s up, push `for`s down.

### Bounds on everything

Every loop has a fixed upper bound. Every queue has a capacity. Every slice index is
checked before use. If the bound is violated, assert and crash — do not silently truncate
or wrap.

```zig
// Good
assert(slot < self.max_connections);
const peer = &self.peers[slot];

// Bad
const peer = &self.peers[slot]; // trusting the caller
```

### No silent truncation

When a buffer is too small, return an error or assert. Never silently write only as many
bytes as fit and pretend the operation succeeded. Buffer bleeds (heartbleed-style
under-fills) are as dangerous as overflows.

### Explicit sizes

Prefer `u32` over `usize` for protocol fields, piece counts, block offsets, and port
numbers. `usize` is for memory addresses and slice lengths. Mixing the two is a source of
subtle bugs on 32-bit builds and makes the intent unclear.

### Handle every error

Every `try` is a statement about what can go wrong. Errors that cannot happen should have
an `unreachable` with a comment explaining why, not a silent `catch {}`. Silently
swallowing errors is the most common source of catastrophic failures in distributed systems.

---

## Naming

**Units belong in names.** A variable named `timeout` is ambiguous. `timeout_ms`,
`timeout_ns`, `deadline_sec` are not. Put units last, after the most significant word:
`latency_ms_max` not `max_latency_ms`. This groups related variables when sorted.

**Sizes, counts, and indexes are distinct types in spirit.** Name them to show which one
they are: `piece_count`, `piece_index`, `piece_size_bytes`. To go from an index to a count,
add one. To go from a count to a size, multiply. Getting these conversions wrong is an
off-by-one error. Naming them correctly makes the conversion explicit.

**Callbacks are named after their caller.** If `recvHeader` submits an operation and its
completion calls back into the loop, the callback is `recvHeaderComplete`. The call history
is readable from function names alone.

**Allocators carry meaning.** `gpa` is a general-purpose allocator. `arena` is an arena
that will be freed as a unit. `bump` is a bump allocator reset per operation. A parameter
named `allocator` tells you nothing about lifetime or behavior.

**Options structs for ambiguous arguments.** Any function that takes two or more arguments
of the same type uses an options struct. `submitRecv(fd, buf, offset, len)` with two `u32`
arguments is a bug waiting to happen. `submitRecv(fd, buf, .{ .offset = 0, .len = 512 })`
is not.

---

## Code Shape

**Functions fit on a screen.** If you have to scroll to see the end of a function, split
it. The exact line count matters less than whether the function's full shape — its
preconditions, its core logic, and its postconditions — is visible at once.

**One thing per function.** A function that parses a message AND handles its side effects
AND updates peer state is three functions. Parse and return a value. Handle effects
separately. The parser is then testable without a peer slot.

**Leaf functions are pure.** Helpers that compute a value should take inputs and return
outputs without touching `self`. Pure functions are trivially testable and composable.

**State transitions are explicit.** When a peer changes state — from `connecting` to
`handshaking` to `active` — the transition is a named function with assertions on entry and
exit state. Implicit state changes buried in the middle of a large function are the primary
source of protocol bugs.

```zig
fn transitionToActive(self: *EventLoop, slot: u16) void {
    const peer = &self.peers[slot];
    assert(peer.state == .handshake_complete);
    peer.state = .active_recv_header;
    peer.last_activity = self.clock.now();
    // ...
    assert(peer.state == .active_recv_header);
}
```

---

## Comments

Write comments to explain **why**, not what. The code already says what. A comment that
restates the code adds noise. A comment that explains a protocol requirement, a subtle
invariant, or a workaround for a specific kernel behavior is worth writing.

Comments are full sentences: capital letter, period at the end, space after `//`. A comment
that trails a line of code may be a short phrase without punctuation.

Never omit the reason. If you write `// do not reorder`, also write why reordering would
break something.

---

## Tooling

The build file is the source of truth for how to build and test the project. Every
operation that a contributor needs — build, test, benchmark, simulate, format — is a `zig
build` step. One-off shell scripts that duplicate build logic are not permitted.

`zig fmt` is not optional. The diff is not a style debate.

Zig is the only language in the repository for new code. If a task seems to require a shell
script or Python helper, write a `zig build` step instead. Type safety and reproducibility
are worth the initial investment.

---

## The Test Hierarchy

From narrowest to broadest:

1. **Unit tests** (`test` blocks inline): pure functions, data structure invariants,
   protocol message parsing. No IO. No allocator beyond testing allocator. Run in
   milliseconds.

2. **Sim tests** (`tests/sim_*.zig`): one or more `SimPeer`s against a real `EventLoop`
   driven by `SimIO`. Exercises the full download path. Seeded, deterministic, fast.
   The right place to test protocol correctness, smart ban, and banning strategies.

3. **Integration tests** (`tests/*_integration_test.zig`): real sockets, real disk,
   real io_uring. Used to validate that the sim results hold against the real stack.
   Slower; not run in CI on every commit.

4. **Demo swarm** (`zig build demo`): a multi-peer real-network download against a local
   tracker. Used to validate end-to-end behavior and measure real throughput. Run manually.

New protocol behavior gets a sim test first. If the sim test passes and the integration
test fails, the gap between `SimIO` and real `io_uring` is the bug — fix the sim.
