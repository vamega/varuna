# uTP Transport Selection Wiring

## What was done

The uTP protocol was fully implemented (`src/net/utp.zig`, `src/net/ledbat.zig`, `src/net/utp_manager.zig`) and integrated into the event loop (`addUtpPeer()`, `startUtpListener()`), but never actually used -- all three peer discovery sources (DHT, tracker announces, PEX) hardcoded TCP-only connections via `addPeerForTorrent()`. This change wires uTP into the transport selection path so it gets used in practice.

### Changes

1. **Config option** (`src/config.zig`): Added `enable_utp: bool = true` to `Config.Network`. Parsed from TOML config file under `[network]`.

2. **EventLoop fields** (`src/io/event_loop.zig`): Added `utp_enabled: bool` and `utp_transport_counter: u32` fields. The counter provides a simple alternating 50/50 TCP/uTP split for new outbound connections.

3. **Transport selection** (`src/io/event_loop.zig`):
   - `selectTransport()` -- returns `.tcp` when uTP is disabled, alternates TCP/uTP when enabled.
   - `addPeerAutoTransport()` -- dispatches to `addPeerForTorrent()` (TCP) or `addUtpPeer()` (uTP) based on `selectTransport()`, with automatic fallback to TCP if uTP connection fails.

4. **Peer source wiring**:
   - `src/io/dht_handler.zig:80` -- DHT peer discovery now calls `addPeerAutoTransport()`.
   - `src/io/peer_policy.zig:697` -- Tracker announce results now call `addPeerAutoTransport()`.
   - `src/io/protocol.zig:513` -- PEX peer exchange now calls `addPeerAutoTransport()`.

5. **Config flow** (`src/main.zig:95`): `cfg.network.enable_utp` is applied to `shared_el.utp_enabled` at daemon startup.

6. **Proactive UDP listener** (`src/main.zig:198`): The UDP listener start is now conditional on `cfg.network.dht or cfg.network.enable_utp`. If the UDP socket fails to start and uTP was enabled, `utp_enabled` is set to false as a graceful degradation.

7. **Preferences API** (`src/rpc/handlers.zig`):
   - GET `/api/v2/app/preferences` now includes `"enable_utp":true|false`.
   - POST `/api/v2/app/setPreferences` accepts `enable_utp=true|false` (form or JSON) to toggle at runtime.

8. **Documentation** (`docs/future-features.md`): Updated uTP section to mark transport wiring as DONE. Added config example and a new "Advanced Transport Disposition" subsection documenting uTorrent's `bt.transp_disposition` bitfield for future reference.

## Design decisions

- **50/50 alternation** via a simple modulo counter was chosen over more complex strategies (random, weighted, preference-based) because it provides even distribution with zero overhead and is easy to reason about.
- **Fallback to TCP** on uTP failure (e.g., no UDP socket) ensures the `enable_utp` toggle is safe -- worst case, all connections go through TCP.
- **Wrapping counter** (`+%`) avoids overflow concerns for long-running daemons.

## Key code references

- `src/io/event_loop.zig:selectTransport()` -- transport selection logic
- `src/io/event_loop.zig:addPeerAutoTransport()` -- dispatch with fallback
- `src/io/event_loop.zig:addUtpPeer()` -- existing uTP connection path (unchanged)
- `src/config.zig:enable_utp` -- config field
- `src/rpc/handlers.zig:handlePreferences()` -- API GET
- `src/rpc/handlers.zig:handleSetPreferences()` -- API POST

## Tests added

- `src/config.zig`: "default enable_utp is true"
- `src/io/event_loop.zig`: "selectTransport always returns tcp when utp disabled", "selectTransport alternates tcp and utp when enabled", "selectTransport yields approximately 50/50 split"
- `src/rpc/handlers.zig`: "enable_utp form param parsing", "enable_utp json bool parsing"

## Remaining work

- uTP performance tuning: the 50/50 split may not be optimal for all network conditions. A future enhancement could bias toward the transport that shows better throughput.
- The `bt.transp_disposition` bitfield approach (documented in `future-features.md`) would allow separate control of inbound vs outbound and TCP vs uTP independently.
