# Ubuntu DHT Fast Resume

## What Changed

- Fixed UDP tracker connected-send plumbing so connected UDP sockets send with no destination address and preserve the real send error instead of reporting a synthetic errno. This was needed before public torrent probes could be trusted.
- Fixed `RealIO.connect` to pass the sockaddr stored in the heap completion, not the stack copy passed into `connect`. This removed intermittent datagram/connect lifetime failures.
- Added `ENOTCONN` / `EDESTADDRREQ` mappings across IO backends so datagram socket failures surface as structured errors instead of noisy unexpected-errno paths.
- Changed torrent startup so normal add/start/restart never infers a full recheck from file presence. Startup now trusts Varuna resume state, or starts with an empty `PieceTracker` when there is no resume bitfield.
- Preserved explicit force-recheck behavior with a one-shot `startup_recheck_requested` flag for the heavyweight stop/start fallback.

## What Was Learned

- The Ubuntu torrent is DHT-dependent in practice. A short probe showed tracker counts remained zero, but DHT quickly found peers: `get_peers for c8295ce6: 28 peers`.
- The previous Ubuntu stall was not DHT bootstrap. DHT had about 180 nodes and returned peers, but the torrent stayed in `checkingDL` because startup forced a full recheck of the freshly preallocated 5.4 GiB file.
- After the fast-resume startup change, the Ubuntu probe entered `downloading` immediately, had 27-28 peers by 15-45 seconds, and reached about 168 MiB downloaded by 120 seconds.
- Current Ubuntu throughput in that short run was only about 1-2 MiB/s, so peer discovery is no longer the blocker, but throughput still needs follow-up.

## Validation

- `zig build test-torrent-session test-recheck --search-prefix /nix/store/hkapr9yav6nx45h1gizasd80gkqv3rqd-sqlite-3.50.2`
- `zig build test --search-prefix /nix/store/hkapr9yav6nx45h1gizasd80gkqv3rqd-sqlite-3.50.2`
- `zig build --search-prefix /nix/store/hkapr9yav6nx45h1gizasd80gkqv3rqd-sqlite-3.50.2`
- Real Ubuntu probe with DHT/PEX enabled on a fresh temp profile.

## Key References

- `src/daemon/torrent_session.zig:223` one-shot explicit startup recheck flag.
- `src/daemon/torrent_session.zig:493` startup now skips recheck unless explicitly requested.
- `src/daemon/torrent_session.zig:562` no-recheck startup builds a trusted or empty `PieceTracker`.
- `src/daemon/session_manager.zig:803` force-recheck fallback sets the explicit startup recheck flag.
- `tests/torrent_session_test.zig:86` regression: normal startup skips recheck even when the target file already exists.
- `src/tracker/udp_executor.zig` connected UDP sendmsg and error propagation fixes.
- `src/io/real_io.zig` connect sockaddr lifetime fix.

## Remaining Follow-Up

- Investigate Ubuntu throughput now that DHT/PEX and startup are working. The short probe downloaded successfully but far slower than Transmission/qBittorrent.
- Decide whether an explicit "import/check existing data" workflow should be added for users who intentionally point Varuna at already-downloaded files.
- Clean up remaining uTP diagnostic noise such as `NoRemoteAddress` during pending send drain.
