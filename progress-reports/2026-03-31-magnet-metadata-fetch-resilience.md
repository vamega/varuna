# Magnet Link Metadata Fetch Resilience

**Date**: 2026-03-31

## What was done

The BEP 9 metadata download path was hardened to handle real-world failure modes. The previous implementation (`fetchMetadata` + `fetchMetadataFromPeer` in `torrent_session.zig`) tried peers sequentially but had no timeouts, no retry logic for transient failures, and no progress reporting.

### New module: `src/net/metadata_fetch.zig`

Created `MetadataFetcher`, a self-contained coordinator for resilient metadata download:

1. **Multi-peer retry**: When a peer disconnects, times out, or rejects a metadata request, the fetcher moves to the next available peer. Partial progress is preserved in the `MetadataAssembler` -- if peer A delivers pieces 0-2 and fails, peer B only needs to deliver the remaining pieces.

2. **Per-peer timeout (30s)**: Socket-level `SO_RCVTIMEO`/`SO_SNDTIMEO` set on each peer connection. If a peer stalls, the recv/send will error after 30 seconds and the fetcher moves on. Connect timeout is 5 seconds via `ring.connect_timeout`.

3. **Overall timeout (5 minutes)**: Checked between peer attempts and between piece requests. Prevents indefinite hangs when all peers are slow or unresponsive.

4. **Peer selection strategy**: Prefers unattempted peers first. Failed peers with fewer than 3 failures are retried (allows recovery from transient network issues). Peers with 3+ failures are permanently skipped.

5. **DHT peer provider interface**: `PeerProvider` struct with a function pointer (`get_peers_fn`) that DHT can implement later. The fetcher polls the provider periodically during the fetch loop. Stubbed with `PeerProvider.none()` for now.

6. **Progress reporting**: `FetchProgress` struct exposes metadata_size, pieces_received/total, peers_attempted/active/with_metadata, elapsed_secs, and error_message. Surfaced through `TorrentSession.Stats` for API consumption.

7. **Peer deduplication**: `addPeer` checks address equality before inserting.

### Changes to `src/daemon/torrent_session.zig`

- `fetchMetadata` rewritten to use `MetadataFetcher` instead of inline peer logic
- `fetchMetadataFromPeer` removed (logic moved to `MetadataFetcher.fetchFromPeer`)
- Added `metadata_fetch_progress` field to `TorrentSession`
- Added 5 metadata progress fields to `Stats` struct
- `getStats` populates metadata progress from the stored snapshot

## Key design decisions

- **Sequential peer attempts, not thread-per-peer parallelism**: The fetcher tries one peer at a time from the background thread. True parallelism would require multiple rings or threads, adding complexity for marginal benefit (metadata is small, typically <100 KiB). The key resilience improvement is retrying with partial progress preserved.

- **Socket timeout vs io_uring link_timeout**: Used `SO_RCVTIMEO` for per-peer timeout rather than adding `recv_exact_timeout` to Ring. Simpler, doesn't pollute Ring's API, and the metadata fetch already runs on a dedicated background thread where blocking is acceptable.

- **PeerProvider as function pointer, not comptime interface**: Runtime dispatch via `?*const fn(...)` allows DHT to be wired in without recompiling MetadataFetcher. The `?*anyopaque` context pointer carries DHT state.

## Tests added (12 tests)

- PeerProvider.none returns empty
- PeerProvider custom implementation
- MetadataFetcher init/deinit
- Peer deduplication
- Fetch fails with no peers
- selectNextPeer prefers unattempted
- selectNextPeer retries failed peers
- selectNextPeer returns null when exhausted
- addressEqual correctness
- FetchProgress default values
- setPeerProvider + pollPeerProvider
- Overall timeout detection

## Code references

- `src/net/metadata_fetch.zig` -- new module (MetadataFetcher, PeerProvider, FetchProgress)
- `src/net/root.zig:2` -- module registration
- `src/daemon/torrent_session.zig:14` -- import
- `src/daemon/torrent_session.zig:161` -- metadata_fetch_progress field
- `src/daemon/torrent_session.zig:67-73` -- Stats metadata progress fields

## Follow-up work

- Wire `PeerProvider` to DHT when BEP 5 is implemented
- Consider true parallel peer connections (multiple simultaneous fetchFromPeer) for very large metadata (>1 MiB)
- Add metadata fetch progress to the /api/v2/sync/maindata delta protocol
- Expose metadata_fetch_progress in the torrentPeers endpoint
