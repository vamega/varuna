# HttpExecutor `bind_address` and Full-Isolation Transfer Matrix

**Date:** 2026-04-22 (session continuation)

## What Changed

### 1. `src/io/http_executor.zig` — outbound bind config

The HTTP tracker client and BEP 19 web seed downloads previously
ignored `cfg.network.bind_address`. Every outbound HTTP connection
used the OS default source IP, which is fine for single-homed
production but blocked test isolation: when a seeder bound its peer
listener to `127.0.1.2` but its tracker announce originated from
`127.0.0.1`, opentracker registered the peer at the wrong address and
the downloader couldn't reach it.

Change:

- `HttpExecutor.Config` now carries `bind_device: ?[]const u8` and
  `bind_address: ?[]const u8`. Both are slices; strings must outlive
  the executor (in practice they come from `cfg.network.*`, which
  lives as long as the process).
- `HttpExecutor.create` copies the values onto the struct.
- `handleSocketCreated` calls `socket_util.applyBindConfig(fd,
  bind_device, bind_address, 0)` on the fd returned by
  `IORING_OP_SOCKET` *before* `IORING_OP_CONNECT`. This matches what
  `src/io/peer_handler.zig:144` already does for peer sockets.

Propagation:

- `TrackerExecutor.Config` forwards the same two fields and passes
  them into `HttpExecutor.create`.
- `SessionManager.ensureTrackerExecutor` reads
  `el.bind_device` / `el.bind_address` (already populated by
  `main.zig` from the TOML config) and passes them through.

### 2. `scripts/test_transfer_matrix.sh` — unique /24 per test

Each test now runs in its own `127.0.${TEST_INDEX}.x` /24:

```
tracker    → 127.0.${TEST_INDEX}.1 : 6969
seeder     → 127.0.${TEST_INDEX}.2 : 6881 (peer) / 8081 (api)
downloader → 127.0.${TEST_INDEX}.3 : 6882 (peer) / 8082 (api)
```

Every `(src_ip, src_port, dst_ip, dst_port)` 4-tuple across the suite
is therefore disjoint. Nothing the kernel keeps around from test N
(TIME_WAIT, CLOSE_WAIT, conntrack) can land on test N+1's listening
socket, because test N+1 isn't on the same address. Port re-use
across tests is fine — different IP, different tuple.

All helpers were refactored to take an explicit `host` argument
(`wait_for_tcp`, `api_login`, `api_add_torrent`, `api_get_progress`,
`register_shutdown`, `write_daemon_config`, `start_daemon`).
`wait_for_port_free` is gone because it's no longer needed — the
test's port always starts idle since nothing else has that address.

The `large-20m-64k` timeout went back from 240 s to the original 120 s
since proper isolation makes it fast again when it passes.

## Results

5 back-to-back runs of `scripts/test_transfer_matrix.sh`:

| Run | Result | Notes                                         |
|-----|--------|-----------------------------------------------|
| 1   | 24/24  | all tests PASS                                |
| 2   | 23/24  | `large-20m-64k` timeout at `progress=0.0000`  |
| 3   | 24/24  | all tests PASS                                |
| 4   | 24/24  | all tests PASS                                |
| 5   | 24/24  | all tests PASS                                |

**4/5 → 80% first-run pass rate.** Before these changes the matrix was
0/24, then 23/24 with frequent regression of the passing test.

Unit tests (`zig build test`) and `demo_swarm.sh` are unaffected.

## The Remaining Flake Is a Varuna Bug

With per-test `/24` isolation, inter-test interference is impossible at
the kernel level — test N+1's sockets use addresses test N never
touched. The lingering 20% failure rate on `large-20m-64k` is
therefore a real daemon-side issue. Observations:

- When the test stalls, `progress=0.0000` — no pieces transferred at
  all, but the peers complete MSE and extension handshake.
- Same test passes in ~6 s when run alone.
- Specific to the 20 MB × 64 KB-piece layout (320 pieces, 4 blocks per
  piece). `large-20m-256k` (80 pieces, 16 blocks per piece) and
  `large-50m-256k` (200 pieces) both pass reliably.

Hypothesis: something in the early REQUEST / CHOKE / UNCHOKE sequence
mis-handles the specific 320×4 layout under contention. Needs
instrumentation — probably log the peer state machine transitions
once per second on the downloader for this one test, and capture a
stalled-state snapshot.

## Key Code References

- `src/io/http_executor.zig:130-140` — `Config` struct
- `src/io/http_executor.zig:280-296` — `create` stores bind fields
- `src/io/http_executor.zig:518-527` — `handleSocketCreated` applies
  them before connect
- `src/daemon/tracker_executor.zig:42-62` — forwarding in `Config` and
  `create`
- `src/daemon/session_manager.zig:698-716` — `ensureTrackerExecutor`
  reads from `el.bind_*`
- `scripts/test_transfer_matrix.sh:6-26` — isolation-model comment
- `scripts/test_transfer_matrix.sh:189-203` — per-test IP assignment
  via `TEST_INDEX`

## Follow-up

- **Instrument `large-20m-64k` failure.** When the downloader sits at
  `progress=0.0000`, we need a dump of: peer bitfield state, who is
  choked/choking whom, inflight request queue, pipeline_sent, etc.
  Either add a `/api/v2/peers` debug endpoint or log a state line
  every 5 s when progress hasn't moved.
- **Apply the same isolation to `test_web_seed.sh` and
  `demo_daemon_swarm.sh`** once they need it. Today they use only one
  daemon per test so inter-test interference is lower-risk, but the
  pattern is nice.
- **`scripts/test_large_transfer.sh`** still calls removed
  `varuna-tools seed` / `download` subcommands and is dead code until
  someone rewrites it to drive the daemon + API like
  `test_transfer_matrix.sh` does.
