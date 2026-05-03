# Control Theory Ideas

## What changed and why

- Captured subsystem-level opportunities where control theory could improve Varuna's BitTorrent behavior.
- Focused the ideas on existing feedback surfaces instead of introducing abstract control terminology without code anchors.
- Ranked adaptive request pipelining and endgame duplicate-request control as the first likely experiments because they are local to the download hot path and can be measured under SimIO.

## What was learned

- Varuna already has several feedback mechanisms: LEDBAT for uTP congestion control, token-bucket rate limiting, tit-for-tat choking, rarest-first selection, endgame claiming, web-seed backoff, DHT query timeouts, and smart-ban trust scoring.
- Several important loops still use fixed constants: request pipeline depth, peers per piece, unchoke slot count, DHT lookup alpha, tracker/DHT requery cadence, HTTP/web-seed concurrency, and web-seed range size.
- The deterministic simulation stack is a strong fit for controller validation. Candidate metrics include completion time, wasted duplicate bytes, false-positive bans, peer fairness, event-loop tick latency, queue depth, and disk/hash backpressure.

## Remaining issues or follow-up

- Design an adaptive per-peer request pipeline controller using block arrival rate, timeout rate, peer throughput, and estimated bandwidth-delay product.
- Add an endgame controller that raises duplicate-request pressure only when estimated tail completion time exceeds a target.
- Evaluate choke/unchoke improvements with hysteresis and fairness constraints before changing BEP-facing behavior.
- Consider peer-source controllers for DHT, trackers, and PEX so peer acquisition targets useful connected peers instead of raw peer count.
- Add backpressure controllers across hashing, disk writes, web seeds, and piece assignment if queue depth or tick latency becomes unstable under load.

## Key references

- `src/io/peer_policy.zig:31` - fixed request pipeline depth.
- `src/io/peer_policy.zig:39` - fixed unchoke and optimistic unchoke intervals.
- `src/io/peer_policy.zig:1406` - tit-for-tat choking recalculation.
- `src/torrent/piece_tracker.zig:264` - piece claiming and endgame entry point.
- `src/net/ledbat.zig:3` - existing delay-based uTP congestion controller.
- `src/net/utp.zig:634` - ACK, RTT, RTO, and retransmission feedback path.
- `src/dht/lookup.zig:14` - fixed DHT lookup alpha.
- `src/dht/dht.zig:28` - fixed DHT query timeout.
- `src/io/web_seed_handler.zig:57` - web-seed range assignment.
- `src/net/web_seed.zig:117` - web-seed exponential backoff.
- `src/io/rate_limiter.zig:22` - token-bucket rate limiter.
- `src/io/event_loop.zig:1868` - central tick loop where many feedback passes run.
