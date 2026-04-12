#!/usr/bin/env bash
# validate_strace.sh - Verify daemon I/O routes through io_uring
#
# Usage: ./scripts/validate_strace.sh <strace-summary-file>
#
# Takes a strace summary file produced by: strace -f -c -o <file> ./zig-out/bin/varuna ...
# Parses the syscall table and FAILs if any direct I/O syscalls appear that
# should be going through io_uring (per the io_uring policy in AGENTS.md).

set -euo pipefail

if [ $# -lt 1 ]; then
    echo "Usage: $0 <strace-summary-file>"
    echo ""
    echo "Generate the summary with:"
    echo "  strace -f -c -o strace-summary.txt ./zig-out/bin/varuna ..."
    exit 1
fi

STRACE_FILE="$1"

if [ ! -f "$STRACE_FILE" ]; then
    echo "FAIL: strace file not found: $STRACE_FILE"
    exit 1
fi

# ── Forbidden syscalls (must go through io_uring) ─────────────
#
# These are direct I/O syscalls that the daemon should be submitting
# as io_uring SQEs instead.
FORBIDDEN=(
    "connect"
    "send"
    "sendto"
    "sendmsg"
    "recv"
    "recvfrom"
    "recvmsg"
    "accept"
    "accept4"
)

# ── Allowed syscalls (documented exceptions) ──────────────────
#
# These are expected in strace output and do not violate the io_uring policy:
#   io_uring_enter, io_uring_setup, io_uring_register  - io_uring itself
#   futex, clone, clone3                                - thread sync/creation
#   read, pread64, pwrite64                             - SQLite background thread, logging
#   write, writev, pwritev                              - stdout logging
#   socket, bind, listen, setsockopt, getsockopt        - one-time socket setup
#   openat, close, fstat, newfstatat, statx             - file operations
#   mmap, munmap, mprotect, madvise, brk                - memory management
#   rt_sig*, rseq, getpid, gettid, set_robust_list     - process management
#   epoll_*, eventfd2, timerfd_*                        - epoll/timer setup
#   getrandom, uname, clock_gettime                     - misc
#   fcntl, ioctl, prctl, arch_prctl, set_tid_address   - misc control
#   access, readlink, pipe2, dup3, lseek, ftruncate     - misc file ops
#   sched_*, nanosleep                                  - scheduling
#   exit, exit_group                                    - process exit
#   prlimit64, getrlimit                                - resource limits

# ── Parse strace summary ─────────────────────────────────────
#
# strace -c output looks like:
#   % time     seconds  usecs/call     calls    errors syscall
#   ------ ----------- ----------- --------- --------- ----------------
#    99.70    0.007283          60       121           io_uring_enter
#     0.15    0.000011           0        37           close
#   ...
#   ------ ----------- ----------- --------- --------- ----------------
#   100.00    0.007305                   278        14 total
#
# We extract the syscall name from the last column of non-header, non-total lines.

found_violations=()
found_syscalls=()

while IFS= read -r line; do
    # Skip header lines, separator lines, and the total line
    [[ "$line" =~ ^[[:space:]]*%[[:space:]]time ]] && continue
    [[ "$line" =~ ^[[:space:]]*-+ ]] && continue
    [[ "$line" =~ total[[:space:]]*$ ]] && continue
    [[ -z "$line" ]] && continue

    # Extract the syscall name (last whitespace-delimited field)
    syscall=$(echo "$line" | awk '{print $NF}')
    [ -z "$syscall" ] && continue

    found_syscalls+=("$syscall")

    for forbidden in "${FORBIDDEN[@]}"; do
        if [ "$syscall" = "$forbidden" ]; then
            # In strace -c output the calls column is always field 4.
            calls=$(echo "$line" | awk '{print $4}')
            found_violations+=("$syscall (${calls:-?} calls)")
        fi
    done
done < "$STRACE_FILE"

# ── Report ────────────────────────────────────────────────────

echo "=== io_uring Policy Validation ==="
echo ""
echo "Strace file: $STRACE_FILE"
echo "Syscalls found: ${#found_syscalls[@]}"
echo ""

if [ ${#found_violations[@]} -eq 0 ]; then
    echo "PASS: No forbidden direct I/O syscalls detected."
    echo ""
    echo "All networking and I/O is routing through io_uring as expected."
    exit 0
else
    echo "FAIL: Found ${#found_violations[@]} forbidden syscall(s) that should use io_uring:"
    echo ""
    for violation in "${found_violations[@]}"; do
        echo "  - $violation"
    done
    echo ""
    echo "These syscalls should be submitted as io_uring SQEs instead of"
    echo "being called directly. See AGENTS.md for the io_uring policy."
    echo ""
    echo "Forbidden -> io_uring mapping:"
    echo "  connect    -> IORING_OP_CONNECT"
    echo "  send       -> IORING_OP_SEND"
    echo "  sendto     -> IORING_OP_SEND"
    echo "  sendmsg    -> IORING_OP_SENDMSG"
    echo "  recv       -> IORING_OP_RECV"
    echo "  recvfrom   -> IORING_OP_RECV"
    echo "  recvmsg    -> IORING_OP_RECVMSG"
    echo "  accept     -> IORING_OP_ACCEPT"
    echo "  accept4    -> IORING_OP_ACCEPT"
    exit 1
fi
