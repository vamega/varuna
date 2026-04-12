#!/usr/bin/env bash
# Cross-client conformance test runner.
#
# Builds varuna, starts a Docker Compose swarm with opentracker,
# qBittorrent, and varuna instances, then verifies bidirectional
# data transfer and integrity.
#
# Usage:
#   ./test/docker/run_conformance.sh          # from project root
#   TIMEOUT=120 ./test/docker/run_conformance.sh
#
# Requirements:
#   - Docker with Compose v2 (docker compose)
#   - zig (for building varuna)
#   - curl, sha256sum
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
COMPOSE_FILE="$ROOT_DIR/test/docker/docker-compose.yml"
TIMEOUT="${TIMEOUT:-180}"
POLL_INTERVAL=3
PASS_COUNT=0
FAIL_COUNT=0
TESTS=()

# ── Helpers ──────────────────────────────────────────────────

log()  { printf '[conformance] %s\n' "$*"; }
pass() { log "PASS: $1"; PASS_COUNT=$((PASS_COUNT + 1)); TESTS+=("PASS: $1"); }
fail() { log "FAIL: $1"; FAIL_COUNT=$((FAIL_COUNT + 1)); TESTS+=("FAIL: $1"); }

cleanup() {
  log "cleaning up containers..."
  docker compose -f "$COMPOSE_FILE" down -v --remove-orphans 2>/dev/null || true
}
trap cleanup EXIT

# Login to qBittorrent API (default creds for linuxserver image).
# The linuxserver/qbittorrent image generates a random password on first
# start and prints it to the container log. We try the well-known default
# first; if that fails we extract the generated password from the log.
qbt_login() {
  local host="$1"
  local port="$2"
  local container_name="${3:-}"

  # Attempt 1: default credentials (admin / adminadmin)
  local sid
  sid=$(curl -s -c - "http://${host}:${port}/api/v2/auth/login" \
    -d "username=admin&password=adminadmin" 2>/dev/null \
    | grep SID | awk '{print $NF}')
  if [[ -n "$sid" ]]; then
    echo "$sid"
    return 0
  fi

  # Attempt 2: extract the generated password from container logs
  if [[ -n "$container_name" ]]; then
    local gen_pass
    gen_pass=$(docker compose -f "$COMPOSE_FILE" logs "$container_name" 2>/dev/null \
      | grep -oP 'temporary password.*?:\s*\K\S+' | tail -1)
    if [[ -n "$gen_pass" ]]; then
      sid=$(curl -s -c - "http://${host}:${port}/api/v2/auth/login" \
        -d "username=admin&password=${gen_pass}" 2>/dev/null \
        | grep SID | awk '{print $NF}')
      if [[ -n "$sid" ]]; then
        echo "$sid"
        return 0
      fi
    fi
  fi

  return 1
}

# Login to varuna API.
varuna_login() {
  local host="$1"
  local port="$2"
  local sid
  sid=$(curl -s -c - "http://${host}:${port}/api/v2/auth/login" \
    -d "username=admin&password=adminadmin" 2>/dev/null \
    | grep SID | awk '{print $NF}')
  echo "$sid"
}

# Add a torrent file to a qBittorrent-compatible API.
api_add_torrent() {
  local host="$1"
  local port="$2"
  local sid="$3"
  local torrent_file="$4"
  local save_path="${5:-/downloads}"

  curl -s -b "SID=${sid}" \
    "http://${host}:${port}/api/v2/torrents/add" \
    -F "torrents=@${torrent_file}" \
    -F "savepath=${save_path}" \
    2>/dev/null
}

# Get progress of first torrent from a qBittorrent-compatible API.
api_get_progress() {
  local host="$1"
  local port="$2"
  local sid="$3"

  curl -s -b "SID=${sid}" \
    "http://${host}:${port}/api/v2/torrents/info" 2>/dev/null \
    | sed -n 's/.*"progress":\([0-9.]*\).*/\1/p' | head -1
}

# Wait for a torrent to reach 100% progress.
wait_for_completion() {
  local label="$1"
  local host="$2"
  local port="$3"
  local sid="$4"
  local timeout="$5"
  local elapsed=0

  log "waiting for ${label} to complete (timeout: ${timeout}s)..."
  while [[ $elapsed -lt $timeout ]]; do
    local progress
    progress=$(api_get_progress "$host" "$port" "$sid")
    if [[ -n "$progress" ]] && awk "BEGIN{exit(!($progress >= 1.0))}"; then
      log "${label} complete (progress=${progress})"
      return 0
    fi
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))
  done

  log "${label} timed out after ${timeout}s (progress=${progress:-unknown})"
  return 1
}

# ── Step 1: Build varuna ─────────────────────────────────────

log "building varuna..."
(cd "$ROOT_DIR" && mise exec -- zig build)
log "build complete"

# ── Step 2: Start compose infrastructure ─────────────────────

log "starting Docker Compose services..."
docker compose -f "$COMPOSE_FILE" build
docker compose -f "$COMPOSE_FILE" up -d

# Wait for all healthchecks to pass
log "waiting for services to become healthy..."
HEALTH_TIMEOUT=120
HEALTH_ELAPSED=0
while [[ $HEALTH_ELAPSED -lt $HEALTH_TIMEOUT ]]; do
  ALL_HEALTHY=true
  for svc in qbittorrent-seed varuna-download varuna-seed qbittorrent-download; do
    STATUS=$(docker compose -f "$COMPOSE_FILE" ps --format json "$svc" 2>/dev/null \
      | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('Health',''))" 2>/dev/null || echo "")
    if [[ "$STATUS" != "healthy" ]]; then
      ALL_HEALTHY=false
      break
    fi
  done
  if $ALL_HEALTHY; then
    log "all services healthy"
    break
  fi
  sleep "$POLL_INTERVAL"
  HEALTH_ELAPSED=$((HEALTH_ELAPSED + POLL_INTERVAL))
done

if [[ $HEALTH_ELAPSED -ge $HEALTH_TIMEOUT ]]; then
  log "services did not become healthy within ${HEALTH_TIMEOUT}s"
  docker compose -f "$COMPOSE_FILE" ps
  docker compose -f "$COMPOSE_FILE" logs --tail=30
  exit 1
fi

# ── Step 3: Copy torrent file out of volume ──────────────────

TORRENT_FILE=$(mktemp /tmp/conformance-XXXXXX.torrent)
docker compose -f "$COMPOSE_FILE" cp setup:/shared/torrents/testfile.torrent "$TORRENT_FILE"
log "extracted torrent file to ${TORRENT_FILE}"

# ── Step 4: Test A -- qBittorrent seeds, varuna downloads ────

log "=== Test A: qBittorrent -> varuna ==="

# Login to qBittorrent seeder and add the torrent
QBT_SEED_SID=$(qbt_login 127.0.0.1 8080 qbittorrent-seed) || {
  fail "qBittorrent seeder login"
  QBT_SEED_SID=""
}

if [[ -n "$QBT_SEED_SID" ]]; then
  api_add_torrent 127.0.0.1 8080 "$QBT_SEED_SID" "$TORRENT_FILE" /downloads
  log "torrent added to qBittorrent seeder"

  # Wait for qBittorrent to finish checking/seeding (data is already in place)
  sleep 5

  # Login to varuna downloader and add the torrent
  VARUNA_DL_SID=$(varuna_login 127.0.0.1 8081) || true
  if [[ -z "$VARUNA_DL_SID" ]]; then
    fail "varuna downloader login"
  else
    api_add_torrent 127.0.0.1 8081 "$VARUNA_DL_SID" "$TORRENT_FILE" /data
    log "torrent added to varuna downloader"

    if wait_for_completion "varuna-download" 127.0.0.1 8081 "$VARUNA_DL_SID" "$TIMEOUT"; then
      # Verify data integrity: compare SHA-256 of original and downloaded file
      ORIG_HASH=$(docker compose -f "$COMPOSE_FILE" exec -T qbittorrent-seed \
        sha256sum /downloads/testfile.bin 2>/dev/null | awk '{print $1}')
      DL_HASH=$(docker compose -f "$COMPOSE_FILE" exec -T varuna-download \
        sha256sum /data/testfile.bin 2>/dev/null | awk '{print $1}')

      if [[ -n "$ORIG_HASH" && "$ORIG_HASH" == "$DL_HASH" ]]; then
        pass "qBittorrent->varuna transfer + integrity"
      else
        fail "qBittorrent->varuna integrity (orig=${ORIG_HASH:-?}, dl=${DL_HASH:-?})"
      fi
    else
      fail "qBittorrent->varuna transfer timed out"
    fi
  fi
else
  fail "qBittorrent->varuna (seeder login failed)"
fi

# ── Step 5: Test B -- varuna seeds, qBittorrent downloads ────

log "=== Test B: varuna -> qBittorrent ==="

# Login to varuna seeder and add the torrent
VARUNA_SEED_SID=$(varuna_login 127.0.0.1 8082) || true
if [[ -z "$VARUNA_SEED_SID" ]]; then
  fail "varuna seeder login"
else
  api_add_torrent 127.0.0.1 8082 "$VARUNA_SEED_SID" "$TORRENT_FILE" /data
  log "torrent added to varuna seeder"

  # Wait for varuna to finish recheck (data is already in place)
  sleep 5

  # Login to qBittorrent downloader and add the torrent
  QBT_DL_SID=$(qbt_login 127.0.0.1 8083 qbittorrent-download) || true
  if [[ -z "$QBT_DL_SID" ]]; then
    fail "qBittorrent downloader login"
  else
    api_add_torrent 127.0.0.1 8083 "$QBT_DL_SID" "$TORRENT_FILE" /downloads
    log "torrent added to qBittorrent downloader"

    if wait_for_completion "qbittorrent-download" 127.0.0.1 8083 "$QBT_DL_SID" "$TIMEOUT"; then
      # Verify data integrity
      ORIG_HASH=$(docker compose -f "$COMPOSE_FILE" exec -T varuna-seed \
        sha256sum /data/testfile.bin 2>/dev/null | awk '{print $1}')
      DL_HASH=$(docker compose -f "$COMPOSE_FILE" exec -T qbittorrent-download \
        sha256sum /downloads/testfile.bin 2>/dev/null | awk '{print $1}')

      if [[ -n "$ORIG_HASH" && "$ORIG_HASH" == "$DL_HASH" ]]; then
        pass "varuna->qBittorrent transfer + integrity"
      else
        fail "varuna->qBittorrent integrity (orig=${ORIG_HASH:-?}, dl=${DL_HASH:-?})"
      fi
    else
      fail "varuna->qBittorrent transfer timed out"
    fi
  fi
fi

# ── Step 6: Report ───────────────────────────────────────────

rm -f "$TORRENT_FILE"

log ""
log "════════════════════════════════════════"
log "  Conformance Test Results"
log "════════════════════════════════════════"
for t in "${TESTS[@]}"; do
  log "  $t"
done
log "────────────────────────────────────────"
log "  Total: $((PASS_COUNT + FAIL_COUNT))  Pass: ${PASS_COUNT}  Fail: ${FAIL_COUNT}"
log "════════════════════════════════════════"

if [[ $FAIL_COUNT -gt 0 ]]; then
  log ""
  log "dumping container logs for debugging..."
  docker compose -f "$COMPOSE_FILE" logs --tail=50
  exit 1
fi

log "all conformance tests passed"
exit 0
