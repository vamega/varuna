# 2026-04-28 — DNS `bind_device` cleanup: module-global → explicit Config

Branch: `worktree-dns-bind-device-cleanup`.

Follow-up to the 2026-04-28 correctness-fixes round (commit `4c845a4`,
`progress-reports/2026-04-28-correctness-fixes.md`). That round wired
`bind_device` into the c-ares DNS path via a process-wide write-once
module global (`dns.setDefaultBindDevice` / `dns.defaultBindDevice`)
because the engineer was forbidden from touching the executor /
session-manager files at the time. They documented it as
"gross-but-contained" and worth revisiting once the parallel-work
constraint lifted. This milestone does the clean refactor.

## What changed

### New `dns.Config` struct (replaces module global)

```zig
// src/io/dns.zig
pub const Config = struct {
    bind_device: ?[]const u8 = null,
    ttl_bounds: TtlBounds = TtlBounds.default,
};

// Both backends:
pub fn init(allocator: std.mem.Allocator, config: Config) !DnsResolver { ... }
```

The c-ares backend stores `config.bind_device` on the resolver and
heap-allocates a stable `BindDeviceCell` registered as `user_data` on
`ares_set_socket_callback`. The callback dereferences the cell to
read the slice, instead of re-reading a module global. The threadpool
backend stores the field for API parity but cannot apply it (its top
docstring's "Known limitation" paragraph is preserved verbatim — the
gap is queued behind the custom-DNS-library work).

### Plumbing chain

`cfg.network.bind_device` (config arena, daemon lifetime)
  → `main.zig` `sm.bind_device = cfg.network.bind_device`
  → `SessionManager.bind_device: ?[]const u8`
  → `ensureTrackerExecutor` / `ensureUdpTrackerExecutor` pass `.bind_device`
  → `TrackerExecutor.Config.bind_device` → `HttpExecutor.Config.bind_device`
  → `UdpTrackerExecutor.Config.bind_device`
  → `DnsResolver.init(allocator, .{ .bind_device = ... })`

### Files touched (caller side)

- `src/main.zig` — set `sm.bind_device`; deleted the `setDefaultBindDevice` call
- `src/daemon/session_manager.zig` — new `bind_device` field on `SessionManager`; both `ensure*Executor` helpers forward it
- `src/daemon/tracker_executor.zig` — `Config.bind_device` forwarded into the inner `HttpExecutor`
- `src/daemon/udp_tracker_executor.zig` — `Config.bind_device` forwarded into `DnsResolver.init`
- `src/io/http_executor.zig` — `Config.bind_device` forwarded into `DnsResolver.init`

### Files touched (resolver layer)

- `src/io/dns.zig` — new `Config` struct; deleted `setDefaultBindDevice`,
  `defaultBindDevice`, `module_default_bind_device`
- `src/io/dns_cares.zig` — `init(allocator, Config)`; new `BindDeviceCell`
  user_data heap cell; callback reads cell instead of global; deinit frees cell
- `src/io/dns_threadpool.zig` — `init(allocator, Config)`; stores
  `bind_device` field; "Known limitation" docstring untouched

### Test coverage

- `src/io/dns.zig` — two new cross-backend tests: `Config.bind_device`
  is captured into `resolver.bind_device`; default Config leaves it null
- `src/io/dns_cares.zig` — four new tests:
  - Config.bind_device captured to per-resolver field and heap cell
  - default config leaves cell null
  - socket callback applies bind_device to a real fd (skipping
    gracefully on `BindDevicePermissionDenied` /
    `BindDeviceNotFound` for the synthetic device name)
  - callback with null user_data is a clean no-op

## What was learned

- **The "gross-but-contained" workaround was load-bearing on a single
  read site.** All consumers of the global lived inside
  `dns_cares.zig` (the `init` and the socket callback). The threadpool
  backend never read it — its "Known limitation" was the whole story.
  So the cleanup was small once the no-touch constraint dropped:
  add a Config field, plumb it three executor levels and one
  SessionManager field, delete the global. ~150 lines net.

- **`user_data` on the c-ares socket callback wants a stable pointer,
  not a slice.** `[]const u8` is two words (ptr + len). Stuffing it
  through `?*anyopaque` requires either a heap cell or some form of
  encoding. The original workaround sidestepped this by reading from
  a module global. The clean answer is a heap-allocated cell whose
  lifetime is tied to the resolver — the same shape as any other
  long-lived `*anyopaque` user_data on async callbacks elsewhere in
  the codebase.

- **The threadpool gap stays queued, not closed here.** The custom-DNS-
  library work in `docs/custom-dns-design-round2.md` §1 is the right
  fix for that — a resolver that owns its UDP socket can apply
  `SO_BINDTODEVICE` natively on every backend. This milestone cleaned
  up the workaround without expanding scope.

## Remaining issues / follow-up

- **Threadpool `bind_device` gap**: still a Known Issue (STATUS.md).
  The custom-DNS-library work is the closing fix.
- **c-ares backend build**: pre-existing `ares_build.h not found`
  issue documented in `progress-reports/2026-04-28-correctness-fixes.md`.
  Not in scope here.

## Key code references

- `src/io/dns.zig:42-65` — new `Config` struct + module docstring
- `src/io/dns_cares.zig:79-132` — c-ares `init(allocator, Config)` +
  BindDeviceCell registration
- `src/io/dns_cares.zig:139-141` — `BindDeviceCell` declaration
- `src/io/dns_cares.zig:157-170` — callback reads cell from user_data
- `src/io/dns_threadpool.zig:54-78` — threadpool `init(allocator, Config)`
- `src/io/http_executor.zig:135-141` — `HttpExecutor.Config.bind_device`
- `src/io/http_executor.zig:281` — `DnsResolver.init` call site
- `src/daemon/udp_tracker_executor.zig:90-96` — `UdpTrackerExecutor.Config.bind_device`
- `src/daemon/tracker_executor.zig:42-50` — `TrackerExecutor.Config.bind_device`
- `src/daemon/session_manager.zig:34-43` — `SessionManager.bind_device`
- `src/daemon/session_manager.zig:707-721` — `ensure*Executor` plumb
- `src/main.zig` (`initSessionManager`) — `sm.bind_device = cfg.network.bind_device`
- STATUS.md — milestone added; "Known Issues" entry refreshed to point at the new plumbing path

## Test count delta

1525 → 1531 (+6 inline tests across `dns.zig` and `dns_cares.zig`).
