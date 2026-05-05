# Memory safety static audit

Date: 2026-05-05

Fix update: 2026-05-05

Scope: source-level review and validation for use-after-free, invalid frees,
retained allocations, checked-arithmetic traps, and async shutdown races that
could plausibly surface as SIGSEGV, SIGABRT, SIGBUS, or allocator corruption.

## What changed and why

- Rebased validation branch `agent/memory-safety-validation-tests` onto current
  local `main` (`3c86bc1`).
- Converted the validation repros in `tests/memory_safety_validation_test.zig`
  into passing regression tests. The aggregate `zig build test-memory-safety`
  target is wired into `zig build test`, and focused `test-memory-*` targets
  remain available for each issue.
- Fixed seed-mode piece reads by dynamically sizing per-span metadata and
  keeping the shared piece buffer alive until every submitted read CQE drains.
- Fixed bencode and metainfo partial-cleanup paths so errors free only owned,
  initialized values.
- Fixed storage partial-submit paths by draining already submitted completions
  before stack-owned completion/context arrays go out of scope.
- Fixed hostile `Content-Length` arithmetic in the RPC server and HTTP executor
  with checked addition and response-size bounds.
- Fixed UDP tracker host handling by adding a checked `Job.setHost` copy API.
- Fixed event-loop move-job teardown by having `SessionManager.deinit` cancel
  and drain move jobs before freeing jobs whose embedded completions may still
  be owned by the IO backend.

## What was learned

The confirmed issues were real and clustered around two ownership patterns:

- async submitters must keep userdata, completion objects, and target buffers
  alive until every submitted CQE has completed, even after the first operation
  fails;
- parsers that allocate arrays of owning values must track the initialized
  prefix and must free parsed-but-not-yet-appended child values on append
  failure.

The hostile-size issues were conventional checked-arithmetic gaps: external
lengths and offsets cannot be added or cast until bounded.

## Fixed issues

- Seed-mode multi-file piece reads no longer assume at most eight spans, and a
  failed read now waits for sibling CQEs before releasing the piece buffer
  (`src/io/event_loop.zig:191`, `src/io/seed_handler.zig:320`,
  `src/io/seed_handler.zig:388`).
- `MoveJob` event-loop completions are drained during session-manager teardown
  before the job is destroyed (`src/daemon/session_manager.zig:180`,
  `src/daemon/session_manager.zig:240`, `src/storage/move_job.zig:351`).
- `PieceStore.sync`, `preallocateAll`, and the truncate fallback drain partial
  submissions before returning submit errors (`src/storage/writer.zig:461`,
  `src/storage/writer.zig:621`, `src/storage/writer.zig:658`).
- `bencode.parse`, `parseList`, and `parseDict` free parsed children on
  trailing data and nested parse/append failures
  (`src/torrent/bencode.zig:32`, `src/torrent/bencode.zig:146`).
- `metainfo.parseWithOptions` frees initialized file/url/http-seed state only,
  uses checked casts for `creation date`, and shares file-list cleanup through
  `freeFiles` (`src/torrent/metainfo.zig:211`,
  `src/torrent/metainfo.zig:237`, `src/torrent/metainfo.zig:257`,
  `src/torrent/metainfo.zig:308`, `src/torrent/metainfo.zig:388`).
- RPC request parsing rejects overflowing `body_start + Content-Length`
  (`src/rpc/server.zig:424`).
- HTTP response parsing uses `http_parse.bodyEndOffset` and bounds accumulated
  response data (`src/io/http_parse.zig:146`,
  `src/io/http_executor.zig:93`, `src/io/http_executor.zig:1242`,
  `src/io/http_executor.zig:1308`).
- UDP tracker announce/scrape jobs reject hosts longer than the fixed 253-byte
  job buffer (`src/tracker/udp_executor.zig:84`,
  `src/tracker/udp_executor.zig:109`,
  `src/daemon/torrent_session.zig:1673`,
  `src/daemon/torrent_session.zig:1817`).

## Remaining issues or follow-up

- No confirmed issue from this audit remains intentionally unfixed in this
  branch.
- The `SessionManager.deinit` move-job drain is bounded at 1024 rounds and logs
  then leaks a still-running event-loop job rather than freeing memory still
  referenced by pending IO. That is a deliberate last-resort safety tradeoff;
  a future relocation scheduler can expose an explicit shutdown drain budget.
- The audit was focused on confirmed memory-safety findings. Broader hardening
  work, such as reviewing all external length additions and all async
  submitters, remains worthwhile.

## Key code references

- `tests/memory_safety_validation_test.zig:146` - nine-span seed read
  regression.
- `tests/memory_safety_validation_test.zig:221` - seed failed-read sibling CQE
  lifetime regression.
- `tests/memory_safety_validation_test.zig:317` - bencode trailing-data cleanup.
- `tests/memory_safety_validation_test.zig:324` - bencode nested-list cleanup.
- `tests/memory_safety_validation_test.zig:331` - metainfo fail-after cleanup.
- `tests/memory_safety_validation_test.zig:367` - UDP host length rejection.
- `tests/memory_safety_validation_test.zig:389` - RPC `Content-Length`
  overflow rejection.
- `tests/memory_safety_validation_test.zig:421` - HTTP body-end checked
  addition.
- `tests/memory_safety_validation_test.zig:436` - storage sync partial-submit
  drain.
- `tests/memory_safety_validation_test.zig:464` - storage init partial-submit
  drain.
- `tests/memory_safety_validation_test.zig:486` - session-manager move-job
  teardown drain.

## Validation

Commands run after the fixes:

- `nix develop -c timeout 180s zig build test-memory-seed-spans` - exit 0
- `nix develop -c timeout 180s zig build test-memory-bencode-trailing` - exit 0
- `nix develop -c timeout 180s zig build test-memory-bencode-nested` - exit 0
- `nix develop -c timeout 180s zig build test-memory-metainfo-oom` - exit 0
- `nix develop -c timeout 180s zig build test-memory-udp-host-overflow` - exit 0
- `nix develop -c timeout 120s zig build test-memory-rpc-content-length` - exit 0
- `nix develop -c timeout 180s zig build test-memory-http-content-length` - exit 0
- `nix develop -c timeout 180s zig build test-memory-storage-partial-submit` - exit 0
- `nix develop -c timeout 180s zig build test-memory-move-job-deinit` - exit 0
- `nix develop -c timeout 240s zig build test-memory-safety` - exit 0
- `nix develop -c timeout 600s zig build test` - exit 0
