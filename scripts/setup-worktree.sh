#!/usr/bin/env bash
# Initialize a fresh `git worktree` for development.
#
# - Initializes vendor/boringssl and vendor/c-ares (required to build).
# - Symlinks reference-codebases/ from the main checkout (read-only,
#   shared across worktrees to avoid duplicating gigabytes).
# - Symlinks .zig-cache/ from the main checkout to avoid per-worktree
#   duplicate compiler cache trees.
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

# Zig cache: shared across worker worktrees. `zig-out/` remains per-worktree
# so branch builds do not overwrite each other's installed binaries.
mkdir -p "$MAIN_ROOT/.zig-cache"
if [[ -L .zig-cache ]]; then
    if [[ "$(readlink .zig-cache)" != "$MAIN_ROOT/.zig-cache" ]]; then
        rm .zig-cache
    fi
elif [[ -e .zig-cache ]]; then
    rm -rf .zig-cache
fi
if [[ ! -L .zig-cache ]]; then
    ln -s "$MAIN_ROOT/.zig-cache" .zig-cache
fi

# The symlink intentionally replaces the parent directory that contains tracked
# gitlink entries. Hide only those reference gitlinks in this worktree index,
# then ignore the parent symlink as local checkout setup metadata.
reference_gitlinks=()
while IFS=$'\t' read -r meta path; do
    mode="${meta%% *}"
    if [[ "$mode" == "160000" ]]; then
        reference_gitlinks+=("$path")
    fi
done < <(git ls-files -s reference-codebases)

if [[ ${#reference_gitlinks[@]} -gt 0 ]]; then
    git update-index --skip-worktree -- "${reference_gitlinks[@]}"
fi

exclude_file="$(git rev-parse --git-path info/exclude)"
mkdir -p "$(dirname "$exclude_file")"
touch "$exclude_file"
add_local_exclude() {
    local pattern="$1"
    local comment="$2"

    if ! grep -qxF "$pattern" "$exclude_file"; then
        {
            echo ""
            echo "# setup-worktree: $comment"
            echo "$pattern"
        } >>"$exclude_file"
    fi
}

if ! grep -qxF "/reference-codebases" "$exclude_file"; then
    add_local_exclude "/reference-codebases" "shared reference-codebases symlink"
fi
add_local_exclude "/.zig-cache" "shared Zig cache symlink"

echo "worktree ready: $WORKTREE_ABS"
