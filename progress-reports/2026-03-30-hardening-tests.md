# Hardening tests: adversarial peers, soak test, private tracker

## What was done

Added three categories of hardening tests to catch protocol, resource, and tracker correctness issues:

### 1. Adversarial peer tests (`tests/adversarial_peer_test.zig`)
35 tests exercising the peer wire protocol against malicious inputs:
- Oversized message length fields (2 MiB, max+1, 2 GB attack)
- Invalid/unknown message ID coverage verification
- Wrong payload lengths for choke/unchoke/interested/not_interested/have/request/piece
- Malformed handshakes (wrong protocol length, wrong protocol string, wrong info_hash, truncated)
- Piece messages for unrequested pieces or when no piece is assigned
- Out-of-range piece indices via Bitfield.set() bounds checking
- Oversized and undersized bitfield imports
- Garbage/truncated/invalid bencode in extension handshakes
- Extension handshake with negative/overflow port values
- Connection limit sanity checks (global, per-torrent, half-open)
- Block offset beyond piece size detection
- BEP 10 reserved bit detection patterns
- Private torrent ut_pex omission

### 2. Soak test framework (`tests/soak_test.zig`, `zig build soak-test`)
Long-running resource leak detection harness:
- Runs 8 simulated torrents with 1000 pieces each for 10 seconds
- Tracks GPA `total_requested_bytes` for memory leak detection
- Monitors `/proc/self/fd` count for FD leaks
- Measures tick latency (fails if any tick > 100ms)
- Includes allocator stress test (varied sizes, interleaved alloc/free)
- Includes bitfield stress test (repeated init/set/import/deinit cycles)
- GPA deinit leak check on exit

### 3. Private tracker simulation tests (`tests/private_tracker_test.zig`)
25 tests for tracker announce correctness:
- All required announce fields: compact=1, numwant, key, info_hash, peer_id, port, uploaded, downloaded, left
- Event parameter: started, completed, stopped, null (re-announce)
- Per-session key generation (8 hex chars, uniqueness)
- Private flag enforcement: ut_pex omitted for private torrents, included for public
- Tracker error handling: failure reason, missing peers field, invalid peers format, odd-length compact, non-dict root, negative interval
- Warning message parsing, empty peer list, default interval
- Complete/incomplete count parsing, compact peer parsing (single and multi)

### Build integration
- `zig build test` now includes all adversarial and private tracker tests
- `zig build soak-test` added as a dedicated build step for the soak harness
- Made `announce.buildUrl` and `announce.parseResponse` public for external test access

## What was learned
- Zig 0.15 `ArrayList` uses `.empty` initialization and passes allocator per-call, not `.init(allocator)`
- `std.Thread.sleep` replaces `std.time.sleep` in Zig 0.15
- GPA with `enable_memory_limit` exposes `total_requested_bytes` for monitoring
- `/proc/self/fd` iteration is a portable way to count FDs on Linux without system calls

## Key files
- `tests/adversarial_peer_test.zig` — adversarial peer protocol tests
- `tests/private_tracker_test.zig` — private tracker simulation tests
- `tests/soak_test.zig` — soak test harness
- `build.zig` — new test/soak-test build steps
- `src/tracker/announce.zig` — made buildUrl/parseResponse public
- `STATUS.md` — updated testing section
