# io_uring swarm stall self-peer fix

## What changed

- Fixed tracker reannounce ingestion so wildcard-bound daemons skip loopback self-announces on their own listen port instead of connecting to themselves.
- Normalized IPv4-mapped IPv6 addresses in `addressEql`, so duplicate filtering treats `::ffff:127.0.0.1:port` and `127.0.0.1:port` as the same endpoint.
- Added regression coverage for wildcard-bound loopback self peers and same-host different-port peers.
- Mapped `EAFNOSUPPORT` to `AddressFamilyNotSupported` in the IO error translators to avoid `unexpected errno: 97` stack-trace floods if a bad socket-family path is hit again.

## What was learned

- The 256 MiB io_uring swarm timeout was not a sparse-payload artifact after the marker fix. The seed and downloader were each able to ingest their own tracker echo because `0.0.0.0:<port>` did not compare equal to `127.0.0.1:<port>`.
- The failing run showed a seed self-connection followed by millions of `errno 97` stack traces from MSE/plaintext fallback. After the self-peer fix, the same 256 MiB io_uring harness completed in 34.832s and both daemon logs stayed at 12 lines, with no self uTP connect and no errno flood.

## Remaining follow-up

- The transfer is no longer stalled, but throughput is still low for localhost. Now that sparse-payload and self-peer artifacts are removed, rerun the backend throughput matrix and profile the real hot path.
- Consider tracker peer-id-aware self filtering for non-compact peer lists. Compact peers do not carry peer IDs, so endpoint filtering is still needed.

## References

- `src/net/address.zig:8` - IPv4-mapped-aware endpoint equality.
- `src/net/address.zig:28` - self-announce endpoint detection.
- `src/io/peer_policy.zig:1517` - tracker reannounce self-peer skip.
- `src/io/peer_policy.zig:1929` - wildcard loopback self-peer regression.
- `src/io/real_io.zig:907` - `EAFNOSUPPORT` mapping.
- `build.zig:272` - focused peer-policy target includes reannounce regressions.
