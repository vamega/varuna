# Tracker Scrape Support (HTTP + UDP)

## What was done

Added tracker scrape support to query swarm health statistics (seeders, leechers, snatches) without doing a full announce. This implements both HTTP and UDP scrape protocols.

### New file: `src/tracker/scrape.zig`

- `ScrapeResult` struct with `complete`, `incomplete`, `downloaded` fields
- `deriveScrapeUrl()`: replaces last "announce" in URL path with "scrape" (handles passkeys, .php suffixes, nested paths)
- `scrapeHttp()`: builds scrape URL with percent-encoded info_hash, HTTP GET via io_uring, parses bencoded `d5:filesd20:<hash>d...eee` response
- `scrapeUdp()`: BEP 15 action=2 -- UDP connect handshake then 36-byte scrape request (connection_id + action + txid + info_hash), parses 20-byte response (seeders + completed + leechers)
- `scrapeAuto()`: routes by URL scheme (http:// vs udp://)
- 8 unit tests covering URL derivation, response parsing, error cases

### Integration

- `TorrentSession`: added `scrape_result`, `last_scrape_time`, `scraping` atomic flag
- `maybeScrape()`: triggers background scrape every 30 minutes (detached thread, uses shared `announce_ring`)
- `Stats`: added `scrape_complete`, `scrape_incomplete`, `scrape_downloaded`
- Main daemon loop calls `maybeScrape()` during periodic tick
- `torrents/trackers` API: returns `num_seeds`, `num_leeches`, `num_downloaded` per tracker
- `torrents/info` API: `num_seeds` now populated from scrape data instead of hardcoded 0

### Minor changes

- Made `udp.zig` `parseUdpUrl()` and `resolveAddress()` public so scrape can reuse them
- Added `scrape` to `src/tracker/root.zig` exports

## What was learned

- HTTP scrape URL derivation replaces the last occurrence of "announce" after the last `/`, preserving query strings and path suffixes (e.g. `.php`, `?passkey=...`)
- UDP scrape response order is seeders, completed, leechers (different from the HTTP bencoded keys complete/incomplete/downloaded)
- The BEP 15 UDP scrape request is compact: just 36 bytes for a single hash (8 connection_id + 4 action + 4 txid + 20 info_hash)

## Key code references

- `src/tracker/scrape.zig` (entire file -- new)
- `src/tracker/udp.zig:119` (`parseUdpUrl` made pub)
- `src/tracker/udp.zig:136` (`resolveAddress` made pub)
- `src/daemon/torrent_session.zig` (scrape_result field, maybeScrape, scrapeWorker)
- `src/rpc/handlers.zig:402-435` (trackers endpoint with scrape data)
- `src/main.zig:186` (maybeScrape in periodic tick)
