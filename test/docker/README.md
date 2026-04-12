# Cross-Client Conformance Tests

Docker-based integration tests that verify varuna can transfer data bidirectionally with qBittorrent. The test suite spins up an isolated network with an opentracker instance, then runs two scenarios:

1. **qBittorrent seeds, varuna downloads** -- verifies varuna can download from a real-world client.
2. **varuna seeds, qBittorrent downloads** -- verifies other clients can download from varuna.

Both scenarios verify data integrity via SHA-256 comparison after transfer.

## Prerequisites

- Docker with Compose v2 (`docker compose`)
- Zig (matching the version in `mise.toml`)
- `mise` (for building varuna)
- `curl`, `sha256sum` (standard on most Linux distributions)

## Running

From the project root:

```bash
./test/docker/run_conformance.sh
```

The script will:

1. Build varuna via `zig build`
2. Build the Docker image for varuna
3. Start the compose stack (tracker, qBittorrent instances, varuna instances)
4. Create a 1 MiB random test payload and torrent file
5. Add torrents to seeders and downloaders via their APIs
6. Poll for download completion
7. Verify transferred data matches via SHA-256
8. Report PASS/FAIL for each scenario
9. Tear down all containers and volumes

## Configuration

| Variable   | Default | Description                           |
|------------|---------|---------------------------------------|
| `TIMEOUT`  | `180`   | Seconds to wait for each transfer     |

Example:

```bash
TIMEOUT=300 ./test/docker/run_conformance.sh
```

## Manual Operation

Start the stack without the test runner:

```bash
docker compose -f test/docker/docker-compose.yml up -d
```

Inspect individual services:

```bash
docker compose -f test/docker/docker-compose.yml logs varuna-seed
docker compose -f test/docker/docker-compose.yml exec varuna-download varuna-ctl list
```

Tear down:

```bash
docker compose -f test/docker/docker-compose.yml down -v
```

## Network Layout

| Service               | IP            | Peer Port | API Port |
|-----------------------|---------------|-----------|----------|
| tracker               | 172.28.0.10   | --        | 6969     |
| qbittorrent-seed      | 172.28.0.20   | 6881      | 8080     |
| varuna-download       | 172.28.0.30   | 6882      | 8081     |
| varuna-seed           | 172.28.0.40   | 6883      | 8082     |
| qbittorrent-download  | 172.28.0.50   | 6884      | 8083     |

## Troubleshooting

If tests fail, the runner dumps the last 50 lines of each container's log.
For deeper investigation:

```bash
# Keep containers running after failure (comment out trap in run_conformance.sh)
docker compose -f test/docker/docker-compose.yml logs -f varuna-download
docker compose -f test/docker/docker-compose.yml exec varuna-download varuna-ctl list
```

Common issues:

- **io_uring not available**: The varuna daemon requires a modern Linux kernel with io_uring support. Docker Desktop on macOS may not provide this. Use a native Linux host or a VM with kernel 5.15+.
- **qBittorrent login failure**: The `linuxserver/qbittorrent` image may generate a random admin password on first start. The test runner attempts to extract it from container logs automatically.
- **Tracker whitelist**: opentracker in whitelist mode will reject announces for unknown hashes. The setup container creates the torrent before clients start, so the tracker should accept all announces for the test torrent.
