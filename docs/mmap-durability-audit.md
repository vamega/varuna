# mmap-Backed File-I/O Durability Audit

**Status:** read-only research, no code changes proposed in this branch.

**Worst-severity finding:** **Important** — `EpollMmapIO.fsync` and
`KqueueMmapIO.fsync` issue `msync(MS_SYNC)` only and do *not* follow with
`fsync(fd)` (Linux) or `F_FULLFSYNC` (macOS). This is weaker than the
mmap backends' docstrings imply ("flushes both data and metadata
changes accumulated against the mapping" / "flushes the dirty pages in
the mapping to disk") and weaker than what the daemon callsite
(`PieceStore.sync` in `src/storage/writer.zig:411`) is presumably
asking for. Severity is "important" rather than "critical" today
because (a) `PieceStore.sync` is not actually called from any daemon
code path on either backend (only from a test), (b) both mmap backends
are explicitly dev-only — production targets `io_uring`, and (c) a
standalone power-loss survival claim was never made by either backend's
docstring. `MS_SYNC` does cover process-kill (SIGKILL) durability.

---

## Section 1 — varuna's mmap durability today

### 1.1 EpollMmapIO (Linux)

The `fsync` body lives in `src/io/epoll_mmap_io.zig:675-699`. With a
live mapping (populated lazily on first read/write, see
`src/io/epoll_mmap_io.zig:736-773`):

```zig
const slice: []align(std.heap.page_size_min) u8 = @alignCast(entry.ptr[0..entry.size]);
posix.msync(slice, posix.MSF.SYNC) catch |err| break :blk .{ .fsync = err };
```

That is exactly one `msync(addr, len, MS_SYNC)` over the full
`(ptr, size)` range returned by `mmap` — no `MS_INVALIDATE` bit. With
no mapping (fresh fd that has been `fallocate`'d but not read/written
through this backend), it falls back to `fdatasync` or `fsync`
depending on `op.datasync` at `src/io/epoll_mmap_io.zig:690`. The
mapping itself is `mmap(null, size, PROT.READ | PROT.WRITE,
.{ .TYPE = .SHARED }, fd, 0)` at lines 757-764, with best-effort
`madvise(MADV.WILLNEED)` warm-up at line 768.

**No subsequent `fsync(fd)` is issued.** That is the weakness. On
Linux, `MS_SYNC` schedules I/O on every dirty page of the mapping and
waits for completion at the page level; `fsync(fd)` is the canonical
"flush the inode + its dirty data, then flush the writeback cache"
call. On modern Linux + ext4/xfs the two are practically equivalent
for the mapped data range, but the formal POSIX contract is weaker
and filesystem-defined (tmpfs's msync is a no-op; FUSE is
implementation-defined). One concrete manifestation surfaces in
libtorrent-rasterbar's source: `msync(MS_ASYNC)` is "a no-op on Linux
> 2.6.19" (`reference-codebases/libtorrent/src/mmap.cpp:327`) —
behaviour the POSIX wording does not expose.

`op.datasync` is *ignored* on the mapped path — there is no data-only
msync flag. Dirty metadata accumulated against the mapping (mtime,
size growth from extending writes) is flushed by `MS_SYNC`; metadata
that did not flow through the mapping (e.g. mtime updates from a
separate `utimes` call) is not. The docstring claim at
`src/io/epoll_mmap_io.zig:25-27` ("stronger than fdatasync") therefore
overstates the formal guarantee. Edge case (mapping growth after
`fallocate`/`truncate`) is handled by `write` at lines 657-662
remapping on demand.

#### Truncate + pwrite-then-truncate

`EpollMmapIO.truncate` (`src/io/epoll_mmap_io.zig:724-732`) calls
`self.unmapFile(op.fd)` then `posix.ftruncate(op.fd, op.length)`. There
is no `msync` between the unmap and the truncate. Linux guarantees
that `munmap` does not discard dirty pages — they remain in the
inode's pagecache and are flushed asynchronously — but they are not
durable at the point `truncate` returns. A power loss in that window
could lose them. The probability is low: the daemon's only truncate
callsite is at init time (`src/storage/writer.zig:466`,
`fallocate`-fallback when `EOPNOTSUPP`), not on a path that has dirty
pieces hanging.

The "pwrite then truncate-shrinking-past-the-write" sequence is not
exercised by any daemon path. It would be safe regardless: writes go
into `MAP_SHARED` pagecache; `ftruncate` to a smaller size discards
higher-offset pages (POSIX-mandated) without corrupting the lower
portion.

#### Daemon callsite — `PieceStore.sync`

`PieceStore.sync` (`src/storage/writer.zig:411-443`) submits one
`io.fsync(datasync=true)` per open file. Under EpollMmapIO this
resolves to one `msync(MS_SYNC)` per file (or `fdatasync` if no
mapping exists).

**Side observation:** `PieceStore.sync` is currently invoked from a
single test (`src/storage/writer.zig:741`); no daemon code path calls
it. The daemon's effective durability story today is "the OS pagecache
will eventually write the data; we do not actively ask for a flush" —
across all six backends. The "weaker than documented" finding here is
therefore not exercised in production paths today.

#### Durability claim, EpollMmapIO

| Failure mode      | Survives? | Why                                                                                                           |
| ----------------- | --------- | ------------------------------------------------------------------------------------------------------------- |
| Process kill (SIGKILL) | ✅ Yes after `msync(MS_SYNC)` returns | Dirty pages are scheduled to the block layer; `MS_SYNC` waits for completion. On modern Linux + ext4/xfs, equivalent to `fsync` for the data range. |
| Kernel panic      | ⚠️ Likely yes on ext4/xfs but not contractually guaranteed by POSIX. | `MS_SYNC` flushes pagecache → block layer; without a follow-up `fsync(fd)` the inode-level metadata path is not formally drained. ext4/xfs in practice flush both. |
| Power loss / disk-cache loss | ⚠️ Depends on disk write cache. `msync(MS_SYNC)` flushes to the block device; whether it also issues a barrier/FUA to flush the disk's volatile write cache is filesystem-dependent on Linux (`fsync` on ext4 does; `msync` historically may or may not). | Production on `io_uring` is unaffected — this audit applies only to `EpollMmapIO`. |

**Bottom line for §1.1:** the "stronger than fdatasync" docstring is
overstated. `msync(MS_SYNC)` is comparable to `fdatasync` on healthy
Linux filesystems for the data range, weaker than `fsync` for inode
metadata not accumulated through the mapping, and the difference
matters under adversarial filesystems and disk write-cache loss.

### 1.2 KqueueMmapIO (macOS / BSD)

The `fsync` body at `src/io/kqueue_mmap_io.zig:829-854`: with a live
mapping, one `msync(addr, len, MS_SYNC)` over the full mapping
(line 848); with no mapping, fallback to `std.c.fsync(op.fd)` at
line 843. `op.datasync` is ignored — Darwin's msync has no
datasync-only variant. The mapping itself is created at lines 587-594.

#### F_FULLFSYNC — confirmed deferred

Darwin's `fsync(2)` only flushes the OS pagecache to the *drive's
write-back cache*; it does not flush the drive's on-platter buffers.
`F_FULLFSYNC` (`fcntl(fd, F_FULLFSYNC)`) is the documented call to
force the drive cache flush — markedly slower than `fsync`, and what
SQLite-on-Darwin uses for WAL durability. `F_BARRIERFSYNC` (10.13+)
is a middle ground (drive-cache barrier, no wait). Neither is used in
either varuna or the libtorrent codebases.

The KqueueMmapIO file header at lines 18-21 acknowledges this:

> Apple's `F_FULLFSYNC` would give true durability — out of scope for
> a dev backend.

Net: KqueueMmapIO's `fsync` offers **strictly less durability than
POSIX `fsync(2)` does on Linux**. `msync(MS_SYNC)` on Darwin reaches
the drive's write-back cache. With a healthy cache + battery/UPS, this
survives process kill and kernel panic. On power loss with dirty
cached writes, data can be lost.

#### Truncate semantics

Identical pattern to EpollMmapIO: drop the mapping, then `ftruncate`
(`src/io/kqueue_mmap_io.zig:901-912`). Same pre-truncate-flush gap.

#### Durability claim, KqueueMmapIO

| Failure mode      | Survives? | Why                                                                                                       |
| ----------------- | --------- | --------------------------------------------------------------------------------------------------------- |
| Process kill (SIGKILL) | ✅ Yes after `msync(MS_SYNC)` returns | Dirty pages flushed to OS pagecache; `MS_SYNC` waits.                                                       |
| Kernel panic      | ⚠️ Likely yes on HFS+/APFS but not documented. `msync(MS_SYNC)` ≈ `fsync(2)` on Darwin for the data range. | Without `F_FULLFSYNC`, drive write-cache is not drained.                                                   |
| Power loss / disk-cache loss | ❌ **Not survived** unless the drive's write-back cache is volatile-loss-protected. | This is exactly what `F_FULLFSYNC` exists to defend against. KqueueMmapIO does not call it. |

**Bottom line for §1.2:** the "dev backend, F_FULLFSYNC out of scope"
trade-off is reasonable given the explicit dev-only positioning (file
header lines 32-50). But the gap on macOS is real and substantially
larger than on Linux — power loss is genuinely not survived, and the
docstring should say so.

### 1.3 Gap between docstring and behaviour

| File / line                                          | Doc claim                                                               | Reality                                                                                               |
| ---------------------------------------------------- | ----------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------- |
| `src/io/epoll_mmap_io.zig:25-27`                     | "msync — stronger than fdatasync"                                       | Comparable to `fdatasync` for the data range on healthy Linux fs; weaker than `fsync(fd)` for inode metadata. Overstated.  |
| `src/io/epoll_mmap_io.zig:678-682`                   | "msync flushes both data and metadata changes accumulated against the mapping" | True for data, narrow for metadata (does not flush inode metadata from sources other than the mapping). |
| `src/io/kqueue_mmap_io.zig:18-21`                    | "F_FULLFSYNC would give true durability — out of scope for a dev backend." | Accurate.                                                                                            |
| `src/io/kqueue_mmap_io.zig:833-837`                  | "Darwin's msync flushes the dirty pages in the mapping to disk."        | Imprecise — flushes to the *drive*'s write-back cache, not to the platter. F_FULLFSYNC needed.       |

---

## Section 2 — libtorrent-rasterbar's approach (arvidn/libtorrent)

libtorrent-rasterbar has two fully-fledged disk-IO backends:
`mmap_disk_io` (mmap-based, default on POSIX) and `posix_disk_io`
(positional pread/pwrite via a thread pool, default on Windows and
fallback when the mmap backend isn't built). The user can also write a
custom `disk_interface`. Both are wired through the same
`disk_interface` virtual class.

### 2.1 Does libtorrent-rasterbar use mmap?

Yes — `mmap_disk_io` maps every file region with `mmap(...,
PROT_READ|PROT_WRITE, MAP_SHARED, fd, offset)` (the implementation is
in `reference-codebases/libtorrent/src/mmap.cpp` and the wiring is in
`reference-codebases/libtorrent/src/mmap_storage.cpp`). The
`file_mapping` class exposes only two persistence-related operations
on a mapping: `dont_need(range)` and `page_out(range)`.

### 2.2 What msync flags do they use?

Only **MS_INVALIDATE** and **MS_ASYNC**. Never `MS_SYNC`.

The two callsites in the entire codebase
(`reference-codebases/libtorrent/src/mmap.cpp`):

```cpp
// dont_need():
303    ::msync(start, size, MS_INVALIDATE);
```

```cpp
// page_out():
322    #elif TORRENT_USE_SYNC_FILE_RANGE
323            ::sync_file_range(m_file.fd(), start - static_cast<const byte*>(m_mapping)
324                    , size, SYNC_FILE_RANGE_WRITE);
325    #endif
326
327            // msync(MS_ASYNC) is a no-op on Linux > 2.6.19.
328            ::msync(start, size, MS_ASYNC);
```

That comment at line 327 is the smoking gun: the libtorrent-rasterbar
authors know that `msync(MS_ASYNC)` is a no-op on modern Linux, and
they call it anyway as a portability safety belt. They explicitly do
*not* call `msync(MS_SYNC)`.

### 2.3 Do they follow msync with fsync?

**No.** A grep for `fsync|fdatasync|FullFsync|FlushFileBuffers` over
the entire libtorrent-rasterbar tree (excluding the `ChangeLog` which
mentions `sync_file_range` historically) finds **zero** call sites
inside `src/` and `include/`. Quoting the search:

```
$ grep -rln 'fsync\|fdatasync\|FullFsync\|FlushFileBuffers' \
        reference-codebases/libtorrent/src/ \
        reference-codebases/libtorrent/include/
(no output)
```

libtorrent-rasterbar **does not call fsync anywhere** in either disk
backend. `mmap_storage::release_files` (which is what runs when a
torrent stops) does not fsync; it just calls
`m_pool.release(storage_index())` to close the file pool's handles
(`reference-codebases/libtorrent/src/mmap_storage.cpp:482-496`).
`posix_storage::release_files` is the same shape (`reference-codebases/libtorrent/src/posix_storage.cpp:302-310`).

### 2.4 Platform-specific durability primitives

None used at runtime. They use them at *open time* via the
`open_mode::no_cache` flag:

`reference-codebases/libtorrent/src/file.cpp:393-397`:
```cpp
#ifdef O_SYNC
        | ((mode & open_mode::no_cache) ? O_SYNC : 0)
#endif
```

`reference-codebases/libtorrent/src/file.cpp:570-582`:
```cpp
#ifdef F_NOCACHE
    // for BSD/Mac
    if (mode & aux::open_mode::no_cache)
    {
        int yes = 1;
        ::fcntl(m_fd, F_NOCACHE, &yes);

#ifdef F_NODIRECT
        // it's OK to temporarily cache written pages
        ::fcntl(m_fd, F_NODIRECT, &yes);
#endif
    }
#endif
```

When `open_mode::no_cache` is set, files are opened with `O_SYNC` on
POSIX (every write blocks until the kernel reports the data as
durable) and `F_NOCACHE` on Darwin (writes go straight to disk,
bypassing the OS pagecache).

This flag is conditionally set in `mmap_storage::open_file`
(`reference-codebases/libtorrent/src/mmap_storage.cpp:992-997`):

```cpp
auto const write_mode = sett.get_int(settings_pack::disk_io_write_mode);
if (write_mode == settings_pack::disable_os_cache
    || write_mode == settings_pack::write_through)
{
    mode |= aux::open_mode::no_cache;
}
```

i.e. the user opts in via the `disk_io_write_mode` setting. The
documented values (`reference-codebases/libtorrent/include/libtorrent/settings_pack.hpp:1305-1316`):

> `enable_os_cache` — Files are opened normally, with the OS caching reads and writes.
> `disable_os_cache` — This opens all files in no-cache mode...
> `write_through` — flush pieces to disk as they complete validation.

Apple's `F_FULLFSYNC` is **not** invoked anywhere in
libtorrent-rasterbar. Linux's `sync_file_range(SYNC_FILE_RANGE_WRITE)`
is only the best-effort "kick the writeback" call inside `page_out`,
not a durability call.

### 2.5 Stance on torn writes / partial-piece persistence

libtorrent-rasterbar's stance, implicit across both backends: **defer
durability to the OS pagecache** (or `O_SYNC` when the user opts in).
No flush is forced at any piece-completion or shutdown boundary. The
justification, by implication of the code:

- Pieces are content-addressed. Torn writes are detected by recheck on
  next session start and re-downloaded. Cost is bounded by recheck,
  not silent corruption.
- BitTorrent torrents are inherently recoverable: peers will re-serve
  any pieces that fail to verify.
- Per-piece synchronous flushing would be a major throughput cost.

### 2.6 Documented commentary

The most operationally-pointed comment in `mmap.cpp` (lines 293-294,
inside the `dont_need` body):

> note that MADV_DONTNEED is broken on Linux. It can destroy data. We
> cannot use it

That piece of operational wisdom informs the rest of the file's
conservative use of msync flags. The `disk_io_write_mode::write_through`
setting description (`settings_pack.hpp:1314`) says "flush pieces to
disk as they complete validation," but a code search shows no
implementation of an explicit per-piece flush — the behaviour is
delivered entirely through the `O_SYNC` open flag.

---

## Section 3 — libtorrent-rakshasa's approach

rakshasa's libtorrent (the engine behind rtorrent) is older and
simpler than rasterbar. It is **mmap-only** for piece data — there is
no positional-IO fallback backend.

### 3.1 Does rakshasa use mmap?

Yes — `MemoryChunk` (`reference-codebases/libtorrent-rakshasa/src/data/memory_chunk.h`)
is the mmap wrapper. `ChunkList` (`src/data/chunk_list.h/cc`) manages a
list of mapped chunks per torrent.

### 3.2 What msync flags do they use?

All three: **MS_SYNC**, **MS_ASYNC**, and **MS_INVALIDATE**, exposed
as `MemoryChunk::sync_sync`, `sync_async`, `sync_invalidate`
(`reference-codebases/libtorrent-rakshasa/src/data/memory_chunk.h:37-39`).

The actual call (`reference-codebases/libtorrent-rakshasa/src/data/memory_chunk.cc:108-119`):

```cpp
bool
MemoryChunk::sync(uint32_t offset, uint32_t length, int flags) {
  if (!is_valid())
    throw internal_error("Called MemoryChunk::sync() on an invalid object");

  if (!is_valid_range(offset, length))
    throw internal_error("MemoryChunk::sync(...) received out-of-range input");

  align_pair(&offset, &length);

  return msync(m_ptr + offset, length, flags) == 0;
}
```

### 3.3 When MS_SYNC vs MS_ASYNC?

`ChunkList::sync_options` (`reference-codebases/libtorrent-rakshasa/src/data/chunk_list.cc:328-343`)
is the dispatch table:

```cpp
std::pair<int, bool>
ChunkList::sync_options(ChunkListNode* node, sync_flags flags) {
  if ((flags & sync_force)) {
    if ((flags & sync_safe))
      return std::make_pair(MemoryChunk::sync_sync, true);
    else
      return std::make_pair(MemoryChunk::sync_async, true);

  } else if ((flags & sync_safe)) {
      return std::make_pair(MemoryChunk::sync_sync, true);
                                                ...
  }
    return std::make_pair(MemoryChunk::sync_async, true);
}
```

The "safe" / "force" flags in turn come from
`ChunkList::sync_chunks` (`src/data/chunk_list.cc:272-279`):

```cpp
// If we got enough diskspace and have not requested safe syncing,
// then sync all chunks with MS_ASYNC.
if (!(flags & (sync_safe | sync_sloppy))) {
    if (m_manager->safe_sync() || m_slot_free_diskspace() <= m_manager->safe_free_diskspace())
        flags = flags | sync_safe;
    else
        flags = flags | sync_force;
}
```

Three triggers escalate to MS_SYNC:
1. The user explicitly enables `safe_sync` (a runtime setting on
   `ChunkManager`, default off).
2. Free disk space drops below `safe_free_diskspace`.
3. The caller passes the `sync_safe` flag explicitly.

The two callsites that pass `sync_safe`:
- `Download::sync_chunks` (`src/torrent/download.cc:347-348`) uses
  `sync_all | sync_force` (no `sync_safe`) — so this defaults to
  MS_ASYNC unless `safe_sync` is on.
- `download_wrapper.cc:109` (the shutdown path) uses
  `sync_all | sync_force | sync_sloppy | sync_ignore_error` — also
  MS_ASYNC.
- `ChunkManager::periodic_sync` (`src/torrent/chunk_manager.cc:147`)
  uses `sync_use_timeout` — MS_ASYNC by default.

So in practice, **rakshasa defaults to MS_ASYNC and only escalates to
MS_SYNC when the user explicitly opts in via `safe_sync` or when free
disk space is low**.

### 3.4 Do they follow msync with fsync?

**No.** The `MemoryChunk::sync` body is exactly one `msync(2)` call.
No fsync follow-up. A grep for `fsync` across the rakshasa source
finds zero occurrences:

```
$ grep -rln 'fsync\|fdatasync' reference-codebases/libtorrent-rakshasa/
(no output)
```

### 3.5 Platform-specific durability primitives

None. rakshasa does not use `F_FULLFSYNC`, `F_BARRIERFSYNC`,
`sync_file_range`, `O_SYNC`, or `F_NOCACHE`. The only durability lever
it gives the user is the choice between `MS_SYNC` and `MS_ASYNC` via
the `safe_sync` setting and the `sync_*` flags.

### 3.6 Stance on torn writes / partial-piece persistence

Same as rasterbar in spirit — pieces are content-addressed, recovery
is via re-download. rakshasa's *additional* defence is the `safe_sync`
setting plus the disk-space-low automatic escalation, which neither
rasterbar nor varuna offer today.

### 3.7 Documented commentary

The most explicit commentary is the `safe_sync` setting and the
disk-space heuristic. rakshasa is otherwise sparse on documentation;
the code is self-explanatory.

---

## Section 4 — Comparison + lessons

| Property                          | varuna `EpollMmapIO` | varuna `KqueueMmapIO` | libtorrent-rasterbar (mmap_disk_io) | libtorrent-rakshasa |
| --------------------------------- | -------------------- | --------------------- | ----------------------------------- | ------------------- |
| Uses mmap for piece data          | Yes                  | Yes                   | Yes (default on POSIX)              | Yes (only mode)     |
| `msync(MS_SYNC)` ever called      | Yes, every `fsync`   | Yes, every `fsync`    | **No**                              | Yes, when `sync_safe` or low disk |
| `msync(MS_ASYNC)` ever called     | No                   | No                    | Yes (via `page_out`, "no-op on Linux > 2.6.19" per their comment) | Yes, the default path |
| `msync(MS_INVALIDATE)` ever called | No                   | No                    | Yes (via `dont_need`)               | Available, sparingly used |
| `fsync(fd)` follow-up after msync | **No**               | **No**                | N/A — no msync(MS_SYNC) at all      | **No**              |
| `F_FULLFSYNC` on macOS            | N/A                  | **No** (deferred)     | **No**                              | **No**              |
| `O_SYNC` open flag option         | No                   | No                    | Yes via `disk_io_write_mode`        | No                  |
| `F_NOCACHE` open flag option      | No                   | No                    | Yes via `disk_io_write_mode`        | No                  |
| `sync_file_range` (Linux)         | No                   | No                    | Yes (best-effort `page_out` only)   | No                  |
| User-facing durability knob       | No                   | No                    | `disk_io_write_mode`                | `safe_sync`         |

### Lessons varuna can draw

1. **Neither libtorrent calls `fsync(fd)` to back up `msync`.** The
   "msync + fsync" pattern the user's concern hints at is *not*
   mainstream BitTorrent practice. Both codebases trust `msync(MS_SYNC)`
   alone (rakshasa) or do nothing beyond pagecache + optional `O_SYNC`
   open (rasterbar). varuna's mmap backends are in line with
   precedent.

2. **Production BitTorrent clients trade durability for throughput by
   default.** rasterbar's default: rely on OS pagecache, no msync on
   the data path. rakshasa's default: `MS_ASYNC` (which on Linux
   ≥2.6.19 is a no-op per rasterbar's own comment). Neither flushes
   per-piece by default; both expose a knob.

3. **Content-addressing is the durability backstop.** Both libtorrent
   codebases lean on recheck to repair torn writes after a crash.
   varuna has the same infrastructure (`src/io/recheck/`,
   `src/storage/state_db.zig`); the durability gap manifests as "this
   piece fails its hash on restart and gets re-downloaded," not as
   silent corruption. Severity is bounded by recheck cost.

4. **macOS is harder than Linux.** On ext4/xfs, `msync(MS_SYNC)` is
   practically equivalent to `fsync(fd)` for the data range. On
   Darwin, `msync` ≈ `fsync(2)` ≈ "data reaches the drive's
   write-back cache, not the platter." The KqueueMmapIO gap is
   qualitatively larger than the EpollMmapIO gap. Mitigated in
   practice by KqueueMmapIO being dev-only.

5. **The user-facing knob is missing.** Both libtorrent codebases
   expose a single setting (`disk_io_write_mode` / `safe_sync`) that
   escalates from fast to durable. varuna has none. If varuna ever
   ships a production readiness backend, this is the precedent to
   follow.

6. **`sync_file_range` and `MS_INVALIDATE` are not durability calls.**
   rasterbar uses both as best-effort writeback / cache-drop hints in
   `page_out` and `dont_need`. They are not relevant to varuna's
   durability story; mentioned here only because the EpollMmapIO
   docstring lists `MS_INVALIDATE` as a flag option.

---

## Section 5 — Recommendations

Each item is tagged with a severity and a complexity estimate.
Sequencing relative to the in-flight POSIX file-op thread pool is
called out where it matters.

### R1. **Important** — Tighten the EpollMmapIO docstring

The claim "stronger than fdatasync" at `src/io/epoll_mmap_io.zig:25-27`
and at line 678-682 overstates the formal guarantee. Recommended
rewrite:

> `fsync` runs `msync(ptr, size, MS_SYNC)` on the active mapping.
> `MS_SYNC` is synchronous: the call returns only after the kernel has
> flushed dirty pages of the mapping to the underlying block layer. On
> ext4/xfs this is practically equivalent to `fdatasync(fd)` for the
> data range; the formal POSIX guarantee is weaker (filesystem-defined),
> and dirty inode metadata that did not flow through the mapping (e.g.
> mtime updates from `utimes`) is not covered. For strict durability
> against power loss with a volatile drive cache, the caller must
> follow with `fsync(fd)` and rely on the filesystem to issue a write
> barrier — varuna does not currently do this.

**Complexity:** ~30 minutes (docstring + inline comment).
**Sequencing:** independent; can land in the next progress-report
cycle.

### R2. **Important** — Document KqueueMmapIO's actual durability story

Add a "Durability claim" subsection to the `KqueueMmapIO` file header,
explicitly enumerating: (a) survives SIGKILL, (b) survives kernel
panic on healthy filesystems, (c) does **not** survive power loss
without `F_FULLFSYNC`. The current parenthetical on line 19-21 is
correct but easy to miss.

**Complexity:** ~30 minutes (docstring only).
**Sequencing:** independent.

### R3. **Cosmetic** — Note that `op.datasync` is structurally ignored on the mmap path

Both backends silently ignore `op.datasync` in the mapped path because
neither `msync(MS_SYNC)` nor Darwin's msync supports a data-only
variant. The Linux fallback path at `epoll_mmap_io.zig:690` honours
`op.datasync` when no mapping exists. This asymmetry is fine but
worth a one-line comment so the next reader doesn't assume the
contract guarantees hold uniformly.

**Complexity:** ~10 minutes.
**Sequencing:** independent.

### R4. **Cosmetic** — Optional `fsync(fd)` after `msync(MS_SYNC)` (Linux), behind a flag

If EpollMmapIO is ever made production-eligible, expose
`Config.strict_durability: bool = false` and follow `msync(MS_SYNC)`
with `fsync(fd)`. Costs one extra syscall per fsync; mostly redundant
with `MS_SYNC` on ext4/xfs but defends against filesystems where
msync semantics are weaker. Varuna's scope statement excludes those
filesystems explicitly, so this is not warranted today.

**Complexity:** ~2-4 hours.
**Sequencing:** after the POSIX file-op thread pool lands, when the
durability story across `EpollPosixIO`/`EpollMmapIO` becomes
user-visible and a unified flag makes sense.

### R5. **Cosmetic / deferred** — F_FULLFSYNC behind a KqueueMmapIO flag

If KqueueMmapIO ever leaves dev-only positioning, add
`Config.strict_durability: bool = false` and call
`fcntl(fd, F_FULLFSYNC)` after `msync(MS_SYNC)`. The standdown report
and file header (lines 18-21) correctly identify this as the right
primitive. Cost is "very high latency" by Apple's own documentation,
so it must be opt-in.

**Recommendation:** keep deferred. macOS production deployment is not
on the roadmap. The "out of scope for a dev backend" trade-off stands
as long as that remains true.

**Complexity:** ~4 hours when warranted.
**Sequencing:** only after any decision to ship a macOS production
target.

### R6. **Important (daemon-level, surfaced by this audit)** — Wire a periodic `PieceStore.sync`

Orthogonal to the mmap audit but surfaced by it: `PieceStore.sync` is
called only from a test (`src/storage/writer.zig:741`). The daemon
never asks the OS to flush written pieces, on any backend. "Rely on
the OS pagecache" is fine in practice on Linux but not what an
operator who runs `varuna stop` then powers off would expect.

**Recommendation:** invoke `PieceStore.sync` at three natural
boundaries: (a) torrent completion, (b) periodic interval (~30 s when
there are dirty writes), (c) graceful shutdown. Daemon-level change
in `src/daemon/torrent_session.zig` near the piece-completion handler.
Benefits all six backends uniformly — `msync(MS_SYNC)` for mmap
variants, thread-pool `fdatasync` for POSIX variants, `IORING_OP_FSYNC`
for io_uring.

**Complexity:** ~4-8 hours (wiring, cadence, BUGGIFY tests).
**Sequencing:** independent. Highest-leverage durability improvement
varuna could make today.

### R7. **None** — Don't add fsync follow-up unconditionally

Rejected. The libtorrent codebases survey makes it clear that "msync
+ fsync" is *not* the mainstream BitTorrent practice; if anything, the
mainstream practice is laxer than what varuna already does (rasterbar
calls neither, rakshasa defaults to MS_ASYNC). Adding an unconditional
fsync follow-up to varuna's mmap backends would put varuna out of
step with the reference codebases and would impose a per-fsync cost
on both backends that — given that those backends are dev-only today
— pays for nothing.

---

## Conclusion (TL;DR for a future implementer)

- **varuna's mmap backends are not buggy.** Correctly implemented for
  their stated purpose (development-targeted readiness backends).
  Production on io_uring is unaffected.
- **The `msync(MS_SYNC)`-only approach is in line with mainstream
  practice.** rakshasa does the same; rasterbar is *laxer* (never
  calls msync(MS_SYNC) at all). The user's instinct that "msync alone
  is weaker than msync + fsync" is technically correct on POSIX-formal
  semantics but does not match what shipping BitTorrent clients do.
- **The doc-vs-reality gap is real but small.** EpollMmapIO's
  "stronger than fdatasync" overstates; KqueueMmapIO's macOS
  durability ceiling deserves to be surfaced more prominently than it
  is. R1 + R2 fix both with ~1 hour of doc work.
- **The single highest-leverage durability improvement is at the
  daemon level.** R6 (periodic + shutdown-time `PieceStore.sync`)
  gives varuna a real durability story on *every* backend including
  io_uring. The mmap audit surfaced it; the fix is orthogonal.

Order if a future engineer wants to harden specifically: R1 → R2 → R6
→ optionally R4 / R5 only if a backend ever leaves dev-only
positioning.
