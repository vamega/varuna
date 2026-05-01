# GPT-5.5 Codebase Review

**Date:** 2026-05-01
**Scope:** Read-only multi-agent review of the torrent daemon, protocol paths, storage, DHT/tracker, RPC/API, memory lifetime, performance, and test coverage.

## What changed and why

No product code changed. This report records a static review requested to identify likely bugs, missing torrent-client behavior, testing gaps, memory lifetime risks, performance opportunities, and simplifications.

The review used six specialized subagents:

- io_uring/event-loop compliance
- storage durability and relocation
- BitTorrent peer protocol behavior
- DHT, tracker, NAT, and connectivity
- RPC/qBittorrent WebAPI compatibility and security
- memory, cancellation, and concurrency lifetime

I also did a small local pass to deduplicate findings and verify one peer-slot lifetime issue directly.

## What was learned

The strongest cross-cutting issue is async operation lifetime. Several state machines free buffers, reset slots, or destroy parent objects while io_uring completions may still arrive. The affected areas include metadata fetch, async recheck, HTTP tracker work, UDP tracker work, and some peer-message paths.

Storage correctness also has two high-priority crash/corruption risks: completion state can be persisted before data is durable, and short writes are accepted as complete writes on the hot download path.

BEP 52/v2 support is broader than a stub, but still has important holes in handshake hash selection, outbound hash requests, DHT-discovered peer handshakes, and multi-piece v2 recheck.

The qBittorrent WebAPI surface is substantial, but several endpoints still miss common client semantics such as multi-hash selection, filtered `/torrents/info`, multi-add, and slow-client protection.

## Critical and high-priority bugs

### Resume DB can outrun durable data writes

`completePiece` can mark pieces complete after write CQEs, while those writes are still explicitly not fsynced. Resume state can then be flushed to SQLite before the file data reaches durable storage. After a crash, restart can trust the DB and skip recheck for stale or missing bytes.

Key references:

- `src/io/peer_handler.zig:948`
- `src/io/types.zig:235`
- `src/daemon/torrent_session.zig:2403`
- `src/main.zig:340`
- `src/io/event_loop.zig:1943`
- `src/daemon/torrent_session.zig:482`

Follow-up: persist completion rows only after a successful fsync barrier for the dirty generation, or add a crash-clean marker/epoch that forces recheck when dirty pieces were not durably flushed.

### Hot disk-write path accepts short writes as full writes

The hot disk-write completion path treats any positive result as success and only handles negative results as errors. A partial regular-file write, especially under ENOSPC or delayed allocation pressure, can mark a verified in-memory piece complete even though only part reached disk.

Key references:

- `src/io/peer_handler.zig:907`
- `src/io/peer_handler.zig:927`
- `src/io/peer_handler.zig:948`
- `src/io/peer_policy.zig:791`
- `src/io/peer_policy.zig:1010`
- `src/io/peer_policy.zig:1191`
- `src/io/web_seed_handler.zig:572`
- `src/storage/writer.zig:207`

Follow-up: make `DiskWriteOp` track expected length, remaining bytes, and current offset, then resubmit short writes the way `PieceStore.writePiece` already does.

### Async metadata fetch can free live operation storage

When one metadata peer completes successfully, `verifyAndComplete` releases every slot. `releaseSlot` frees send/receive buffers and resets state even though other slots may still have connect, recv, or send SQEs in flight. Cancellation destroys the whole fetch object immediately and has the same late-CQE risk.

Key references:

- `src/io/metadata_handler.zig:812`
- `src/io/metadata_handler.zig:855`
- `src/io/metadata_handler.zig:899`
- `src/io/metadata_handler.zig:932`
- `src/io/event_loop.zig:2240`

Follow-up: add per-slot generation, active-op counters, canceling/draining state, and deferred destruction after all CQEs retire.

### Async recheck cancellation can destroy objects referenced by CQEs

`cancelRecheckForTorrent` destroys async recheck state while read/hash callbacks may still reference embedded completions, `ReadOp.parent`, buffers, and parent state.

Key references:

- `src/io/event_loop.zig:2164`
- `src/io/recheck.zig:132`
- `src/io/recheck.zig:296`

Follow-up: use the same cancellable state-machine pattern as metadata fetch: generations, active operations, cancel completions, and delayed reclamation.

### UDP tracker executor reuses one completion for concurrent send/recv

`RequestSlot` has one `Completion`, but connect, announce, and scrape paths submit `sendmsg` and `recvmsg` back-to-back with that same object. `RealIO.armCompletion` rejects the second arm as `AlreadyInFlight`, so UDP tracker requests can fail before a response is possible. Cleanup can then reset the slot while the send CQE is still live. The executor also calls raw `posix.connect` on UDP sockets.

Key references:

- `src/tracker/udp_executor.zig:111`
- `src/tracker/udp_executor.zig:428`
- `src/tracker/udp_executor.zig:445`
- `src/tracker/udp_executor.zig:505`
- `src/tracker/udp_executor.zig:531`
- `src/io/real_io.zig:584`

Follow-up: use distinct send/recv/cancel completions, or submit recv only after send completion. Add generation checks and either route UDP connect through the IO abstraction or use unconnected sendmsg with source validation.

### HTTP tracker timeout resets slots before late CQEs drain

`checkTimeouts` calls `completeSlot`, which closes fds and frees/reset slot buffers while connect/send/recv operations may still be in flight. Late callbacks do not have enough generation guarding and can continue the state machine on reset or reused storage.

Key references:

- `src/io/http_executor.zig:309`
- `src/io/http_executor.zig:526`
- `src/io/http_executor.zig:720`
- `src/io/http_executor.zig:796`
- `src/io/http_executor.zig:1004`
- `src/io/http_executor.zig:1029`

Follow-up: introduce closing/timed-out states, targeted `io.cancel`, and delay slot reset until original or cancel CQEs are observed.

### Peer message processing can re-arm a removed peer slot

`peer_handler` and `utp_handler` call `protocol.processMessage`, then unconditionally reset body state and re-arm the peer for another header. But `processMessage` can call `removePeer`, for example on invalid bitfield length or spare bits. That resets the slot to `.free`; the caller can then resurrect it into an active recv state.

Key references:

- `src/io/peer_handler.zig:858`
- `src/io/protocol.zig:127`
- `src/io/protocol.zig:144`
- `src/io/event_loop.zig:1673`
- `src/io/utp_handler.zig:444`

Follow-up: make `processMessage` return a disposition, or check whether the slot is still active before freeing/rearming. Add TCP and uTP malformed-bitfield tests.

### uTP sends can truncate peer-wire messages

The uTP send path stops when `createDataPacket` returns null and then reports success after a partial send. A normal 16 KiB `PIECE` frame can exceed the initial LEDBAT window, leaving the receiver stuck mid length-prefixed BitTorrent message.

Key references:

- `src/io/utp_handler.zig:565`
- `src/io/utp_handler.zig:568`
- `src/io/seed_handler.zig:211`

Follow-up: add a per-uTP-peer stream send queue that resumes unsent bytes on ACK/tick.

### BEP 52/v2 handshake hash selection is incomplete

Outbound TCP/uTP handshakes always use `tc.info_hash`, while truncated v2 hash state is stored separately. For pure-v2 torrents, this appears to send the SHA-1 info-dict hash instead of the BEP 52 truncated SHA-256 hash. DHT v2 searches also reduce discovered peers to `torrent_id`, so the selected swarm hash is lost before TCP/uTP/MSE handshakes.

Key references:

- `src/torrent/info_hash.zig:6`
- `src/io/event_loop.zig:848`
- `src/io/event_loop.zig:1093`
- `src/io/peer_handler.zig:338`
- `src/io/peer_handler.zig:342`
- `src/io/peer_handler.zig:761`
- `src/io/utp_handler.zig:266`
- `src/io/utp_handler.zig:270`
- `src/dht/dht.zig:459`
- `src/dht/dht.zig:545`
- `src/io/dht_handler.zig:52`

Follow-up: carry the selected 20-byte swarm hash through peer discovery and use it for MSE SKEY and BT handshake. Echo the inbound hash variant for inbound peers. Add exact handshake-byte tests for v1, hybrid, and pure-v2 torrents.

### Pure-v2 downloads have no outbound BEP 52 hash_request path

Pure-v2 completion fails closed when leaves are missing, but production code appears to only encode hash requests for rejecting incoming requests rather than asking peers for missing hashes.

Key references:

- `src/io/peer_policy.zig:937`

Follow-up: make the picker request missing leaf hashes before piece data, track in-flight hash requests, and add a pure-v2 multi-piece swarm test.

### Peer handshakes do not validate pstrlen/protocol string

TCP and uTP handshakes validate info hash but not `pstrlen` or `"BitTorrent protocol"`. The metadata fetcher has a stricter validator that could be shared.

Key references:

- `src/io/peer_handler.zig:709`
- `src/io/peer_handler.zig:761`
- `src/io/utp_handler.zig:470`
- `src/io/utp_handler.zig:503`
- `src/io/metadata_handler.zig:489`

Follow-up: add a shared handshake validator and adversarial tests where the info hash matches but the protocol prefix is invalid.

### Relocation can move unrelated data and race active writes

Async move uses `session.save_path` as the source root and hands that whole directory to `MoveJob`. Multiple torrents can share a save path, so moving one torrent can move unrelated files. The move path also pauses/detaches but does not clearly drain pending writes/fsyncs for that torrent before moving data.

Key references:

- `src/daemon/session_manager.zig:1007`
- `src/daemon/session_manager.zig:1018`
- `src/daemon/session_manager.zig:1027`
- `src/daemon/torrent_session.zig:418`
- `src/daemon/torrent_session.zig:2453`
- `src/io/event_loop.zig:968`
- `src/storage/manifest.zig:54`
- `src/storage/move_job.zig:248`
- `src/storage/move_job.zig:252`
- `src/storage/move_job.zig:267`

Follow-up: drive relocation from the torrent manifest file list, not the save-root directory. Add a drain phase that stops assignment, waits for hasher jobs and writes, fsyncs, then moves/reopens storage.

### Relocation ignores fsync failure before deleting source

The move job has a comment noting fsync safety, but drops fsync errors and can unlink the source afterward. Delayed ENOSPC/EIO can surface at fsync, so this can delete the only good copy.

Key references:

- `src/storage/move_job.zig:419`
- `src/storage/move_job.zig:423`
- `src/storage/move_job.zig:426`

Follow-up: propagate fsync errors, never unlink on destination fsync failure, and fsync containing directories after copy/rename/unlink where supported.

### RPC /torrents/export can return a dangling body buffer

The export handler returns `session.torrent_bytes` after dropping the session-manager mutex, while the server stores that slice for async send. A concurrent delete can free those bytes before send completion.

Key references:

- `src/rpc/handlers.zig:2119`
- `src/rpc/server.zig:384`
- `src/daemon/torrent_session.zig:376`

Follow-up: duplicate `.torrent` bytes into request-owned storage, or hold a session read lease/refcount until send completion.

### RPC delete does blocking daemon I/O and SQLite inline

`/torrents/delete?deleteFiles=true` calls into `removeTorrentEx`, then walks/deletes files with `std.fs` and clears resume DB state inline on the RPC path. This violates the current daemon I/O and SQLite-on-event-loop policy and can stall peer/API service.

Key references:

- `src/rpc/server.zig:467`
- `src/rpc/handlers.zig:508`
- `src/rpc/handlers.zig:518`
- `src/daemon/session_manager.zig:382`
- `src/daemon/session_manager.zig:394`
- `src/daemon/session_manager.zig:514`
- `src/daemon/session_manager.zig:537`

Follow-up: queue deletion as an async maintenance job, route filesystem work through io_uring-backed operations, and route SQLite cleanup through the allowed background SQLite path.

### Overlapping tracker announce batches share one in-flight counter

Regular announces guard with `announcing`, but stopped announces bypass that guard and still call `scheduleAnnounceJobs`, which resets `announce_jobs_in_flight`. Older callbacks can decrement the new batch counter or underflow it, leaving state stuck.

Key references:

- `src/daemon/torrent_session.zig:1557`
- `src/daemon/torrent_session.zig:1571`
- `src/daemon/torrent_session.zig:1582`
- `src/daemon/torrent_session.zig:1828`

Follow-up: create announce batch objects with generation and remaining count, or use separate counters for stopped and regular batches.

### PieceStore init can leave fallocates live on submit failure

`PieceStore.init` submits one fallocate per file and later drains completions, but if a later submission fails there is no catch path that drains already-submitted operations. The one-shot backend has a small ring, so large multifile torrents can hit SQ exhaustion and leave completions pointing at freed stack/heap state.

Key references:

- `src/storage/writer.zig:606`
- `src/storage/writer.zig:610`
- `src/storage/writer.zig:622`
- `src/storage/writer.zig:640`
- `src/io/backend.zig:138`
- `src/daemon/torrent_session.zig:1328`

Follow-up: batch by ring capacity or drain all submitted completions on submit error before returning.

## Medium-priority bugs and compatibility gaps

### Async recheck cannot validate multi-piece pure-v2 files

`planPieceVerification` uses an all-zero sentinel for multi-piece v2, but `AsyncRecheck` passes that to the hasher as a direct SHA-256 expected hash. Multi-piece v2 rechecks fail closed instead of verifying the file Merkle root.

Key references:

- `src/storage/verify.zig:127`
- `src/storage/verify.zig:355`
- `src/io/recheck.zig:214`
- `src/io/hasher.zig:243`

Follow-up: add a v2 recheck mode that accumulates per-file piece hashes and verifies `pieces_root`.

### DHT search registry silently caps at 16 hashes

Each hybrid torrent can register two DHT hashes. After 16 hashes, `registerSearch` silently returns, so later public torrents never receive DHT discovery.

Key references:

- `src/dht/dht.zig:267`
- `src/dht/dht.zig:459`
- `src/dht/dht.zig:483`
- `src/dht/dht.zig:488`

Follow-up: use a dynamic bounded registry keyed by hash, or expose/log an explicit configured cap.

### IPv6 DHT announce tokens only bind the first 32 bits

Token generation uses four bytes for both IPv4 and IPv6. For IPv6, only the first four address bytes are bound, allowing token reuse across a shared /32.

Key references:

- `src/dht/dht.zig:670`
- `src/dht/dht.zig:739`
- `src/dht/dht.zig:1153`
- `src/dht/token.zig:46`

Follow-up: bind tokens to all 16 IPv6 address bytes and add same-prefix IPv6 tests.

### uTP/DHT UDP queues are unbounded and drain with orderedRemove(0)

Slow UDP sends or inbound DHT floods can grow memory without bound. Draining from the front with ordered removal makes catch-up quadratic.

Key references:

- `src/io/event_loop.zig:122`
- `src/io/event_loop.zig:268`
- `src/io/utp_handler.zig:123`
- `src/io/utp_handler.zig:145`
- `src/dht/dht.zig:255`
- `src/dht/dht.zig:1108`
- `src/io/dht_handler.zig:36`

Follow-up: use bounded ring queues, drop/backpressure counters, response rate limiting, and head-index draining.

### qBittorrent multi-hash semantics are mostly missing

Handlers accept raw `hashes` but pass it to single-hash manager methods. `hash1|hash2` and `all` will fail or affect nothing for common operations.

Key references:

- `src/rpc/handlers.zig:508`
- `src/daemon/session_manager.zig:305`

Follow-up: add a central `forEachHashOrAll` helper, snapshot hashes for `all`, and use it across plural `hashes` endpoints.

### RPC form/query parsing mutates the request buffer while scanning

`extractParamMut` decodes values in place. If an early decoded value contains `%26` or `%3D`, later scans can split on newly written separators. This is risky for tracker URLs with query strings.

Key references:

- `src/rpc/handlers.zig:1167`
- `src/rpc/handlers.zig:2206`

Follow-up: tokenize raw parameters first, then decode each key/value into arena-owned slices.

### /torrents/add handles only one torrent file or magnet

Multipart handling finds the first matching part, then adds one torrent. qBittorrent clients commonly send multiple `torrents` parts or newline-separated `urls`.

Key references:

- `src/rpc/handlers.zig:494`
- `src/rpc/multipart.zig:221`

Follow-up: iterate all matching multipart parts and split decoded `urls` by newline.

### Slow API clients can exhaust all API slots

The API server has a finite client array, but incomplete headers re-arm recv without a deadline. If `api_bind` is exposed beyond loopback, unauthenticated slow clients can exhaust slots.

Key references:

- `src/rpc/server.zig:12`
- `src/rpc/server.zig:400`

Follow-up: add header/body idle timers, lower header caps, and optional per-IP throttles.

### Some RPC writes do SQLite work on the event-loop path

Category/tag handlers and ban-list persistence call DB writes directly. SQLite is allowed only off the event-loop thread under the current policy.

Key references:

- `src/rpc/handlers.zig:1460`
- `src/rpc/handlers.zig:1554`
- `src/daemon/session_manager.zig:461`

Follow-up: update memory synchronously, then enqueue persistence to the SQLite/background writer path.

### /torrents/info ignores common qBittorrent filters

The route returns all torrents and discards query parameters while docs mark the endpoint full. Missing semantics include `filter`, `category`, `tag`, `sort`, `limit`, `offset`, and `hashes`.

Key references:

- `src/rpc/handlers.zig:215`
- `docs/api-compatibility.md:44`

Follow-up: implement common filters/sort/page fields or downgrade the compatibility doc.

### Web seed Range handling accepts invalid full-body responses

The web seed handler accepts 200 and 206 but does not validate `Content-Range` or exact target byte count. Servers ignoring Range can write the wrong slice or cause hash-fail/backoff loops.

Key references:

- `src/io/web_seed_handler.zig:313`
- `src/io/http_executor.zig:80`

Follow-up: require 206 for nonzero ranges, validate `Content-Range`, and check exact byte count.

### BEP 17 httpseeds are parsed and exposed but not downloaded

Metainfo parses `httpseeds`, and RPC reports them, but runtime initialization only wires `url_list` into `WebSeedManager`.

Key references:

- `src/torrent/metainfo.zig:258`
- `src/daemon/session_manager.zig:1623`
- `src/daemon/torrent_session.zig:655`
- `src/daemon/torrent_session.zig:1017`

Follow-up: implement BEP 17 URL/query behavior or avoid exposing `httpseeds` as active web seeds.

### Choking state can leave uninterested peers unchoked

`NOT_INTERESTED` flips `peer_interested`, but recalculation considers only interested peers and returns early when none exist. Previously unchoked peers can stay unchoked.

Key references:

- `src/io/protocol.zig:92`
- `src/io/peer_policy.zig:1409`
- `src/io/peer_policy.zig:1420`

Follow-up: choke immediately on `NOT_INTERESTED` or sweep all active peers not in the selected unchoke set.

### Metadata fetch duplicates work across slots

`requestNextPiece` uses `nextNeeded`, which checks only received pieces. Multiple peers can request the same first missing metadata piece, reducing useful parallelism.

Key references:

- `src/io/metadata_handler.zig:757`
- `src/net/ut_metadata.zig:353`

Follow-up: add an in-flight/requested bitmap, released on peer failure or reject.

### Malformed fixed-size peer-wire messages are tolerated

Fixed-size messages accept extra payload bytes, and serving allows zero-length block requests.

Key references:

- `src/io/protocol.zig:95`
- `src/io/protocol.zig:166`
- `src/io/protocol.zig:270`
- `src/io/seed_handler.zig:252`

Follow-up: enforce exact BEP 3 payload lengths and reject zero-length block requests.

### PEX advertises inbound peers as seeds

PEX derives seed status from `PeerMode.inbound`, but inbound means connection direction, not remote swarm role.

Key references:

- `src/io/peer_policy.zig:1569`
- `src/io/peer_policy.zig:1584`
- `src/io/types.zig:23`
- `src/io/protocol.zig:160`

Follow-up: derive seed status from remote availability or `upload_only`; leave false when unknown.

### Move-job reverse map can hold borrowed keys into destroyed sessions

`torrent_move_jobs` stores `&session.info_hash_hex` as a `StringHashMap` key. Removing a torrent with a prepared move job can free the session while the map retains a dangling key.

Key references:

- `src/daemon/session_manager.zig:293`
- `src/daemon/session_manager.zig:1022`
- `src/daemon/session_manager.zig:1075`
- `src/daemon/session_manager.zig:1103`

Follow-up: store an owned fixed key such as `[40]u8`, or reject/remove torrents that still have move-job entries before destroying the session.

### MetadataAssembler.setSize can leak on partial allocation failure

The owning-buffer path assigns `self.buffer` before allocating `self.received`. If the second allocation fails, a retry can overwrite and leak the first allocation.

Key references:

- `src/net/ut_metadata.zig:286`
- `src/net/ut_metadata.zig:296`
- `src/io/metadata_handler.zig:672`

Follow-up: allocate into locals with `errdefer`, then assign all fields only after both allocations succeed.

### MoveJob.start can leave a job permanently running if thread spawn fails

State transitions to `.running` before `std.Thread.spawn`. If spawning fails, no thread exists but the job can remain running forever.

Key references:

- `src/storage/move_job.zig:174`
- `src/storage/move_job.zig:181`

Follow-up: on spawn error, restore `.created` or transition to `.failed` under the mutex.

## io_uring policy and performance opportunities

The daemon policy says all daemon networking and file I/O should go through io_uring except narrow listed exceptions. The review found several areas that either violate the policy or deserve an explicit documented exception:

- UDP tracker uses raw `posix.connect`: `src/tracker/udp_executor.zig:428`
- Async relocation uses worker-thread file I/O, `copy_file_range`, and fsync: `src/storage/move_job.zig:383`, `src/storage/move_job.zig:412`, `src/storage/move_job.zig:423`, `src/storage/move_job.zig:475`
- BEP 52 hash serving does peer-triggered disk reads in the hasher pool via `posix.pread`: `src/io/protocol.zig:907`, `src/io/hasher.zig:258`, `src/io/hasher.zig:416`, `src/io/hasher.zig:463`
- The main daemon loop still uses `Thread.sleep` for idle delay: `src/main.zig:375`

Performance improvements worth prioritizing after correctness:

- Download-side peer receive still allocates heap body buffers for large messages, including piece payloads, before copying into piece assembly. Direct-to-piece or reusable scratch buffers would reduce allocation churn.
- Metadata fetch should request distinct pieces across slots instead of duplicating work.
- DHT/uTP queues should use bounded ring buffers instead of unbounded arrays with front removal.
- BEP 52 leaf hashes should be cached/persisted so serving hash requests does not trigger disk reads in the hasher pool.

## Missing or incomplete torrent-client features

The most user-visible missing/incomplete features found in this pass:

- qBittorrent multi-select `hashes` semantics for `all` and pipe-delimited hashes.
- qBittorrent `/torrents/info` filtering, sorting, pagination, and hash selection.
- Multi-add support for multiple uploaded torrent files and newline-separated magnet/URL lists.
- Full BEP 52 pure-v2 download support: correct handshake hash, DHT-selected swarm hash propagation, outbound `hash_request`, and v2 recheck.
- BEP 17 `httpseeds` download behavior.
- Concurrent magnet metadata fetch queueing/retry instead of a single global active fetch that makes other magnets fail or error.
- DHT scalability beyond 16 registered search hashes.

Docs also already list qBittorrent placeholder fields that are still worth replacing over time, including `total_wasted`, average speeds, disk free space, total peer connections, availability, and popularity.

## Testing gaps

Recommended regression tests:

- Crash-before-fsync resume: piece marked complete in DB but file data not durable should force recheck.
- Short write injection on peer/web-seed disk writes should resubmit remaining bytes.
- Metadata fetch success/cancel with another slot parked in recv/send must not free buffers until late CQEs drain.
- Async recheck cancellation with reads in flight must not dereference freed parent state.
- UDP tracker announce/scrape should complete a real send/recv sequence and reject completion reuse regressions.
- HTTP tracker timeout should ignore or drain late CQEs without slot reuse corruption.
- Malformed bitfield should remove a peer and not re-arm the reset slot, for both TCP and uTP.
- uTP 16 KiB+ `PIECE` transfer under a small window should deliver the full length-prefixed message.
- Pure-v2 handshake byte tests for v1, hybrid, and pure-v2 torrents.
- DHT-discovered v2 peers should connect with the selected swarm hash.
- Pure-v2 multi-piece swarm should request hashes, verify leaves, and complete pieces.
- Async recheck should validate multi-piece v2 Merkle roots.
- Relocation from a shared save path should move only that torrent's files.
- Relocation should not unlink source if destination fsync fails.
- RPC export/delete race with a slow receiver should not expose freed torrent bytes.
- qBittorrent `hashes=all` and `hash1|hash2` should affect all intended torrents.
- Query/form parser should preserve tracker URLs containing encoded `&` and `=`.
- `/torrents/add` should accept multiple multipart `torrents` parts and newline-separated URLs.
- API slowloris/incomplete-header clients should time out and release slots.
- DHT registration beyond 16 hashes should either work or fail visibly.
- IPv6 DHT token tests should distinguish same-/32 but different-address peers.
- Web seed Range tests should reject `200 OK` to nonzero Range requests and validate `Content-Range`.
- Metadata assembler allocator-failure test for partial `setSize` allocation.
- `MoveJob.start` thread-spawn failure should leave a recoverable failed/created state.

## Suggested fix order

1. Establish a shared async cancellation/lifetime pattern: per-operation generations, active-operation counters, cancel/drain states, and deferred object destruction.
2. Fix storage durability: short writes first, then DB/fsync ordering or crash-clean epochs.
3. Fix UDP tracker completion ownership and uTP stream-send truncation.
4. Fix peer-slot rearm-after-remove and shared handshake validation.
5. Fix BEP 52 pure-v2 handshake/hash_request/recheck and DHT-selected hash propagation.
6. Rework relocation around manifest-driven moves, write drains, fsync error handling, and io_uring policy compliance.
7. Fix high-value qBittorrent API gaps: multi-hash semantics, `/torrents/info` filters, multi-add, export/delete races.
8. Add bounded DHT/uTP queues, DHT capacity handling, and remaining RPC slow-client protections.

## Remaining issues or follow-up

This was a static review, not a proof. The findings above should be treated as high-confidence leads, but each bug should still be reproduced with a focused test before or alongside the fix.

No build or test command was run for this report.
