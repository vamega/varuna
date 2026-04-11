#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$(mktemp -d -t varuna-swarm-XXXXXX)}"
TRACKER_PORT="${TRACKER_PORT:-6969}"
SEED_PORT="${SEED_PORT:-6881}"
SEED_API_PORT="${SEED_API_PORT:-8081}"
DOWNLOAD_PORT="${DOWNLOAD_PORT:-6882}"
DOWNLOAD_API_PORT="${DOWNLOAD_API_PORT:-8082}"
TRACKER_PID=""
SEED_DAEMON_PID=""
DOWNLOAD_DAEMON_PID=""

VARUNA="$ROOT_DIR/zig-out/bin/varuna"
VARUNA_TOOLS="$ROOT_DIR/zig-out/bin/varuna-tools"

cleanup() {
  for pid_var in DOWNLOAD_DAEMON_PID SEED_DAEMON_PID TRACKER_PID; do
    local pid="${!pid_var}"
    if [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT

wait_for_tcp() {
  local host="$1"
  local port="$2"

  for _ in $(seq 1 200); do
    if bash -c "exec 3<>/dev/tcp/$host/$port" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
  done

  echo "timed out waiting for $host:$port" >&2
  return 1
}

# Login to a daemon API and return the SID cookie value.
api_login() {
  local port="$1"
  local sid
  sid=$(curl -s -c - "http://127.0.0.1:${port}/api/v2/auth/login" \
    -d "username=admin&password=adminadmin" 2>/dev/null \
    | grep SID | awk '{print $NF}')
  echo "$sid"
}

# Query the torrent list from a daemon and extract the progress of the first torrent.
api_get_progress() {
  local port="$1"
  local sid="$2"
  curl -s -b "SID=${sid}" "http://127.0.0.1:${port}/api/v2/torrents/info" 2>/dev/null \
    | sed 's/.*"progress":\([0-9.]*\).*/\1/'
}

mkdir -p "$WORK_DIR/seed-root" "$WORK_DIR/download-root"
PAYLOAD_PATH="$WORK_DIR/seed-root/fixture.bin"
TORRENT_PATH="$WORK_DIR/fixture.torrent"
TRACKER_LOG="$WORK_DIR/tracker.log"
SEED_LOG="$WORK_DIR/seed.log"
DOWNLOAD_LOG="$WORK_DIR/download.log"

printf 'hello from varuna swarm demo\n' >"$PAYLOAD_PATH"

mise exec -- node "$ROOT_DIR/scripts/create_torrent.mjs" \
  --input "$PAYLOAD_PATH" \
  --output "$TORRENT_PATH" \
  --announce "http://127.0.0.1:$TRACKER_PORT/announce"

mise exec -- zig build >/dev/null

INFO_HASH="$("$VARUNA_TOOLS" inspect "$TORRENT_PATH" | awk -F= '/^info_hash=/{print $2}')"
if [[ -z "$INFO_HASH" ]]; then
  echo "failed to extract torrent info hash" >&2
  exit 1
fi

# ── Start tracker ────────────────────────────────────────
"$ROOT_DIR/scripts/tracker.sh" --host 127.0.0.1 --port "$TRACKER_PORT" --whitelist-hash "$INFO_HASH" >"$TRACKER_LOG" 2>&1 &
TRACKER_PID="$!"
wait_for_tcp 127.0.0.1 "$TRACKER_PORT"

# ── Write per-instance TOML configs ─────────────────────
mkdir -p "$WORK_DIR/seed-daemon" "$WORK_DIR/download-daemon"

cat >"$WORK_DIR/seed-daemon/varuna.toml" <<EOF
[daemon]
api_port = ${SEED_API_PORT}
api_bind = "127.0.0.1"
api_username = "admin"
api_password = "adminadmin"

[storage]
data_dir = "$WORK_DIR/seed-root"
resume_db = "$WORK_DIR/seed-daemon/resume.db"

[network]
port_min = ${SEED_PORT}
port_max = ${SEED_PORT}
dht = false
pex = false
encryption = "disabled"
enable_utp = false
EOF

cat >"$WORK_DIR/download-daemon/varuna.toml" <<EOF
[daemon]
api_port = ${DOWNLOAD_API_PORT}
api_bind = "127.0.0.1"
api_username = "admin"
api_password = "adminadmin"

[storage]
data_dir = "$WORK_DIR/download-root"
resume_db = "$WORK_DIR/download-daemon/resume.db"

[network]
port_min = ${DOWNLOAD_PORT}
port_max = ${DOWNLOAD_PORT}
dht = false
pex = false
encryption = "disabled"
enable_utp = false
EOF

# ── Start seeder daemon ─────────────────────────────────
(cd "$WORK_DIR/seed-daemon" && exec "$VARUNA") >"$SEED_LOG" 2>&1 &
SEED_DAEMON_PID="$!"
wait_for_tcp 127.0.0.1 "$SEED_API_PORT"

# Add the torrent to the seeder
SEED_SID=$(api_login "$SEED_API_PORT")
if [[ -z "$SEED_SID" ]]; then
  echo "failed to log in to seeder daemon API" >&2
  exit 1
fi

curl -s -b "SID=${SEED_SID}" \
  "http://127.0.0.1:${SEED_API_PORT}/api/v2/torrents/add?savepath=$(printf '%s' "$WORK_DIR/seed-root" | sed 's/ /%20/g')" \
  --data-binary @"$TORRENT_PATH" >/dev/null

# Brief pause for the seeder to announce
sleep 2

# ── Start downloader daemon ─────────────────────────────
(cd "$WORK_DIR/download-daemon" && exec "$VARUNA") >"$DOWNLOAD_LOG" 2>&1 &
DOWNLOAD_DAEMON_PID="$!"
wait_for_tcp 127.0.0.1 "$DOWNLOAD_API_PORT"

# Add the torrent to the downloader
DL_SID=$(api_login "$DOWNLOAD_API_PORT")
if [[ -z "$DL_SID" ]]; then
  echo "failed to log in to downloader daemon API" >&2
  exit 1
fi

curl -s -b "SID=${DL_SID}" \
  "http://127.0.0.1:${DOWNLOAD_API_PORT}/api/v2/torrents/add?savepath=$(printf '%s' "$WORK_DIR/download-root" | sed 's/ /%20/g')" \
  --data-binary @"$TORRENT_PATH" >/dev/null

# ── Poll until download completes or timeout ─────────────
TIMEOUT=60
ELAPSED=0
echo "waiting for download to complete (timeout: ${TIMEOUT}s)..."
while [[ $ELAPSED -lt $TIMEOUT ]]; do
  PROGRESS=$(api_get_progress "$DOWNLOAD_API_PORT" "$DL_SID")
  if [[ -n "$PROGRESS" ]] && awk "BEGIN{exit(!($PROGRESS >= 1.0))}"; then
    echo "download complete (progress=${PROGRESS})"
    break
  fi
  sleep 1
  ELAPSED=$((ELAPSED + 1))
done

if [[ $ELAPSED -ge $TIMEOUT ]]; then
  echo "download timed out after ${TIMEOUT}s (progress=${PROGRESS:-unknown})" >&2
  echo "seed log tail:" >&2
  tail -20 "$SEED_LOG" >&2 || true
  echo "download log tail:" >&2
  tail -20 "$DOWNLOAD_LOG" >&2 || true
  exit 1
fi

# ── Verify transferred data ─────────────────────────────
cmp "$PAYLOAD_PATH" "$WORK_DIR/download-root/fixture.bin"

cat <<EOF
swarm demo succeeded
work dir: $WORK_DIR
tracker log: $TRACKER_LOG
seed log: $SEED_LOG
download log: $DOWNLOAD_LOG
EOF
