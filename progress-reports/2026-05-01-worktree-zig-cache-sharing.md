# Worktree Zig Cache Sharing

## What changed and why

`scripts/setup-worktree.sh` now shares the main checkout's `.zig-cache/` with
worker worktrees by replacing each worker's local `.zig-cache` directory with a
symlink to `$MAIN_ROOT/.zig-cache`. This avoids multi-gigabyte duplicate Zig
compiler cache trees under `.codex/worktrees/*`.

`zig-out/` remains per-worktree. It contains installed binaries and other build
outputs that can differ by branch, so sharing it would make concurrent branch
builds overwrite each other.

The script also adds a local exclude for `/.zig-cache`, because the repository's
`/.zig-cache/` ignore rule does not hide a symlink with that name.

## What was learned

A temporary linked-worktree fixture showed that replacing a real worker
`.zig-cache` directory with a symlink works, but Git reports `?? .zig-cache`
unless the symlink itself is locally excluded.

## Remaining issues or follow-up

Existing worker worktrees need `scripts/setup-worktree.sh <worktree-path>`
rerun once to delete their local `.zig-cache` directories and install the shared
symlink. That will reclaim space from the old per-worktree caches.

## Key code references

- `scripts/setup-worktree.sh:44` - creates the main cache directory and symlinks
  worker `.zig-cache` to it.
- `scripts/setup-worktree.sh:78` - adds local excludes for setup symlinks.
- `AGENTS.md:62` - documents shared `.zig-cache` and per-worktree `zig-out/`.
