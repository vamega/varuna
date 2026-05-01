#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKENDS="${BACKENDS:-io_uring epoll_posix epoll_mmap}"
PAYLOAD_BYTES="${PAYLOAD_BYTES:-1048576}"
TIMEOUT="${TIMEOUT:-90}"
PORT_BASE="${PORT_BASE:-26000}"
OUT_DIR="${OUT_DIR:-$ROOT_DIR/perf/output/backend-swarm-$(date +%Y%m%d-%H%M%S)}"
SUMMARY="$OUT_DIR/summary.tsv"

mkdir -p "$OUT_DIR"
printf "backend\tstatus\telapsed_seconds\ttransfer_seconds\tpayload_bytes\twork_dir\n" >"$SUMMARY"

idx=0
for backend in $BACKENDS; do
  backend_dir="$OUT_DIR/$backend"
  mkdir -p "$backend_dir"

  tracker_port=$((PORT_BASE + idx * 10))
  seed_port=$((tracker_port + 1))
  seed_api_port=$((tracker_port + 2))
  download_port=$((tracker_port + 3))
  download_api_port=$((tracker_port + 4))
  run_log="$backend_dir/run.log"

  start_ns="$(date +%s%N)"
  status="pass"
  if ! IO_BACKEND="$backend" \
      RUNTIME_IO_BACKEND="$backend" \
      WORK_DIR="$backend_dir/work" \
      TRACKER_PORT="$tracker_port" \
      SEED_PORT="$seed_port" \
      SEED_API_PORT="$seed_api_port" \
      DOWNLOAD_PORT="$download_port" \
      DOWNLOAD_API_PORT="$download_api_port" \
      PAYLOAD_BYTES="$PAYLOAD_BYTES" \
      TIMEOUT="$TIMEOUT" \
      SKIP_BUILD="${SKIP_BUILD:-0}" \
      ZIG_BUILD_EXTRA_ARGS="${ZIG_BUILD_EXTRA_ARGS:-}" \
      bash "$ROOT_DIR/scripts/demo_swarm.sh" >"$run_log" 2>&1; then
    status="fail"
  fi
  end_ns="$(date +%s%N)"

  elapsed_seconds="$(awk -v elapsed_ns="$((end_ns - start_ns))" 'BEGIN { printf "%.3f", elapsed_ns / 1000000000 }')"
  transfer_seconds="$(awk -F': ' '/^transfer_seconds:/ { value = $2 } END { print value }' "$run_log")"
  payload_bytes="$(awk -F': ' '/^payload_bytes:/ { value = $2 } END { print value }' "$run_log")"
  printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$backend" "$status" "$elapsed_seconds" "${transfer_seconds:-}" "${payload_bytes:-}" "$backend_dir/work" \
    >>"$SUMMARY"

  if [[ "$status" != "pass" ]]; then
    echo "backend $backend failed; log: $run_log" >&2
    tail -80 "$run_log" >&2 || true
    exit 1
  fi

  idx=$((idx + 1))
done

cat "$SUMMARY"
