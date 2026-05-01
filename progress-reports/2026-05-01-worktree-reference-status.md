# Worktree Reference-Codebase Status Cleanup

## What changed and why

`scripts/setup-worktree.sh` now keeps the shared `reference-codebases/`
symlink but hides its Git status artifacts after setup. The script marks the
tracked `reference-codebases/*` gitlinks as `skip-worktree` in the worker
checkout index and adds a local exclude for the parent symlink. This prevents
workers from seeing setup-only deletions and an untracked symlink while keeping
owned source, test, and progress-report edits visible.

Verified the behavior with a temporary linked-worktree fixture using local
submodules. No permanent setup regression test is kept in the tree.

## What was learned

Replacing the tracked `reference-codebases/*` gitlink parent with a symlink is
enough for Git to report every gitlink as deleted and the parent symlink as
untracked. Per-submodule symlinks are not a viable alternative: Git rejects a
submodule path that is itself a symbolic link. The narrow fix is to make the
shared-reference overlay explicit local checkout metadata.

## Remaining issues or follow-up

Existing worktrees that already have the old setup artifacts need
`scripts/setup-worktree.sh <worktree-path>` rerun once to apply the local index
and exclude metadata.

## Key code references

- `scripts/setup-worktree.sh:45` - marks reference gitlinks `skip-worktree`
  and ignores the parent symlink locally.
- `AGENTS.md:62` - documents the local Git metadata applied by the setup
  script.
