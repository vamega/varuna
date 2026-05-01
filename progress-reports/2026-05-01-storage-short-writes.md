# Storage Short Writes

## What changed and why

The hot disk-write completion callback now treats short positive write completions as incomplete. When a write CQE reports fewer bytes than the submitted slice, the callback reuses the same completion and `DiskWriteOp` to submit the unwritten tail at the advanced file offset instead of decrementing the pending span count.

This covers peer and web-seed disk writes because both paths submit spans through `peer_handler.diskWriteCompleteFor`.

## What was learned

The callback already has the submitted `io_interface.WriteOp` in `Completion.op`, so the retry state does not need another side table: each retry narrows the stored buffer slice and advances the stored offset. Zero-byte writes and real write errors are treated as failed spans so the piece is released after other in-flight spans drain.

## Remaining issues or follow-up

Local test execution is blocked in this aarch64 worktree by existing environment/toolchain issues: native builds hit an existing inline-asm compile failure, the repo's tracked SQLite symlink points at x86_64 system libraries, and x86_64 cross-compiled test artifacts cannot run on this host without a libc runtime/QEMU setup. The new regression was added but could not be executed here.

## Key code references

- `src/io/peer_handler.zig:899` - shared disk-write completion callback
- `src/io/peer_handler.zig:938` - short positive write resubmission
- `src/io/peer_handler.zig:1313` - SimIO regression for short write resubmission
