#!/usr/bin/env bash
# Initialize a fresh `git worktree` for development.
#
# - Initializes vendor/boringssl and vendor/c-ares (required to build).
# - Symlinks reference-codebases/ from the main checkout (read-only,
#   shared across worktrees to avoid duplicating gigabytes).
#
# Usage: scripts/setup-worktree.sh <worktree-path>
# Example: scripts/setup-worktree.sh .claude/worktrees/my-branch
set -euo pipefail

if [[ $# -ne 1 ]]; then
    echo "usage: $0 <worktree-path>" >&2
    exit 2
fi

WORKTREE="$1"
MAIN_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ ! -d "$WORKTREE" ]]; then
    echo "error: $WORKTREE does not exist (run 'git worktree add' first)" >&2
    exit 1
fi

WORKTREE_ABS="$(cd "$WORKTREE" && pwd)"

if [[ "$WORKTREE_ABS" == "$MAIN_ROOT" ]]; then
    echo "error: refusing to operate on main checkout" >&2
    exit 1
fi

cd "$WORKTREE_ABS"

# Build dependencies: real submodule init (vendored, compiled into daemon).
git submodule update --init --depth 1 vendor/boringssl vendor/c-ares

# Reference codebases: symlink from main (read-only, never modify in worktree).
if [[ -e reference-codebases && ! -L reference-codebases ]]; then
    rm -rf reference-codebases
fi
if [[ ! -L reference-codebases ]]; then
    ln -s "$MAIN_ROOT/reference-codebases" reference-codebases
fi

echo "worktree ready: $WORKTREE_ABS"
