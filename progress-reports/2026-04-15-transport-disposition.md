# Transport Disposition System

## What changed

Replaced the simple `enable_utp: bool` toggle with a fine-grained `TransportDisposition` packed struct that controls each transport direction independently, inspired by uTorrent's `bt.transp_disposition` bitfield.

### New type: `TransportDisposition` (src/config.zig:11-80)

A `packed struct(u8)` with four boolean flags:
- `outgoing_tcp` (bit 0): allow outgoing TCP connections
- `outgoing_utp` (bit 1): allow outgoing uTP connections
- `incoming_tcp` (bit 2): allow incoming TCP connections
- `incoming_utp` (bit 3): allow incoming uTP connections

Three named presets: `tcp_and_utp` (default, bitfield 15), `tcp_only` (bitfield 5), `utp_only` (bitfield 10).

### Config (src/config.zig Network struct)

New `transport` field accepts preset names: `"tcp_and_utp"`, `"tcp_only"`, `"utp_only"`. Takes precedence over the legacy `enable_utp` boolean when both are set. The `resolveTransportDisposition()` method handles the precedence logic.

### Event loop (src/io/event_loop.zig)

- Replaced `utp_enabled: bool` field with `transport_disposition: TransportDisposition`.
- `selectTransport()` now checks `outgoing_tcp` and `outgoing_utp` flags instead of `utp_enabled`. When both are enabled, alternates 50/50. When only one is enabled, always returns that one.

### Inbound filtering

- `peer_handler.zig:handleAccept`: rejects inbound TCP when `incoming_tcp` is disabled.
- `utp_handler.zig:acceptUtpConnection`: rejects inbound uTP when `incoming_utp` is disabled.

### Daemon startup (src/main.zig)

- Uses `resolveTransportDisposition()` from config.
- UDP listener gated on `transport_disp.toEnableUtp()` instead of `enable_utp`.
- On UDP socket failure, disables both uTP direction flags instead of setting a boolean.

### RPC API (src/rpc/handlers.zig)

- GET preferences returns legacy `enable_utp` plus new granular fields (`outgoing_tcp`, `outgoing_utp`, `incoming_tcp`, `incoming_utp`) and `transport_disposition` integer.
- SET preferences accepts granular fields, integer bitfield, or legacy `enable_utp`. Granular fields take precedence over the legacy toggle.
- `PreferencesUpdate` struct extended with new optional fields.

## What was learned

The packed struct approach maps cleanly to a bitfield integer while keeping the Zig API type-safe. The three-tier precedence (granular > bitfield > legacy) in the API handler keeps backwards compatibility while allowing precise control.

## Remaining issues

- The `startUtpListener()` is still called unconditionally at startup when any uTP direction or DHT is enabled. Dynamically stopping the UDP listener when uTP is runtime-disabled would require draining the UtpManager, which is deferred.
- No `utp_only` preset validation to warn users that disabling all TCP means no fallback for peers that don't support uTP.

## Key code references

- `src/config.zig:11-80` - TransportDisposition type
- `src/config.zig:161-172` - Network.transport field and resolveTransportDisposition()
- `src/io/event_loop.zig:163` - transport_disposition field
- `src/io/event_loop.zig:797-810` - selectTransport() updated logic
- `src/io/peer_handler.zig:47-53` - incoming TCP rejection
- `src/io/utp_handler.zig:236-244` - incoming uTP rejection
- `src/main.zig:114-131` - startup wiring
- `src/rpc/handlers.zig:584-610` - GET preferences output
- `src/rpc/handlers.zig:664-683` - JSON SET handler
- `src/rpc/handlers.zig:744-773` - form SET handler
