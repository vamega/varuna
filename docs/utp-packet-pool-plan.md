# uTP Packet Pool and High-Speed Transfer Plan

This plan covers the next uTP memory and retransmission redesign. The goal is
high-speed uploads and downloads with mostly stable memory allocation, bounded
growth, and transport behavior close to libtorrent-rasterbar where that behavior
is mature.

## Goals

- Support high-speed uTP uploads and downloads without an artificial fixed
  retransmit-buffer bottleneck.
- Preallocate uTP packet-pool memory at daemon startup when uTP is enabled.
- Allow coarse bounded pool growth for unusually large active swarms.
- Keep user-facing config understandable. Users should not need to predict uTP
  traffic share, fast peer count, or path RTT.
- Preserve the existing simulation-first model: allocation pressure, ACK
  cleanup, timeout cleanup, and pool exhaustion should be testable in SimIO or
  unit tests.
- Keep daemon hot-path network I/O on the event loop and io_uring path.

## Reference Behavior

libtorrent-rasterbar exposes these uTP settings and defaults:

- `utp_target_delay = 100` milliseconds
- `utp_min_timeout = 500` milliseconds
- `utp_connect_timeout = 3000` milliseconds
- `utp_syn_resends = 2`
- `utp_fin_resends = 2`
- `utp_num_resends = 3`

libtorrent stores live uTP packets as heap packet objects in per-socket
`packet_buffer` sequence maps. Its `packet_pool` is a small reuse cache, not a
hard live-memory budget. Flow control is primarily protocol-driven through
LEDBAT, congestion window, receive window, ACK/SACK cleanup, and resend limits.

Varuna should keep stronger bounded-memory behavior than libtorrent, but borrow
the mature timeout and resend policy.

## Public Config

Add these network config fields:

```toml
[network]
utp_packet_pool_initial_bytes = "64MiB"
utp_packet_pool_max_bytes = "256MiB"
utp_target_delay_ms = 100
utp_min_timeout_ms = 500
utp_connect_timeout_ms = 3000
utp_syn_resends = 2
utp_fin_resends = 2
utp_data_resends = 3
```

Do not expose these as public knobs:

- uTP traffic share
- expected number of fast peers
- sizing RTT

Those inputs are too hard for users to estimate and are likely to produce
folklore tuning. The daemon should distribute a bounded memory budget across the
active sockets based on runtime behavior.

## Byte-Size Parsing

Add a reusable byte-size parser for config values.

Rules:

- Integer values mean raw bytes.
- String values support binary-scaled suffixes:
  - `K`, `KB`, `KiB`
  - `M`, `MB`, `MiB`
  - `G`, `GB`, `GiB`
  - `T`, `TB`, `TiB`
  - `E`, `EB`, `EiB`
- `MB` means MiB, intentionally. Users who need exact decimal byte values can
  specify an integer byte count.
- Parse internally as `u64`.
- Reject decimals, negative values, unknown suffixes, `ZB`/`ZiB`, and overflow.

Keep the parser generic so future config values such as cache sizes and request
budgets can reuse it.

## Pool Design

Add a `UtpPacketPool` owned by `UtpManager`.

Use two public allocation classes:

- Small packet class for SYN, FIN, request, interested, have, extension,
  metadata, and other control traffic.
- MTU packet class for outbound piece data and larger protocol frames.

The small class may use internal bins:

```text
64 B
128 B
256 B
512 B
```

Packets larger than the small threshold use an MTU slot sized to
`utp.max_datagram`.

The pool should preallocate `utp_packet_pool_initial_bytes` at daemon startup
when any uTP direction is enabled. Growth is allowed up to
`utp_packet_pool_max_bytes`, but only in coarse chunks, for example 8 MiB or
16 MiB. Do not fall back to one allocation per packet on the hot path.

The initial split should favor MTU storage because high-speed uploads retain
full-size DATA packets:

```text
small bins: about 25 percent
MTU slots:  about 75 percent
```

Runtime counters should make this split observable so it can be adjusted later
if real swarms show a different pressure pattern.

## Socket Representation

Replace inline retained datagrams in `OutPacket` with packet handles.

Target shape:

```zig
const OutPacketRef = struct {
    seq_nr: u16,
    handle: UtpPacketHandle,
    packet_len: u16,
    payload_len: u16,
    send_time_us: u32,
    retransmit_count: u8,
    acked: bool,
    needs_resend: bool,
};
```

The socket should store metadata and a handle. The packet bytes live in the
pool. ACK/SACK cleanup returns the handle to the pool. Socket teardown returns
all outstanding handles.

This keeps `UtpSocket` small, avoids reserving a full MTU buffer for small
request/control packets, and makes uTP memory pressure explicit.

## Windows and Backpressure

Keep congestion control separate from memory budgeting:

- LEDBAT decides how aggressively a socket should send.
- Peer receive window limits what the remote can accept.
- Packet-pool limits bound local retained memory.

When the pool is healthy:

- Let productive sockets retain enough packets for high throughput.
- Let active upload sockets use MTU slots for retained DATA.
- Let active download sockets use small slots for request/control traffic and
  receive/reorder memory for inbound DATA.

When the pool is pressured:

- Do not retain ACK-only packets.
- Stop packetizing new pending bytes before failing established sockets.
- Prefer established productive sockets over speculative new uTP attempts.
- Restrict idle, lossy, or low-throughput sockets first.
- If a socket repeatedly cannot make progress because of memory pressure, close
  or reset it cleanly and report the pressure.

Per-socket caps should be derived internally from global pool pressure and live
socket behavior. They should not be primary user config.

## Timeout and Resend Policy

Replace the current "close when RTO reaches 60 seconds" rule with explicit
libtorrent-style resend limits.

Defaults:

- SYN resends: 2
- FIN resends: 2
- DATA resends: 3
- connect timeout: 3000 ms
- min timeout: 500 ms
- max timeout cap: 60000 ms
- LEDBAT target delay: 100 ms

On timeout:

- Update LEDBAT loss/timeout state.
- Apply RTO backoff capped at 60 seconds.
- Mark outstanding unacked packets for resend.
- Drop bytes-in-flight accounting for timed-out packets.
- Resend according to congestion/window availability.
- Tear down the socket when resend limits are exceeded.

Unacked packet memory is freed on ACK/SACK or socket teardown, not because a
packet reached an arbitrary age.

## Telemetry and API Visibility

Expose enough counters to tune and debug the pool:

- small pool capacity, used bytes, free bytes, pressure count
- MTU pool capacity, used bytes, free bytes, pressure count
- pool growth count and growth failures
- packet allocation failures by class
- per-socket retained small packet count
- per-socket retained MTU packet count
- retransmit count
- timeout close count
- receive-window-full time or count
- reorder drops
- request starvation count
- TCP versus uTP upload/download rates where already available

Expose these through daemon diagnostics first. `varuna-ctl` can present a human
view after the API shape is stable.

## Testing

Add focused tests before relying on real-torrent runs:

- Byte-size parser accepts valid suffixes and rejects invalid/overflow values.
- Pool preallocation creates the expected small and MTU capacities.
- Small packets use small bins and return handles on ACK.
- MTU packets use MTU slots and return handles on ACK.
- Socket teardown returns all retained handles.
- Pool exhaustion causes packetization backpressure instead of leaks or UAF.
- Pool growth occurs in coarse chunks and respects the max byte budget.
- SYN timeout uses the configured connect timeout.
- SYN/FIN/DATA resend limits close sockets at the expected attempt count.
- Timeout cleanup eventually releases retained packets via socket teardown.
- Existing uTP ACK/SACK, fast retransmit, and extension stripping regressions
  still pass.

Focused validation target:

```sh
zig build test-utp test-safety -Dtls=none
```

Before landing the full implementation:

```sh
zig build test -Dtls=none
zig build -Dtls=none
```

Real-torrent validation should follow after correctness tests pass.

## Implementation Phases

1. Add byte-size parsing and network config fields.
2. Make LEDBAT target delay, min timeout, connect timeout, and resend limits
   configurable with libtorrent-compatible defaults.
3. Add `UtpPacketPool` with small bins and MTU slots.
4. Preallocate the initial pool during daemon startup when uTP is enabled.
5. Convert `UtpSocket` outbound retained packets from inline bytes to pool
   handles.
6. Add pool pressure behavior to uTP packetization.
7. Replace RTO-cap teardown with explicit resend-limit teardown.
8. Add telemetry counters.
9. Add focused unit and simulation tests.
10. Run real-torrent upload/download parity checks against qBittorrent.

## Open Follow-Up

- Decide whether inbound receive/reorder memory should use the same pool or a
  separate receive-side budget. The first implementation can leave existing
  receive storage alone and focus on outbound retained packets.
- Decide whether pool diagnostics belong in existing connection diagnostics or
  a separate uTP diagnostics API.
- Tune the initial small/MTU split using real swarm telemetry.
