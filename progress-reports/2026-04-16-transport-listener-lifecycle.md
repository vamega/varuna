# Transport Disposition + Runtime Listener Lifecycle

**Date:** 2026-04-16

## What Changed

Implemented fine-grained transport control (TCP/uTP inbound/outbound) with
runtime listener start/stop.

### Transport disposition
- `TransportDisposition` packed struct with 4 boolean flags matching
  uTorrent's `bt.transp_disposition` bitfield
- TOML config accepts presets (`"all"`, `"tcp_only"`, `"utp_only"`) or
  flag lists (`["tcp_inbound", "tcp_outbound", "utp_outbound"]`)
- Backwards-compatible with `enable_utp` boolean
- Runtime API toggle via `POST /api/v2/app/setPreferences`
- 25 integration tests in `tests/transport_disposition_test.zig`

### Listener lifecycle
- `EventLoop.startTcpListener()` / `stopTcpListener()` — runtime TCP listen
- `EventLoop.startUtpListener()` / `stopUtpListener()` — runtime UDP listen
- `reconcileListeners()` — called after every transport change via API
- Proper cancel-before-close: `IORING_OP_ASYNC_CANCEL` then `IORING_OP_CLOSE`
  instead of raw `posix.close()`. ECANCELED results silenced.

## Key Code References
- `src/config.zig:11-130` — TransportDisposition type
- `src/io/event_loop.zig` — startTcpListener, stopTcpListener, reconcileListeners
- `tests/transport_disposition_test.zig` — 25 integration tests
