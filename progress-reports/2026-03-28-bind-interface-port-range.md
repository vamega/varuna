# Bind Interface, Bind Address, and Port Range Support

## What was done

Added three network configuration features essential for private tracker use:

1. **SO_BINDTODEVICE (`bind_device`)**: Restricts all daemon sockets to a specific network interface (e.g., `wg0` for WireGuard VPN). Applied to the peer listen socket, outbound peer connection sockets, and the API server socket.

2. **Bind address (`bind_address`)**: Binds all sockets to a specific local IP address. For the listen socket, replaces `0.0.0.0` with the configured address. For outbound sockets, binds to the local address before connecting.

3. **Port range (`port_min`/`port_max`)**: Replaces the single `port` config with a range. The daemon tries each port in sequence until one succeeds, then reports the actual bound port for tracker announces.

## Key changes

- `src/net/socket.zig` (new): Reusable helpers for `applyBindDevice`, `applyBindAddress`, `applyBindConfig`. Handles EPERM (not root), ENODEV (bad interface), IFNAMSIZ validation.
- `src/config.zig:20-31`: Replaced `port: u16` with `port_min`/`port_max`, added `bind_device`/`bind_address` optional fields.
- `src/main.zig:196-245`: Rewrote `createListenSocket` to iterate the port range, apply bind options, and return the actual bound port.
- `src/main.zig:72-73`: Pass `bind_device`/`bind_address` from config to EventLoop.
- `src/io/event_loop.zig:515`: Apply bind config to outbound peer sockets in `addPeerForTorrent`.
- `src/rpc/server.zig:19-49`: Added `initWithDevice` to apply SO_BINDTODEVICE to the API server socket.

## Design decisions

- Used conventional `setsockopt` rather than `IORING_OP_SETSOCKOPT` (kernel 6.7+) because socket setup is one-time, not hot path. This keeps the minimum kernel requirement lower.
- Created a shared `src/net/socket.zig` module to avoid duplicating bind logic across three call sites.
- Port range iteration closes and retries on `AddressInUse`, but bind_device errors (EPERM, ENODEV) are fatal -- no point retrying with a different port if the interface doesn't exist or permissions are wrong.
- The actual bound port is propagated back to `session_manager.port` so tracker announces report the correct port.

## Testing

- Unit tests in `src/net/socket.zig` for edge cases (empty name, oversized name, invalid address, null config).
- `zig build` and `zig build test` pass.
- `demo_swarm.sh` could not run (opentracker not installed on this system), but this is a pre-existing environment issue.

## Remaining work

- Integration test with a real interface (requires root or CAP_NET_RAW for SO_BINDTODEVICE).
- IPv6 bind_address support is implemented but untested with real IPv6 interfaces.
