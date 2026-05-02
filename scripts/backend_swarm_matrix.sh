#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BACKENDS="${BACKENDS:-io_uring epoll_posix epoll_mmap}"
SWARM_MATRIX_MODE="${SWARM_MATRIX_MODE:-test}"
RUNS="${RUNS:-1}"
if [[ -z "${PAYLOAD_BYTES+x}" ]]; then
  if [[ "$SWARM_MATRIX_MODE" == "perf" ]]; then
    PAYLOAD_BYTES=16777216
  else
    PAYLOAD_BYTES=1048576
  fi
fi
if [[ -z "${TIMEOUT+x}" ]]; then
  if [[ "$SWARM_MATRIX_MODE" == "perf" ]]; then
    TIMEOUT=180
  else
    TIMEOUT=90
  fi
fi
PORT_BASE="${PORT_BASE:-26000}"
if [[ -z "${OUT_DIR+x}" ]]; then
  if [[ "$SWARM_MATRIX_MODE" == "perf" ]]; then
    OUT_DIR="$ROOT_DIR/perf/output/backend-swarm-perf-$(date +%Y%m%d-%H%M%S)"
  else
    OUT_DIR="$ROOT_DIR/perf/output/backend-swarm-$(date +%Y%m%d-%H%M%S)"
  fi
fi
mkdir -p "$OUT_DIR"
OUT_DIR="$(cd "$OUT_DIR" && pwd)"
SUMMARY="$OUT_DIR/summary.tsv"
DEMO_SWARM_SCRIPT="${DEMO_SWARM_SCRIPT:-$ROOT_DIR/scripts/demo_swarm.sh}"

case "$SWARM_MATRIX_MODE" in
  test | perf) ;;
  *)
    echo "SWARM_MATRIX_MODE must be 'test' or 'perf'" >&2
    exit 1
    ;;
esac

if ! [[ "$RUNS" =~ ^[0-9]+$ ]] || [[ "$RUNS" -le 0 ]]; then
  echo "RUNS must be a positive integer" >&2
  exit 1
fi
if [[ "$SWARM_MATRIX_MODE" != "perf" && "$RUNS" != "1" ]]; then
  echo "RUNS is only supported when SWARM_MATRIX_MODE=perf" >&2
  exit 1
fi
if ! [[ "$PAYLOAD_BYTES" =~ ^[0-9]+$ ]] || [[ "$PAYLOAD_BYTES" -le 0 ]]; then
  echo "PAYLOAD_BYTES must be a positive integer" >&2
  exit 1
fi
if ! [[ "$TIMEOUT" =~ ^[0-9]+$ ]] || [[ "$TIMEOUT" -le 0 ]]; then
  echo "TIMEOUT must be a positive integer" >&2
  exit 1
fi
if [[ -z "${BACKENDS// }" ]]; then
  echo "BACKENDS must include at least one backend" >&2
  exit 1
fi
BACKEND_COUNT="$(wc -w <<<"$BACKENDS" | tr -d ' ')"

if [[ "$SWARM_MATRIX_MODE" == "perf" ]]; then
  printf "run\tbackend\tstatus\telapsed_seconds\ttransfer_seconds\tpayload_bytes\tthroughput_mib_s\twork_dir\tlog\n" >"$SUMMARY"
else
  printf "backend\tstatus\telapsed_seconds\ttransfer_seconds\tpayload_bytes\twork_dir\n" >"$SUMMARY"
fi

idx=0
for run in $(seq 1 "$RUNS"); do
  for backend in $BACKENDS; do
    if [[ "$SWARM_MATRIX_MODE" == "perf" ]]; then
      backend_dir="$OUT_DIR/run-$run/$backend"
    else
      backend_dir="$OUT_DIR/$backend"
    fi
    mkdir -p "$backend_dir"

    tracker_port=$((PORT_BASE + idx * 10))
    seed_port=$((tracker_port + 1))
    seed_api_port=$((tracker_port + 2))
    download_port=$((tracker_port + 3))
    download_api_port=$((tracker_port + 4))
    run_log="$backend_dir/run.log"
    backend_skip_build="${SKIP_BUILD:-0}"

    # A single prebuilt daemon binary cannot represent multiple comptime IO
    # backends. `zig build perf-swarm-backends` installs the default binary
    # before invoking this script with SKIP_BUILD=1, so force per-backend
    # rebuilds for multi-backend matrices to keep labels honest.
    if [[ "$backend_skip_build" == "1" && "$BACKEND_COUNT" -gt 1 ]]; then
      backend_skip_build=0
      printf "matrix: overriding SKIP_BUILD=1 for backend %s in a %s-backend run\n" \
        "$backend" "$BACKEND_COUNT" >"$run_log"
    fi

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
        SKIP_BUILD="$backend_skip_build" \
        ZIG_BUILD_EXTRA_ARGS="${ZIG_BUILD_EXTRA_ARGS:-}" \
        bash "$DEMO_SWARM_SCRIPT" >>"$run_log" 2>&1; then
      status="fail"
    fi
    end_ns="$(date +%s%N)"

    elapsed_seconds="$(awk -v elapsed_ns="$((end_ns - start_ns))" 'BEGIN { printf "%.3f", elapsed_ns / 1000000000 }')"
    transfer_seconds="$(awk -F': ' '/^transfer_seconds:/ { value = $2 } END { print value }' "$run_log")"
    payload_bytes="$(awk -F': ' '/^payload_bytes:/ { value = $2 } END { print value }' "$run_log")"
    payload_bytes="${payload_bytes:-$PAYLOAD_BYTES}"
    throughput_mib_s=""
    if [[ -n "${transfer_seconds:-}" ]]; then
      throughput_mib_s="$(awk -v bytes="$payload_bytes" -v seconds="$transfer_seconds" 'BEGIN { if (seconds > 0) printf "%.3f", bytes / 1048576 / seconds }')"
    fi

    if [[ "$SWARM_MATRIX_MODE" == "perf" ]]; then
      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$run" "$backend" "$status" "$elapsed_seconds" "${transfer_seconds:-}" "$payload_bytes" "$throughput_mib_s" "$backend_dir/work" "$run_log" \
        >>"$SUMMARY"
    else
      printf "%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$backend" "$status" "$elapsed_seconds" "${transfer_seconds:-}" "$payload_bytes" "$backend_dir/work" \
        >>"$SUMMARY"
    fi

    if [[ "$status" != "pass" ]]; then
      echo "backend $backend failed; log: $run_log" >&2
      tail -80 "$run_log" >&2 || true
      exit 1
    fi

    idx=$((idx + 1))
  done
done

cat "$SUMMARY"
