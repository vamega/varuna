# Varuna Codebase Review Results (Round 2 — Updated)

Items struck from this list have been fixed. Remaining issues only.

---

## Critical

| # | Finding | Area | File(s) |
|---|---------|------|---------|
| 5 | **UDP tracker: no retry/timeout per BEP 15** -- single send+recv, dropped packet = permanent hang. No exponential backoff. | Protocol | `tracker/udp.zig:40-78` |

---

## High

| # | Finding | Area | File(s) |
|---|---------|------|---------|
| 8 | **DH public key not validated for 0 or 1** -- peer sending pubkey=1 makes shared secret=1 (trivially predictable). Zero check catches pubkey=0 but not pubkey=1 or P-1. | Security | `mse.zig:312-319` |
| 9 | **KRPC `skipValue` has no recursion depth limit** -- separate from the fixed bencode parser; UDP packets with ~750 nesting levels can overflow the stack | Security | `dht/krpc.zig:300-335` |
| 10 | **`setDhtEnabled` races with event loop** -- writes `el.dht_engine = null` from API thread without synchronization while event loop reads it every tick | Memory Safety | `session_manager.zig:111` |
| 11 | **PORT message (id=9) silently discarded** -- DHT peers send PORT to indicate their DHT port; ignoring it means we miss routing table entries | Protocol | `protocol.zig:241` |
| 12 | **No Fast Extension support** -- HAVE_ALL, HAVE_NONE, REJECT_REQUEST (ids 13-17) silently dropped. Seeders sending HAVE_ALL instead of BITFIELD appear to have zero pieces. | Protocol | `protocol.zig` switch |
| 14 | **Dead code: `EventLoop.init()`, `run()`, re-announce infrastructure** -- ~200 lines + 7 struct fields from deleted client.zig path. `setAnnounce()` has zero callers. | Organization | `event_loop.zig`, `peer_policy.zig` |
| 15 | **Config `pipeline_depth` disconnect** -- `Config.Performance.pipeline_depth` defaults to 5 but `peer_policy.zig` hardcodes 64. Config value has no effect. | Organization | `config.zig:83`, `peer_policy.zig:19` |

---

## Medium

| # | Finding | Area | File(s) |
|---|---------|------|---------|
| 16 | **Per-piece heap allocation bypasses PieceBufferPool** -- download-side `alloc(u8, 262144)` hits mmap/munmap. Pool already exists for seed mode. | Performance | `peer_policy.zig:90` |
| 17 | **Per-block 16KB body buffer allocation** -- every PIECE message allocs 16393 bytes from heap then immediately frees after memcpy | Performance | `peer_handler.zig:526-535` |
| 18 | **Hash failure doesn't track per-peer misbehavior** -- bad peer gets piece reassigned indefinitely. No disconnect after N failures. | Protocol | `peer_policy.zig:456-461` |
| 19 | **No anti-snubbing** -- peer that stops sending data wastes a pipeline slot for 60s until timeout | Protocol | `peer_policy.zig` |
| 20 | **Disk-full causes infinite re-download loop** -- ENOSPC on write releases piece back to pool, re-downloaded, re-fails. No escalation or torrent pause. | Robustness | `peer_handler.zig:577-604` |
| 21 | **DHT: no inbound query rate limiting** -- any host can flood with queries, growing send_queue unboundedly | Security | `dht/dht.zig:149` |
| 22 | **DHT: IPv6 token uses only first 4 bytes** -- all nodes in same /32 share tokens, weakening anti-spoofing | Security | `dht/dht.zig:761-767` |
| 23 | **DHT: sequential transaction IDs are predictable** -- enables response spoofing | Security | `dht/dht.zig:723-727` |
| 24 | **UDP tracker discards seeder/leecher counts** -- `_ = leechers; _ = seeders;` means WebAPI shows 0 for UDP-tracked torrents | Protocol | `tracker/udp.zig:87-90` |
| 25 | **Handshake construction duplicated 4+ times** -- `peer_wire.serializeHandshake()` exists but is unused by event loop | Organization | `peer_handler.zig`, `utp_handler.zig`, `metadata_fetch.zig` |
| 26 | **Encrypt-track-send pattern repeated 8+ times** -- should be `encryptAndSubmitTrackedSend()` helper | Organization | `protocol.zig`, `seed_handler.zig`, `peer_handler.zig` |
| 27 | **`completePieceDownload` has 5 identical error cleanup paths** -- should be extracted to helper | Organization | `peer_policy.zig:246-368` |
| 28 | **DHT peer dedup: O(peers x 4096) full array scan** -- should use `peerCountForTorrent()` (O(1)) and address HashSet | Performance | `dht_handler.zig:62-77` |
| 29 | **`orderedRemove(0)` in hot paths** -- O(n) shift in hasher queue, DHT send queue, uTP send queue. Use `swapRemove` or iterate+clear. | Performance | `hasher.zig:282`, `dht_handler.zig:36`, `utp_handler.zig:104` |
| 30 | **Content-Length + body_start can overflow** -- `usize` addition without checked arithmetic | Security | `rpc/server.zig:336` |

---

## Low / Suggestions

| # | Finding | Area |
|---|---------|------|
| 31 | **`allocSlot` O(4096) linear scan** -- use free-slot stack for O(1) | Performance |
| 32 | **`pending_sends` linear scan per send completion** -- use HashMap by send_id | Performance |
| 33 | **Redundant `ring.submit()` before `submit_and_wait`** -- one-line delete | Performance |
| 34 | **`std.time.timestamp()` called 6-8 times per tick** -- cache once | Performance |
| 35 | **event_loop.zig at 2469 lines** -- extract PieceBufferPool, VectoredSendPool, SmallSendPool | Organization |
| 36 | **Two `peer_id.zig` files** -- rename for clarity (gen vs parse) | Organization |
| 37 | **`TorrentIdType` / `TorrentId` dual alias** -- collapse to single name | Organization |
| 38 | **Inline `@import` in function bodies** -- hoist to file-level | Organization |
| 39 | **Dead synchronous functions in `peer_wire.zig`** -- `writeHandshake`, `readHandshake`, `readMessageAlloc` have zero callers | Organization |
| 40 | **Stale comment references `client.zig`** | Organization |
| 41 | **API docs stale** -- setShareLimits and queue endpoints implemented but listed as unsupported | Docs |
| 42 | **DHT doesn't store announced peers (freeloader)** -- `respondAnnouncePeer` validates token but doesn't store peer info | Protocol |
| 43 | **CORS `withCors` has dead concatenation path** -- existing extra_headers returned unchanged | Organization |
| 44 | **No connection backoff for repeatedly failing peers** | Protocol |
| 45 | **API login password compared non-constant-time** | Security |

---

## Testing Gaps

| Priority | Gap |
|----------|-----|
| **#2** | No end-to-end daemon integration test (add torrent -> download -> verify) |
| **#3** | `dht_handler.zig` -- 0 tests. `addressEql`, peer dedup, drain logic untested |
| **#4** | `dht/persistence.zig` -- 1 test. No save/load roundtrip for nodes or config |
| **#5** | `dht.zig` -- `respondAnnouncePeer`, `completeLookup`, `handleResponse` untested |
| **#6** | Preferences API (`handlePreferences`, `handleSetPreferences`) -- 0 tests |
| **#7** | DHT/PEX toggle behavior not tested (disable is one-way, re-enable is no-op) |
| **#8** | Resume DB roundtrip (close -> reopen -> verify loaded pieces) not tested |
| **#9** | `utp_handler.zig` -- 0 tests. `toSendAddr` IPv4-mapped-IPv6 untested |
| **#10** | `tracker_executor.zig` -- 0 tests. Job lifecycle untested |

---

## Fixed in This Round

- ~~#1 Config TOML use-after-free~~ -- `load()` returns `LoadedConfig` keeping parse tree alive
- ~~#2 startPieceDownload leak~~ -- added errdefer for piece_buf/current_piece
- ~~#3 Shell scripts broken~~ -- rewrote to use daemon + varuna-ctl API
- ~~#4 BITFIELD not validated~~ -- length check, spare-bits check added; bad peers disconnected
- ~~#6 UNCHOKE after CHOKE stalls~~ -- calls tryFillPipeline to resume interrupted piece
- ~~#7 Multi-file write fd=-1~~ -- skip spans for do_not_download files
- ~~#13 SO_RCVBUF/SO_SNDBUF~~ -- set 2MB recv / 512KB send on all peer sockets

## Fixed in Round 1

- u32 overflow in block_offset+block_length, max block_length 128KB cap
- Disk write error use-after-free (defers free until spans complete)
- Availability counters decremented on disconnect
- Background announce thread joined in deinit
- announce_result_peers protected by mutex
- CANCEL message handler added
- TCP_NODELAY on all peer sockets
- Bencode: max nesting depth 64, max container elements 500K
- completePiece clears in_progress bit
- Choking: tit-for-tat both modes, 10s interval, optimistic unchoke
- Keep-alive after 90s inactivity
- io_uring COOP_TASKRUN + SINGLE_ISSUER flags
- send_pending gate removed from tryFillPipeline
- Pending disk writes flushed on shutdown
- pipeline_depth 5 -> 64, multi-piece pipelining
