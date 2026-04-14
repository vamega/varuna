#!/usr/bin/env bash
# syscall_report.sh — Zero-overhead syscall audit using bpftrace
#
# Reports per-phase syscall counts for the varuna daemon:
#   Phase 1: Daemon startup (init, config, event loop creation)
#   Phase 2: Add torrent 1 and download to completion
#   Phase 3: Add torrent 2 and download to completion
#
# Uses bpftrace (eBPF) for in-kernel tracing — no daemon slowdown.
# Requires: sudo, bpftrace, curl, varuna built in zig-out/bin/
#
# Usage:
#   sudo ./scripts/syscall_report.sh
#   sudo TORRENT1=path/to/first.torrent TORRENT2=path/to/second.torrent ./scripts/syscall_report.sh
#
# With SQLite in-memory mode (cleaner results):
#   sudo VARUNA_RESUME_DB=":memory:" ./scripts/syscall_report.sh

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VARUNA="${ROOT_DIR}/zig-out/bin/varuna"
VARUNA_TOOLS="${ROOT_DIR}/zig-out/bin/varuna-tools"

TORRENT1="${TORRENT1:-${ROOT_DIR}/testdata/torrents/LibreELEC-Generic.x86_64-12.2.1.img.gz.torrent}"
TORRENT2="${TORRENT2:-${ROOT_DIR}/testdata/torrents/kali-linux-installer.torrent}"

API_PORT=19080
PEER_PORT=19881
WORK_DIR=$(mktemp -d -t varuna-syscall-XXXXXX)
PHASE_FILE="${WORK_DIR}/phase"
DAEMON_PID=""
BPFTRACE_PID=""

cleanup() {
    [ -n "$DAEMON_PID" ] && kill "$DAEMON_PID" 2>/dev/null && wait "$DAEMON_PID" 2>/dev/null || true
    [ -n "$BPFTRACE_PID" ] && kill "$BPFTRACE_PID" 2>/dev/null && wait "$BPFTRACE_PID" 2>/dev/null || true
    rm -rf "$WORK_DIR"
}
trap cleanup EXIT

# Syscall number to name mapping (x86_64)
declare -A SYSCALL_NAMES=(
    [0]=read [1]=write [2]=open [3]=close [4]=stat [5]=fstat
    [6]=lstat [7]=poll [8]=lseek [9]=mmap [10]=mprotect
    [11]=munmap [12]=brk [13]=rt_sigaction [14]=rt_sigprocmask
    [16]=ioctl [17]=pread64 [18]=pwrite64 [19]=readv [20]=writev
    [21]=access [22]=pipe [23]=select [24]=sched_yield
    [28]=madvise [32]=dup [33]=dup2 [35]=nanosleep
    [39]=getpid [41]=socket [42]=connect [43]=accept
    [44]=sendto [45]=recvfrom [46]=sendmsg [47]=recvmsg
    [48]=shutdown [49]=bind [50]=listen [51]=getsockname
    [52]=getpeername [53]=socketpair [54]=setsockopt [55]=getsockopt
    [56]=clone [57]=fork [58]=vfork [59]=execve [60]=exit
    [62]=kill [72]=fcntl [74]=fsync [75]=fdatasync
    [76]=truncate [77]=ftruncate [78]=getdents [79]=getcwd
    [82]=rename [83]=mkdir [87]=unlink [89]=readlink
    [90]=chmod [91]=fchmod [95]=umask [96]=gettimeofday
    [102]=getuid [104]=getgid [107]=geteuid [108]=getegid
    [110]=getppid [131]=sigaltstack [157]=prctl
    [186]=gettid [202]=futex [217]=getdents64
    [218]=set_tid_address [228]=clock_gettime [230]=clock_nanosleep
    [231]=exit_group [232]=epoll_wait [233]=epoll_ctl
    [257]=openat [258]=mkdirat [262]=newfstatat [263]=unlinkat
    [264]=renameat [268]=fchmodat [280]=utimensat
    [281]=epoll_pwait [284]=eventfd2 [288]=accept4
    [290]=eventfd2 [291]=epoll_create1 [293]=pipe2
    [302]=prlimit64 [318]=getrandom [332]=statx
    [334]=rseq [425]=io_uring_setup [426]=io_uring_enter
    [427]=io_uring_register [435]=clone3
    [437]=openat2 [439]=faccessat2
    [448]=process_mrelease [449]=futex_waitv
    [451]=cachestat [452]=fchmodat2
    [285]=fallocate [292]=dup3 [286]=timerfd_settime
    [283]=timerfd_create
)

syscall_name() {
    local id=$1
    echo "${SYSCALL_NAMES[$id]:-syscall_$id}"
}

# I/O syscalls that should go through io_uring
IO_SYSCALLS="connect accept accept4 sendto recvfrom sendmsg recvmsg send recv"

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
echo "╔══════════════════════════════════════════════════╗"
echo "║        Varuna Syscall Audit Report (eBPF)        ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "Torrents:"
echo "  1: $(basename "$TORRENT1")"
echo "  2: $(basename "$TORRENT2")"
echo "Resume DB: ${RESUME_DB}"
echo ""

# ── Phase 1: Startup ─────────────────────────────────
echo "=== PHASE 1: Daemon Startup ==="

# Start daemon
(cd "$WORK_DIR/daemon" && "$VARUNA") >"$WORK_DIR/daemon.log" 2>&1 &
DAEMON_PID=$!
sleep 0.5

# Start bpftrace tracing the daemon PID
sudo bpftrace -e "
tracepoint:raw_syscalls:sys_enter /pid == ${DAEMON_PID} || (curtask->real_parent->pid == ${DAEMON_PID})/ {
    @phase1[args.id] = count();
}
tracepoint:raw_syscalls:sys_enter /pid == ${DAEMON_PID} || (curtask->real_parent->pid == ${DAEMON_PID})/ {
    @total[args.id] = count();
}
" -o "$WORK_DIR/bpf_raw.txt" &
BPFTRACE_PID=$!
sleep 1

wait_for_tcp "$API_PORT"

# Snapshot phase 1: kill bpftrace, restart for phase 2
kill "$BPFTRACE_PID" 2>/dev/null; wait "$BPFTRACE_PID" 2>/dev/null || true

# Parse phase 1 results
echo ""
if [ -f "$WORK_DIR/bpf_raw.txt" ]; then
    python3 -c "
import re, sys

syscall_names = {
    0:'read', 1:'write', 2:'open', 3:'close', 5:'fstat', 9:'mmap',
    10:'mprotect', 11:'munmap', 12:'brk', 13:'rt_sigaction',
    14:'rt_sigprocmask', 17:'pread64', 18:'pwrite64', 20:'writev',
    21:'access', 28:'madvise', 39:'getpid', 41:'socket', 42:'connect',
    43:'accept', 44:'sendto', 45:'recvfrom', 46:'sendmsg', 47:'recvmsg',
    48:'shutdown', 49:'bind', 50:'listen', 54:'setsockopt', 55:'getsockopt',
    56:'clone', 59:'execve', 72:'fcntl', 74:'fsync', 75:'fdatasync',
    77:'ftruncate', 83:'mkdir', 96:'gettimeofday', 102:'getuid',
    104:'getgid', 107:'geteuid', 108:'getegid', 110:'getppid',
    131:'sigaltstack', 186:'gettid', 202:'futex', 228:'clock_gettime',
    257:'openat', 262:'newfstatat', 280:'utimensat', 283:'timerfd_create',
    286:'timerfd_settime', 290:'eventfd2', 302:'prlimit64', 318:'getrandom',
    332:'statx', 334:'rseq', 425:'io_uring_setup', 426:'io_uring_enter',
    427:'io_uring_register', 435:'clone3', 285:'fallocate', 51:'getsockname',
    218:'set_tid_address', 231:'exit_group',
}

io_forbidden = {'connect','accept','accept4','sendto','recvfrom','sendmsg','recvmsg'}
io_uring_ops = {'io_uring_setup','io_uring_enter','io_uring_register'}

results = {}
with open('$WORK_DIR/bpf_raw.txt') as f:
    for line in f:
        m = re.match(r'@phase1\[(\d+)\]:\s*(\d+)', line)
        if m:
            sid, count = int(m.group(1)), int(m.group(2))
            name = syscall_names.get(sid, f'syscall_{sid}')
            results[name] = count

if not results:
    print('  (no syscalls captured)')
else:
    # Group: io_uring, allowed, forbidden
    uring = {k:v for k,v in results.items() if k in io_uring_ops}
    forbidden = {k:v for k,v in results.items() if k in io_forbidden}
    other = {k:v for k,v in results.items() if k not in io_uring_ops and k not in io_forbidden}

    print('  io_uring ops:')
    for k in sorted(uring, key=lambda x: -uring[x]):
        print(f'    {k:30s} {uring[k]:>6}')

    if forbidden:
        print('  ⚠ DIRECT I/O (should be io_uring):')
        for k in sorted(forbidden, key=lambda x: -forbidden[x]):
            print(f'    {k:30s} {forbidden[k]:>6}')
    else:
        print('  ✓ No direct I/O syscalls')

    print('  Other syscalls:')
    for k in sorted(other, key=lambda x: -other[x]):
        print(f'    {k:30s} {other[k]:>6}')

    print(f'  Total: {sum(results.values())} syscalls')
" 2>/dev/null || echo "  (parse error)"
fi

# ── Phase 2: Add torrent 1 ───────────────────────────
echo ""
echo "=== PHASE 2: Add Torrent 1 ($(basename "$TORRENT1")) ==="

SID=$(api_login)

# Start fresh bpftrace for phase 2
sudo bpftrace -e "
tracepoint:raw_syscalls:sys_enter /pid == ${DAEMON_PID} || (curtask->real_parent->pid == ${DAEMON_PID})/ {
    @phase2[args.id] = count();
}
" -o "$WORK_DIR/bpf_phase2.txt" &
BPFTRACE_PID=$!
sleep 0.5

curl -s -b "SID=${SID}" "http://127.0.0.1:${API_PORT}/api/v2/torrents/add" \
    --data-binary @"$TORRENT1" >/dev/null

# Wait for completion (max 10 min)
for _ in $(seq 1 600); do
    status=$(api_progress "$SID")
    [ "$status" = "done" ] && break
    sleep 1
done

kill "$BPFTRACE_PID" 2>/dev/null; wait "$BPFTRACE_PID" 2>/dev/null || true

echo ""
if [ -f "$WORK_DIR/bpf_phase2.txt" ]; then
    sed 's/phase1/phase2/g' "$WORK_DIR/bpf_raw.txt" > /dev/null 2>&1 || true
    python3 -c "
import re
syscall_names = {0:'read',1:'write',3:'close',5:'fstat',9:'mmap',10:'mprotect',11:'munmap',12:'brk',13:'rt_sigaction',14:'rt_sigprocmask',17:'pread64',18:'pwrite64',20:'writev',21:'access',28:'madvise',39:'getpid',41:'socket',42:'connect',43:'accept',44:'sendto',45:'recvfrom',46:'sendmsg',47:'recvmsg',48:'shutdown',49:'bind',50:'listen',54:'setsockopt',55:'getsockopt',56:'clone',72:'fcntl',74:'fsync',75:'fdatasync',77:'ftruncate',83:'mkdir',186:'gettid',202:'futex',228:'clock_gettime',257:'openat',262:'newfstatat',283:'timerfd_create',286:'timerfd_settime',290:'eventfd2',302:'prlimit64',318:'getrandom',332:'statx',334:'rseq',425:'io_uring_setup',426:'io_uring_enter',427:'io_uring_register',435:'clone3',285:'fallocate',51:'getsockname',218:'set_tid_address'}
io_forbidden = {'connect','accept','accept4','sendto','recvfrom','sendmsg','recvmsg'}
io_uring_ops = {'io_uring_setup','io_uring_enter','io_uring_register'}
results = {}
with open('$WORK_DIR/bpf_phase2.txt') as f:
    for line in f:
        m = re.match(r'@phase2\[(\d+)\]:\s*(\d+)', line)
        if m:
            sid, count = int(m.group(1)), int(m.group(2))
            name = syscall_names.get(sid, f'syscall_{sid}')
            results[name] = count
if not results:
    print('  (no syscalls captured)')
else:
    uring = {k:v for k,v in results.items() if k in io_uring_ops}
    forbidden = {k:v for k,v in results.items() if k in io_forbidden}
    other = {k:v for k,v in results.items() if k not in io_uring_ops and k not in io_forbidden}
    print('  io_uring ops:')
    for k in sorted(uring, key=lambda x: -uring[x]): print(f'    {k:30s} {uring[k]:>6}')
    if forbidden:
        print('  ⚠ DIRECT I/O (should be io_uring):')
        for k in sorted(forbidden, key=lambda x: -forbidden[x]): print(f'    {k:30s} {forbidden[k]:>6}')
    else: print('  ✓ No direct I/O syscalls')
    print('  Other syscalls:')
    for k in sorted(other, key=lambda x: -other[x])[:15]: print(f'    {k:30s} {other[k]:>6}')
    if len(other) > 15: print(f'    ... and {len(other)-15} more')
    print(f'  Total: {sum(results.values())} syscalls')
" 2>/dev/null || echo "  (parse error)"
fi

# ── Phase 3: Add torrent 2 ───────────────────────────
echo ""
echo "=== PHASE 3: Add Torrent 2 ($(basename "$TORRENT2")) ==="

sudo bpftrace -e "
tracepoint:raw_syscalls:sys_enter /pid == ${DAEMON_PID} || (curtask->real_parent->pid == ${DAEMON_PID})/ {
    @phase3[args.id] = count();
}
" -o "$WORK_DIR/bpf_phase3.txt" &
BPFTRACE_PID=$!
sleep 0.5

curl -s -b "SID=${SID}" "http://127.0.0.1:${API_PORT}/api/v2/torrents/add" \
    --data-binary @"$TORRENT2" >/dev/null

for _ in $(seq 1 600); do
    status=$(api_progress "$SID")
    [ "$status" = "done" ] && break
    sleep 1
done

kill "$BPFTRACE_PID" 2>/dev/null; wait "$BPFTRACE_PID" 2>/dev/null || true

echo ""
if [ -f "$WORK_DIR/bpf_phase3.txt" ]; then
    python3 -c "
import re
syscall_names = {0:'read',1:'write',3:'close',5:'fstat',9:'mmap',10:'mprotect',11:'munmap',12:'brk',13:'rt_sigaction',14:'rt_sigprocmask',17:'pread64',18:'pwrite64',20:'writev',21:'access',28:'madvise',39:'getpid',41:'socket',42:'connect',43:'accept',44:'sendto',45:'recvfrom',46:'sendmsg',47:'recvmsg',48:'shutdown',49:'bind',50:'listen',54:'setsockopt',55:'getsockopt',56:'clone',72:'fcntl',74:'fsync',75:'fdatasync',77:'ftruncate',83:'mkdir',186:'gettid',202:'futex',228:'clock_gettime',257:'openat',262:'newfstatat',283:'timerfd_create',286:'timerfd_settime',290:'eventfd2',302:'prlimit64',318:'getrandom',332:'statx',334:'rseq',425:'io_uring_setup',426:'io_uring_enter',427:'io_uring_register',435:'clone3',285:'fallocate',51:'getsockname',218:'set_tid_address'}
io_forbidden = {'connect','accept','accept4','sendto','recvfrom','sendmsg','recvmsg'}
io_uring_ops = {'io_uring_setup','io_uring_enter','io_uring_register'}
results = {}
with open('$WORK_DIR/bpf_phase3.txt') as f:
    for line in f:
        m = re.match(r'@phase3\[(\d+)\]:\s*(\d+)', line)
        if m:
            sid, count = int(m.group(1)), int(m.group(2))
            name = syscall_names.get(sid, f'syscall_{sid}')
            results[name] = count
if not results:
    print('  (no syscalls captured)')
else:
    uring = {k:v for k,v in results.items() if k in io_uring_ops}
    forbidden = {k:v for k,v in results.items() if k in io_forbidden}
    other = {k:v for k,v in results.items() if k not in io_uring_ops and k not in io_forbidden}
    print('  io_uring ops:')
    for k in sorted(uring, key=lambda x: -uring[x]): print(f'    {k:30s} {uring[k]:>6}')
    if forbidden:
        print('  ⚠ DIRECT I/O (should be io_uring):')
        for k in sorted(forbidden, key=lambda x: -forbidden[x]): print(f'    {k:30s} {forbidden[k]:>6}')
    else: print('  ✓ No direct I/O syscalls')
    print('  Other syscalls:')
    for k in sorted(other, key=lambda x: -other[x])[:15]: print(f'    {k:30s} {other[k]:>6}')
    if len(other) > 15: print(f'    ... and {len(other)-15} more')
    print(f'  Total: {sum(results.values())} syscalls')
" 2>/dev/null || echo "  (parse error)"
fi

echo ""
echo "════════════════════════════════════════════════════"
echo "Report complete. Work dir: $WORK_DIR"
