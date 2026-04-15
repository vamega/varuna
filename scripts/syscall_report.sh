#!/usr/bin/env bash
# syscall_report.sh — Zero-overhead syscall audit using bpftrace
#
# Reports per-phase syscall counts for the varuna daemon:
#   Phase 1: Daemon startup (init, config, event loop creation)
#   Phase 2: Add torrent 1 and download to completion
#   Phase 3: Add torrent 2 and download to completion
#
# bpftrace attaches kernel tracepoints BEFORE the daemon starts,
# so every syscall from the first execve is captured.
#
# Uses comm == "varuna" filter which correctly captures all daemon
# threads (works on WSL2 where bpftrace pid == TID, not TGID).
#
# Requires: sudo, bpftrace >= 0.12, curl, python3, varuna built
#
# Usage:
#   sudo ./scripts/syscall_report.sh
#   sudo TORRENT1=path/to/first.torrent TORRENT2=path/to/second.torrent ./scripts/syscall_report.sh
#
# With SQLite in-memory mode (cleaner results):
#   sudo VARUNA_RESUME_DB=":memory:" ./scripts/syscall_report.sh
#
# With bpftrace -c (single combined report, bpftrace launches daemon):
#   sudo ./scripts/syscall_report.sh --invoke

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARUNA="${ROOT_DIR}/zig-out/bin/varuna"

TORRENT1="${TORRENT1:-${ROOT_DIR}/testdata/torrents/LibreELEC-Generic.x86_64-12.2.1.img.gz.torrent}"
TORRENT2="${TORRENT2:-${ROOT_DIR}/testdata/torrents/kali-linux-installer.torrent}"

API_PORT=19080
PEER_PORT=19881
WORK_DIR=$(mktemp -d -t varuna-syscall-XXXXXX)
DAEMON_PID=""
BPFTRACE_PID=""
INVOKE_MODE=false

for arg in "$@"; do
    case "$arg" in
        --invoke) INVOKE_MODE=true ;;
    esac
done

cleanup() {
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null && wait "$DAEMON_PID" 2>/dev/null || true
    [ -n "$BPFTRACE_PID" ] && kill "$BPFTRACE_PID" 2>/dev/null && wait "$BPFTRACE_PID" 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# ── Shared syscall name map (x86_64) ────────────────────
PARSE_SCRIPT='
import re, sys, json

SYSCALL_NAMES = {
    0:"read", 1:"write", 2:"open", 3:"close", 4:"stat", 5:"fstat",
    6:"lstat", 7:"poll", 8:"lseek", 9:"mmap", 10:"mprotect",
    11:"munmap", 12:"brk", 13:"rt_sigaction", 14:"rt_sigprocmask",
    16:"ioctl", 17:"pread64", 18:"pwrite64", 19:"readv", 20:"writev",
    21:"access", 22:"pipe", 23:"select", 24:"sched_yield",
    28:"madvise", 32:"dup", 33:"dup2", 35:"nanosleep",
    39:"getpid", 41:"socket", 42:"connect", 43:"accept",
    44:"sendto", 45:"recvfrom", 46:"sendmsg", 47:"recvmsg",
    48:"shutdown", 49:"bind", 50:"listen", 51:"getsockname",
    52:"getpeername", 53:"socketpair", 54:"setsockopt", 55:"getsockopt",
    56:"clone", 57:"fork", 58:"vfork", 59:"execve", 60:"exit",
    62:"kill", 72:"fcntl", 74:"fsync", 75:"fdatasync",
    76:"truncate", 77:"ftruncate", 78:"getdents", 79:"getcwd",
    82:"rename", 83:"mkdir", 87:"unlink", 89:"readlink",
    90:"chmod", 91:"fchmod", 95:"umask", 96:"gettimeofday",
    102:"getuid", 104:"getgid", 107:"geteuid", 108:"getegid",
    110:"getppid", 131:"sigaltstack", 157:"prctl",
    186:"gettid", 202:"futex", 217:"getdents64",
    218:"set_tid_address", 228:"clock_gettime", 230:"clock_nanosleep",
    231:"exit_group", 232:"epoll_wait", 233:"epoll_ctl",
    257:"openat", 258:"mkdirat", 262:"newfstatat", 263:"unlinkat",
    264:"renameat", 268:"fchmodat", 280:"utimensat",
    281:"epoll_pwait", 284:"eventfd2", 288:"accept4",
    290:"eventfd2", 291:"epoll_create1", 293:"pipe2",
    302:"prlimit64", 318:"getrandom", 332:"statx",
    334:"rseq", 425:"io_uring_setup", 426:"io_uring_enter",
    427:"io_uring_register", 435:"clone3",
    437:"openat2", 439:"faccessat2",
    285:"fallocate", 292:"dup3", 286:"timerfd_settime",
    283:"timerfd_create",
}

IO_FORBIDDEN = {"connect","accept","accept4","sendto","recvfrom","sendmsg","recvmsg"}
IO_URING_OPS = {"io_uring_setup","io_uring_enter","io_uring_register"}

def parse_bpf_output(filepath, map_prefix):
    """Parse bpftrace output for a given map name prefix."""
    results = {}
    try:
        with open(filepath) as f:
            for line in f:
                m = re.match(rf"@{map_prefix}\[(\d+)\]:\s*(\d+)", line)
                if m:
                    sid, count = int(m.group(1)), int(m.group(2))
                    name = SYSCALL_NAMES.get(sid, f"syscall_{sid}")
                    results[name] = count
    except FileNotFoundError:
        pass
    return results

def print_report(results, phase_name=""):
    if not results:
        print("  (no syscalls captured)")
        return

    uring = {k:v for k,v in results.items() if k in IO_URING_OPS}
    forbidden = {k:v for k,v in results.items() if k in IO_FORBIDDEN}
    other = {k:v for k,v in results.items() if k not in IO_URING_OPS and k not in IO_FORBIDDEN}

    print("  io_uring ops:")
    for k in sorted(uring, key=lambda x: -uring[x]):
        print(f"    {k:30s} {uring[k]:>6}")

    if forbidden:
        print("  \u26a0 DIRECT I/O (should be io_uring):")
        for k in sorted(forbidden, key=lambda x: -forbidden[x]):
            print(f"    {k:30s} {forbidden[k]:>6}")
    else:
        print("  \u2713 No direct I/O syscalls")

    print("  Other syscalls:")
    for k in sorted(other, key=lambda x: -other[x])[:20]:
        print(f"    {k:30s} {other[k]:>6}")
    if len(other) > 20:
        print(f"    ... and {len(other)-20} more")

    print(f"  Total: {sum(results.values())} syscalls")

# Main: parse args and dispatch
import argparse
parser = argparse.ArgumentParser()
parser.add_argument("--file", required=True)
parser.add_argument("--map", required=True)
args = parser.parse_args()
results = parse_bpf_output(args.file, args.map)
print_report(results)
'

wait_for_tcp() {
    for _ in $(seq 1 100); do
        bash -c "exec 3<>/dev/tcp/127.0.0.1/$1" 2>/dev/null && return 0
        sleep 0.1
    done
    echo "timeout waiting for port $1" >&2
    return 1
}

api_login() {
    curl -s -c - "http://127.0.0.1:${API_PORT}/api/v2/auth/login" \
        -d "username=admin&password=adminadmin" 2>/dev/null \
        | grep SID | awk '{print $NF}'
}

api_progress() {
    local sid=$1
    curl -s -b "SID=${sid}" "http://127.0.0.1:${API_PORT}/api/v2/torrents/info" 2>/dev/null \
        | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    if d:
        all_done = all(t['progress'] >= 1.0 for t in d)
        print('done' if all_done else 'downloading')
    else:
        print('empty')
except: print('error')
"
}

start_bpftrace() {
    local map_name=$1
    local outfile=$2
    bpftrace -e "
tracepoint:raw_syscalls:sys_enter /comm == \"varuna\"/ {
    @${map_name}[args.id] = count();
}
" -o "$outfile" &
    BPFTRACE_PID=$!
    # Wait for probes to attach
    sleep 1
}

stop_bpftrace() {
    if [ -n "$BPFTRACE_PID" ]; then
        kill "$BPFTRACE_PID" 2>/dev/null
        wait "$BPFTRACE_PID" 2>/dev/null || true
        BPFTRACE_PID=""
    fi
}

parse_phase() {
    local file=$1
    local map=$2
    python3 -c "$PARSE_SCRIPT" --file "$file" --map "$map" 2>/dev/null || echo "  (parse error)"
}

# ── Write config ──────────────────────────────────────
mkdir -p "$WORK_DIR/data" "$WORK_DIR/daemon"

RESUME_DB="${VARUNA_RESUME_DB:-${WORK_DIR}/daemon/resume.db}"
cat >"$WORK_DIR/daemon/varuna.toml" <<EOF
[daemon]
api_port = ${API_PORT}
api_bind = "127.0.0.1"
api_username = "admin"
api_password = "adminadmin"
[storage]
data_dir = "$WORK_DIR/data"
resume_db = "${RESUME_DB}"
[network]
port_min = ${PEER_PORT}
port_max = ${PEER_PORT}
encryption = "disabled"
enable_utp = false
EOF

echo ""
echo "================================================================"
echo "        Varuna Syscall Audit Report (eBPF / bpftrace)"
echo "================================================================"
echo ""
echo "Filter:    comm == \"varuna\" (captures all daemon threads)"
echo "Torrents:"
echo "  1: $(basename "$TORRENT1")"
echo "  2: $(basename "$TORRENT2")"
echo "Resume DB: ${RESUME_DB}"
echo ""

# ────────────────────────────────────────────────────────
# --invoke mode: bpftrace -c launches varuna directly
# Single combined report, bpftrace is the parent process.
# ────────────────────────────────────────────────────────
if [ "$INVOKE_MODE" = true ]; then
    echo "Mode: bpftrace -c (single combined report)"
    echo ""
    echo "=== Starting daemon via bpftrace -c ==="

    # bpftrace -c launches the command as a child process.
    # cd to daemon dir first so varuna finds its config, then pass
    # the binary path directly (bpftrace -c rejects shell scripts
    # from user-writable dirs for security reasons).
    cd "$WORK_DIR/daemon"
    bpftrace -c "$VARUNA" -e '
tracepoint:raw_syscalls:sys_enter /comm == "varuna"/ {
    @syscalls[args.id] = count();
}
' -o "$WORK_DIR/bpf_invoke.txt" &
    BPFTRACE_PID=$!
    cd "$ROOT_DIR"

    # Get daemon PID (bpftrace -c spawns it)
    sleep 1
    DAEMON_PID=$(pgrep -x varuna 2>/dev/null | head -1 || true)
    if [ -z "$DAEMON_PID" ]; then
        echo "ERROR: varuna did not start"
        exit 1
    fi

    wait_for_tcp "$API_PORT"
    echo "  Daemon ready (PID $DAEMON_PID)"
    SID=$(api_login)

    # Add torrent 1
    echo ""
    echo "=== Adding Torrent 1: $(basename "$TORRENT1") ==="
    curl -s -b "SID=${SID}" "http://127.0.0.1:${API_PORT}/api/v2/torrents/add" \
        --data-binary @"$TORRENT1" >/dev/null
    for _ in $(seq 1 600); do
        status=$(api_progress "$SID")
        [ "$status" = "done" ] && break
        sleep 1
    done
    echo "  Torrent 1: $status"

    # Add torrent 2
    echo ""
    echo "=== Adding Torrent 2: $(basename "$TORRENT2") ==="
    curl -s -b "SID=${SID}" "http://127.0.0.1:${API_PORT}/api/v2/torrents/add" \
        --data-binary @"$TORRENT2" >/dev/null
    for _ in $(seq 1 600); do
        status=$(api_progress "$SID")
        [ "$status" = "done" ] && break
        sleep 1
    done
    echo "  Torrent 2: $status"

    # Kill daemon → bpftrace -c exits → prints maps
    echo ""
    echo "=== Combined Syscall Report ==="
    kill "$DAEMON_PID" 2>/dev/null
    DAEMON_PID=""
    wait "$BPFTRACE_PID" 2>/dev/null || true
    BPFTRACE_PID=""

    parse_phase "$WORK_DIR/bpf_invoke.txt" "syscalls"
    echo ""
    echo "Report complete."
    exit 0
fi

# ────────────────────────────────────────────────────────
# Default mode: per-phase reports
# bpftrace starts FIRST, attaches tracepoints, THEN daemon starts.
# Every syscall from the first execve is captured.
# ────────────────────────────────────────────────────────
echo "Mode: per-phase (bpftrace attaches before daemon starts)"
echo ""

# ── Phase 1: Startup ─────────────────────────────────
echo "=== PHASE 1: Daemon Startup ==="

# Attach bpftrace BEFORE daemon starts — captures from first syscall
start_bpftrace "phase1" "$WORK_DIR/bpf_phase1.txt"

# NOW start daemon — bpftrace tracepoints already active
(cd "$WORK_DIR/daemon" && "$VARUNA") >"$WORK_DIR/daemon.log" 2>&1 &
DAEMON_PID=$!
echo "  Daemon PID: $DAEMON_PID"

wait_for_tcp "$API_PORT"
echo "  API ready on port $API_PORT"

# End phase 1
stop_bpftrace
echo ""
parse_phase "$WORK_DIR/bpf_phase1.txt" "phase1"

# ── Phase 2: Add torrent 1 ───────────────────────────
echo ""
echo "=== PHASE 2: Torrent 1 ($(basename "$TORRENT1")) ==="

SID=$(api_login)

start_bpftrace "phase2" "$WORK_DIR/bpf_phase2.txt"

curl -s -b "SID=${SID}" "http://127.0.0.1:${API_PORT}/api/v2/torrents/add" \
    --data-binary @"$TORRENT1" >/dev/null

for _ in $(seq 1 600); do
    status=$(api_progress "$SID")
    [ "$status" = "done" ] && break
    sleep 1
done
echo "  Status: $status"

stop_bpftrace
echo ""
parse_phase "$WORK_DIR/bpf_phase2.txt" "phase2"

# ── Phase 3: Add torrent 2 ───────────────────────────
echo ""
echo "=== PHASE 3: Torrent 2 ($(basename "$TORRENT2")) ==="

start_bpftrace "phase3" "$WORK_DIR/bpf_phase3.txt"

curl -s -b "SID=${SID}" "http://127.0.0.1:${API_PORT}/api/v2/torrents/add" \
    --data-binary @"$TORRENT2" >/dev/null

for _ in $(seq 1 600); do
    status=$(api_progress "$SID")
    [ "$status" = "done" ] && break
    sleep 1
done
echo "  Status: $status"

stop_bpftrace
echo ""
parse_phase "$WORK_DIR/bpf_phase3.txt" "phase3"

# ── Summary ───────────────────────────────────────────
echo ""
echo "================================================================"
echo "Report complete. Work dir: $WORK_DIR"
echo "Daemon log: $WORK_DIR/daemon.log"
