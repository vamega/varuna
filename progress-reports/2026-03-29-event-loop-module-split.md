# Event Loop Module Split

## What was done

Split `src/io/event_loop.zig` (2915 lines) into 5 focused modules for maintainability:

- **`src/io/peer_handler.zig`** -- CQE dispatch handlers: `handleAccept`, `handleConnect`, `handleSend`, `handleRecv`, `handleDiskWrite`. These process io_uring completion events for TCP peer connections.

- **`src/io/protocol.zig`** -- Peer wire protocol: `processMessage`, `submitMessage`, `submitHandshakeRecv`, `submitHeaderRecv`, `submitBodyRecv`, `submitExtensionHandshake`, `sendInterestedAndGoActive`, `sendInboundBitfieldOrUnchoke`. Handles BitTorrent message framing, protocol state transitions, and BEP 10 extension handshakes.

- **`src/io/seed_handler.zig`** -- Piece upload (seed mode): `servePieceRequest`, `handleSeedDiskRead`, `flushQueuedResponses`, `sendPieceBlock`. Handles serving pieces to downloading peers with batched sends and piece caching.

- **`src/io/peer_policy.zig`** -- Periodic policy functions: `tryAssignPieces`, `startPieceDownload`, `tryFillPipeline`, `completePieceDownload`, `checkPeerTimeouts`, `checkReannounce`, `recalculateUnchokes`, `processHashResults`, `updateSpeedCounters`. Runs each tick for piece assignment, choking, timeouts, and re-announce.

- **`src/io/utp_handler.zig`** -- uTP transport: All uTP-related functions including `handleUtpRecv`, `handleUtpSend`, `acceptUtpConnection`, `deliverUtpData`, `processUtpInboundHandshake`, packet send/queue, and timeout processing.

`event_loop.zig` retains the `EventLoop` struct definition, all fields, init/deinit, tick/run/stop, peer/torrent management, rate limiting, idle-peer tracking, and internal helpers. It delegates to sub-modules via direct function calls (e.g., `peer_handler.handleConnect(self, ...)`).

## Design approach

Zig does not support splitting struct methods across files. The pattern used:
- Sub-modules export free functions taking `*EventLoop` as their first parameter
- `event_loop.zig` calls these functions from its `dispatch()`, `tick()`, etc.
- Inner types that sub-modules need (`PendingWriteKey`, `PendingPieceRead`, etc.) were changed from private `const` to `pub const`
- Helper methods on EventLoop that sub-modules call (`removePeer`, `getTorrentContext`, `markIdle`, `allocSlot`, etc.) were kept on EventLoop and made `pub`
- One delegation method (`processHashResults`) was added on EventLoop because `torrent_session.zig` calls it externally

## Line counts after split

- `event_loop.zig`: 1011 lines (was 2915)
- `peer_handler.zig`: 404 lines
- `protocol.zig`: 254 lines
- `seed_handler.zig`: 268 lines
- `peer_policy.zig`: 553 lines
- `utp_handler.zig`: 506 lines

## What was learned

- Zig's module system works well for this pattern -- `@import("event_loop.zig").EventLoop` creates clean cross-references without circular dependency issues because Zig resolves types lazily.
- Making inner struct types `pub` is necessary for sub-modules to reference them (e.g., `EventLoop.PendingWriteKey`).
- The `const` keyword for imports at file scope (`const protocol = @import("protocol.zig")`) means sub-modules can also import each other (e.g., `peer_handler` imports `protocol` for `submitHandshakeRecv`).

## Verification

- `zig build`: compiles all three binaries (varuna, varuna-ctl, varuna-tools)
- `zig build test`: all tests pass
- `zig fmt`: all files clean
