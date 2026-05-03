#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="${WORK_DIR:-$(mktemp -d -t varuna-swarm-XXXXXX)}"
TRACKER_PORT="${TRACKER_PORT:-6969}"
SEED_PORT="${SEED_PORT:-6881}"
SEED_API_PORT="${SEED_API_PORT:-8081}"
DOWNLOAD_PORT="${DOWNLOAD_PORT:-6882}"
DOWNLOAD_API_PORT="${DOWNLOAD_API_PORT:-8082}"
# Cross-backend validation hook: when IO_BACKEND is set to a non-default
# value (epoll_posix, epoll_mmap, ...), the daemon binary is rebuilt with
# `-Dio=$IO_BACKEND` after the default io_uring build. The default build
# is still required because varuna-tools (used to create the test
# fixture) is hard-wired to io_uring per AGENTS.md and is not installed
# under non-io_uring backends.
IO_BACKEND="${IO_BACKEND:-io_uring}"
RUNTIME_IO_BACKEND="${RUNTIME_IO_BACKEND:-$IO_BACKEND}"
TRANSPORT_MODE="${TRANSPORT_MODE:-}"
PAYLOAD_BYTES="${PAYLOAD_BYTES:-}"
TIMEOUT="${TIMEOUT:-60}"
SKIP_BUILD="${SKIP_BUILD:-0}"
ZIG_BUILD_EXTRA_ARGS="${ZIG_BUILD_EXTRA_ARGS:-}"
VARUNA_STRACE_DIR="${VARUNA_STRACE_DIR:-}"
TRACKER_PID=""
SEED_DAEMON_PID=""
DOWNLOAD_DAEMON_PID=""
LAUNCHED_PID=""

VARUNA="$ROOT_DIR/zig-out/bin/varuna"
VARUNA_TOOLS="$ROOT_DIR/zig-out/bin/varuna-tools"

terminate_pid() {
  local pid="$1"
  if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
    return 0
  fi

  kill "$pid" 2>/dev/null || true
  for _ in $(seq 1 50); do
    if ! kill -0 "$pid" 2>/dev/null; then
      wait "$pid" 2>/dev/null || true
      return 0
    fi
    sleep 0.1
  done

  kill -KILL "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

cleanup() {
  for pid_var in DOWNLOAD_DAEMON_PID SEED_DAEMON_PID TRACKER_PID; do
    local pid="${!pid_var}"
    terminate_pid "$pid"
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

auto_piece_length() {
  local total_size="$1"
  local target_pieces=1500
  local ideal=$((total_size / target_pieces))
  local piece_length=$((16 * 1024))
  local max_piece_length=$((16 * 1024 * 1024))

  if [[ "$total_size" -eq 0 ]]; then
    echo $((256 * 1024))
    return
  fi

  while [[ "$piece_length" -lt "$max_piece_length" && "$piece_length" -lt "$ideal" ]]; do
    piece_length=$((piece_length * 2))
  done
  echo "$piece_length"
}

write_piece_markers() {
  local payload_path="$1"
  local payload_bytes="$2"
  local piece_length
  piece_length="$(auto_piece_length "$payload_bytes")"

  local offset=0
  while [[ "$offset" -lt "$payload_bytes" ]]; do
    printf '\001' | dd of="$payload_path" bs=1 seek="$offset" conv=notrunc status=none
    offset=$((offset + piece_length))
  done
}

launch_varuna_daemon() {
  local label="$1"
  local daemon_dir="$2"
  local daemon_log="$3"

  if [[ -n "$VARUNA_STRACE_DIR" ]]; then
    local trace_dir
    mkdir -p "$VARUNA_STRACE_DIR"
    trace_dir="$(cd "$VARUNA_STRACE_DIR" && pwd)"
    (cd "$daemon_dir" && exec strace -f -qq -yy \
      -e trace=io_uring_setup,io_uring_enter,io_uring_register,epoll_pwait,read,write,pread64,pwrite64,recvfrom,sendto,recvmsg,sendmsg,connect,accept4,futex \
      -o "$trace_dir/${label}.trace" "$VARUNA") >"$daemon_log" 2>&1 &
  else
    (cd "$daemon_dir" && exec "$VARUNA") >"$daemon_log" 2>&1 &
  fi
  LAUNCHED_PID="$!"
}

mkdir -p "$WORK_DIR/seed-root" "$WORK_DIR/download-root"
PAYLOAD_PATH="$WORK_DIR/seed-root/fixture.bin"
TORRENT_PATH="$WORK_DIR/fixture.torrent"
TRACKER_LOG="$WORK_DIR/tracker.log"
SEED_LOG="$WORK_DIR/seed.log"
DOWNLOAD_LOG="$WORK_DIR/download.log"

if [[ -n "$PAYLOAD_BYTES" ]]; then
  if ! [[ "$PAYLOAD_BYTES" =~ ^[0-9]+$ ]] || [[ "$PAYLOAD_BYTES" -le 0 ]]; then
    echo "PAYLOAD_BYTES must be a positive integer" >&2
    exit 1
  fi
  dd if=/dev/zero of="$PAYLOAD_PATH" bs=1 count=0 seek="$PAYLOAD_BYTES" status=none
  write_piece_markers "$PAYLOAD_PATH" "$PAYLOAD_BYTES"
else
  printf 'hello from varuna swarm demo\n' >"$PAYLOAD_PATH"
fi
PAYLOAD_SIZE="$(wc -c <"$PAYLOAD_PATH" | tr -d ' ')"

case "$TRANSPORT_MODE" in
  "" | all | tcp_and_utp | tcp_only | utp_only) ;;
  *)
    echo "TRANSPORT_MODE must be one of: all, tcp_and_utp, tcp_only, utp_only" >&2
    exit 1
    ;;
esac
if [[ -n "$TRANSPORT_MODE" ]]; then
  TRANSPORT_CONFIG="transport = \"$TRANSPORT_MODE\""
else
  TRANSPORT_CONFIG="enable_utp = true"
fi

# Pick the build wrapper. `mise exec` is the standard path documented in
# AGENTS.md, but the nix-based devshell doesn't ship mise — there `zig`
# is on $PATH directly. Fall through transparently.
if command -v mise >/dev/null 2>&1; then
  ZIG_BUILD=(mise exec -- zig build)
else
  ZIG_BUILD=(zig build)
fi
ZIG_BUILD_ARGS=()
if [[ -n "$ZIG_BUILD_EXTRA_ARGS" ]]; then
  read -r -a ZIG_BUILD_ARGS <<<"$ZIG_BUILD_EXTRA_ARGS"
fi

if [[ "$SKIP_BUILD" != "1" ]]; then
  "${ZIG_BUILD[@]}" "${ZIG_BUILD_ARGS[@]}" >/dev/null

  if [[ "$IO_BACKEND" != "io_uring" ]]; then
    echo "rebuilding varuna with -Dio=$IO_BACKEND (varuna-tools stays io_uring)"
    "${ZIG_BUILD[@]}" "-Dio=$IO_BACKEND" "${ZIG_BUILD_ARGS[@]}" >/dev/null
  fi
fi

"$VARUNA_TOOLS" create \
  -a "http://127.0.0.1:$TRACKER_PORT/announce" \
  -o "$TORRENT_PATH" \
  "$PAYLOAD_PATH"

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
io_backend = "$RUNTIME_IO_BACKEND"
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
encryption = "preferred"
${TRANSPORT_CONFIG}
EOF

cat >"$WORK_DIR/download-daemon/varuna.toml" <<EOF
[daemon]
io_backend = "$RUNTIME_IO_BACKEND"
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
encryption = "preferred"
${TRANSPORT_CONFIG}
EOF

# ── Start seeder daemon ─────────────────────────────────
launch_varuna_daemon seed "$WORK_DIR/seed-daemon" "$SEED_LOG"
SEED_DAEMON_PID="$LAUNCHED_PID"
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
launch_varuna_daemon download "$WORK_DIR/download-daemon" "$DOWNLOAD_LOG"
DOWNLOAD_DAEMON_PID="$LAUNCHED_PID"
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
ELAPSED=0
PROGRESS=""
TRANSFER_START_NS="$(date +%s%N)"
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
TRANSFER_END_NS="$(date +%s%N)"
TRANSFER_SECONDS="$(awk -v elapsed_ns="$((TRANSFER_END_NS - TRANSFER_START_NS))" 'BEGIN { printf "%.3f", elapsed_ns / 1000000000 }')"

# ── Verify transferred data ─────────────────────────────
cmp "$PAYLOAD_PATH" "$WORK_DIR/download-root/fixture.bin"

cat <<EOF
swarm demo succeeded
backend: $RUNTIME_IO_BACKEND
transport_mode: ${TRANSPORT_MODE:-tcp_and_utp}
payload_bytes: $PAYLOAD_SIZE
transfer_seconds: $TRANSFER_SECONDS
work dir: $WORK_DIR
tracker log: $TRACKER_LOG
seed log: $SEED_LOG
download log: $DOWNLOAD_LOG
EOF
