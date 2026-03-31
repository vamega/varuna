# Peer/IP Banning System -- Implementation Plan

This document describes the design for Varuna's peer banning subsystem.
It covers individual IP bans, CIDR range bans, ipfilter.dat-style ban list import,
persistence, enforcement, API endpoints, CLI commands, and testing.

## Reference: How qBittorrent Does It

qBittorrent has two separate ban mechanisms that merge into a single `lt::ip_filter`:

1. **Manual bans** (`bannedIPs`): A `QStringList` stored in `State/BannedIPs` preference.
   The WebAPI exposes:
   - `POST /api/v2/transfer/banPeers` -- `peers` param is `|`-separated `ip:port` list.
     Each IP is parsed and added via `Session::banIP()`.
   - `GET /api/v2/app/preferences` -- returns `banned_IPs` as a `\n`-joined string.
   - `POST /api/v2/app/setPreferences` -- accepts `banned_IPs` as a `\n`-joined string
     (replaces the full list).
   - `Session::bannedIPs()` returns the current list.
   - `Session::setBannedIPs()` validates, deduplicates, sorts, and triggers IP filter rebuild.

2. **IP filter file** (`FilterParserThread`): Parses three formats on a background thread:
   - **DAT format** (eMule): `startIP - endIP , access , description` (access <= 127 is blocked).
   - **P2P plaintext**: `description:startIP-endIP` per line.
   - **P2B binary**: Binary format with version headers.
   The file path is set via `ip_filter_path` preference. Parsing emits `IPFilterParsed(count)`.

3. **Merge**: When IP filtering is enabled, qBittorrent parses the file, then overlays
   manual bans via `processBannedIPs()`, and installs the combined `lt::ip_filter` into
   the libtorrent session in one atomic call.

4. **Preferences**: `ip_filter_enabled` (bool), `ip_filter_path` (string),
   `ip_filter_trackers` (bool), `banned_IPs` (newline-separated string).

The qui frontend calls `POST /api/v2/transfer/banPeers` with `peers=ip:port|ip:port`
from the peer list context menu.

## Design for Varuna

### Overview

Varuna's ban system has three layers:

1. **BanList** (`src/net/ban_list.zig`) -- in-memory data structure for O(1) IPv4/IPv6
   individual IP lookups and efficient CIDR range checks.
2. **BanDb** (extension to `src/storage/resume.zig`) -- SQLite persistence on the
   background thread.
3. **API + CLI** -- qBittorrent-compatible endpoints plus Varuna-specific extensions.

### Data Structures (`src/net/ban_list.zig`)

```zig
pub const BanList = struct {
    allocator: std.mem.Allocator,

    /// Individual banned IPs. Key is the raw address bytes (4 for IPv4, 16 for IPv6).
    /// Value is the ban entry metadata.
    banned_ips: std.AutoHashMap([16]u8, BanEntry),

    /// CIDR ranges, stored as sorted arrays for binary-search matching.
    /// Separate lists for IPv4 and IPv6.
    ipv4_ranges: std.ArrayList(Ipv4Range),
    ipv6_ranges: std.ArrayList(Ipv6Range),

    /// Generation counter, incremented on every mutation.
    /// The event loop caches a snapshot; when generations diverge it rebuilds its local copy.
    generation: u64,

    pub const BanEntry = struct {
        source: BanSource,
        reason: ?[]const u8,       // heap-allocated, optional comment
        created_at: i64,           // unix timestamp
    };

    pub const BanSource = enum(u8) {
        manual,     // individual API/CLI ban
        ipfilter,   // imported from ipfilter.dat / P2P / CIDR file
    };

    pub const Ipv4Range = struct {
        start: u32,  // network byte order -> host u32 for comparison
        end: u32,
        source: BanSource,
    };

    pub const Ipv6Range = struct {
        start: u128,
        end: u128,
        source: BanSource,
    };

    /// Check if an address is banned. O(1) for individual IPs,
    /// O(log n) binary search for CIDR ranges.
    pub fn isBanned(self: *const BanList, addr: std.net.Address) bool;

    /// Add an individual IP ban. Returns true if newly added.
    pub fn banIp(self: *BanList, addr: std.net.Address, reason: ?[]const u8, source: BanSource) !bool;

    /// Remove an individual IP ban. Returns true if it was present.
    pub fn unbanIp(self: *BanList, addr: std.net.Address) bool;

    /// Add a CIDR range ban.
    pub fn banRange(self: *BanList, start: anytype, end: anytype, source: BanSource) !void;

    /// Remove all bans from a specific source (e.g., clear all ipfilter entries before reimport).
    pub fn clearSource(self: *BanList, source: BanSource) void;

    /// Return a snapshot of all individual bans for API listing.
    pub fn listBans(self: *const BanList, allocator: std.mem.Allocator) ![]BanInfo;

    /// Return count of total rules (individual + ranges).
    pub fn ruleCount(self: *const BanList) usize;
};
```

**Why this structure:**
- Individual IPs use a hash map keyed on the raw address bytes (padded to 16 bytes,
  with a family tag in byte 0 for disambiguation). Lookup is O(1).
- CIDR ranges are stored as sorted `(start, end)` intervals. `isBanned` does a hash
  map probe first; if miss, it does a binary search on the range list. Typical ban
  lists have thousands of ranges, so O(log n) on a sorted array is efficient and
  cache-friendly.
- IPv4 and IPv6 ranges are stored separately to avoid mixed comparisons.

### Address Normalization

All addresses are normalized before storage:
- IPv4-mapped IPv6 (`::ffff:1.2.3.4`) is converted to plain IPv4.
- IPv6 addresses are stored in canonical form (RFC 5952).
- Port numbers are stripped -- bans apply to all ports for an IP.

### SQLite Schema (in `src/storage/resume.zig`)

```sql
-- Individual IP bans (manual or imported)
CREATE TABLE IF NOT EXISTS banned_ips (
    address TEXT NOT NULL PRIMARY KEY,   -- canonical IP string
    source  INTEGER NOT NULL DEFAULT 0,  -- 0 = manual, 1 = ipfilter
    reason  TEXT,                         -- optional comment
    created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

-- CIDR range bans
CREATE TABLE IF NOT EXISTS banned_ranges (
    id         INTEGER PRIMARY KEY AUTOINCREMENT,
    start_addr TEXT NOT NULL,            -- canonical IP string (range start)
    end_addr   TEXT NOT NULL,            -- canonical IP string (range end)
    source     INTEGER NOT NULL DEFAULT 0,
    created_at INTEGER NOT NULL DEFAULT (strftime('%s','now'))
);

-- IP filter file configuration
CREATE TABLE IF NOT EXISTS ipfilter_config (
    id       INTEGER PRIMARY KEY CHECK (id = 1),  -- singleton row
    path     TEXT,                                  -- file path, NULL if not set
    enabled  INTEGER NOT NULL DEFAULT 0,            -- 0 = disabled, 1 = enabled
    rule_count INTEGER NOT NULL DEFAULT 0           -- last parsed rule count
);
```

All SQLite operations run on the existing background thread, consistent with
project conventions. The ban list is loaded into memory at startup and written
through on changes.

### API Endpoints

All endpoints require authentication (existing SID cookie check).

#### 1. Ban Peers (qBittorrent-compatible)

**`POST /api/v2/transfer/banPeers`**

Bans one or more IPs. This is the endpoint that qui/Flood call from the peer
list context menu.

Request (form-encoded):
```
peers=192.168.1.1:6881|10.0.0.1:51413|[2001:db8::1]:6881
```

Peers are `|`-separated `ip:port` strings. Port is ignored for ban purposes.
IPv6 addresses use bracket notation.

Response: `200 OK` (empty body)

Behavior:
- Parse each peer address, extract IP, ignore port.
- Add to BanList as `source = manual`.
- Persist to SQLite `banned_ips` table (background thread).
- Signal event loop to disconnect any currently connected peers at those IPs.

#### 2. Preferences (qBittorrent-compatible fields)

**`GET /api/v2/app/preferences`** -- add these fields to existing response:

```json
{
    "ip_filter_enabled": false,
    "ip_filter_path": "",
    "ip_filter_trackers": false,
    "banned_IPs": "192.168.1.1\n10.0.0.0/8"
}
```

- `ip_filter_enabled`: whether the ipfilter.dat file is active.
- `ip_filter_path`: path to the ipfilter file.
- `ip_filter_trackers`: whether IP filter applies to tracker connections (always false for now).
- `banned_IPs`: `\n`-separated list of manually banned IPs and CIDR ranges.

**`POST /api/v2/app/setPreferences`** -- accept these fields:

```
ip_filter_enabled=true
ip_filter_path=/path/to/ipfilter.dat
banned_IPs=192.168.1.1\n10.0.0.0/8
```

When `banned_IPs` is set, it replaces the entire manual ban list (same as qBittorrent).
When `ip_filter_enabled` or `ip_filter_path` changes, re-parse the filter file.

#### 3. Unban IP (Varuna extension)

**`POST /api/v2/transfer/unbanPeers`**

Request (form-encoded):
```
ips=192.168.1.1|10.0.0.1
```

Response: `200 OK` with body `{"removed": 2}`

#### 4. List Banned IPs (Varuna extension)

**`GET /api/v2/transfer/bannedPeers`**

Response:
```json
{
    "individual": [
        {"ip": "192.168.1.1", "source": "manual", "reason": "bad peer", "created_at": 1711900800},
        {"ip": "10.0.0.5", "source": "ipfilter", "reason": null, "created_at": 1711900800}
    ],
    "ranges": [
        {"start": "10.0.0.0", "end": "10.255.255.255", "source": "ipfilter", "created_at": 1711900800}
    ],
    "total_rules": 1542
}
```

#### 5. Import Ban List (Varuna extension)

**`POST /api/v2/transfer/importBanList`**

Request (multipart form-data):
```
file=@ipfilter.dat
format=auto
```

`format` can be `auto` (detect from content), `dat` (eMule DAT), `p2p` (P2P plaintext),
or `cidr` (one CIDR per line).

Response:
```json
{"imported": 15234, "errors": 3}
```

This differs from the qBittorrent `ip_filter_path` approach. qBittorrent points to a
file on the server filesystem and re-reads it. Varuna supports both:
- Upload via multipart (this endpoint) for one-shot import.
- `ip_filter_path` preference for a persistent file that is re-parsed on startup and
  when the path changes.

### IP Filter File Parsing (`src/net/ipfilter_parser.zig`)

Supports three formats:

#### eMule DAT Format
```
# Comment line
001.009.096.105 - 001.009.096.105 , 000 , Some Organization
```
Lines with access level > 127 are NOT blocked (same as qBittorrent).

#### P2P Plaintext Format
```
Some Organization:1.9.96.105-1.9.96.105
```

#### CIDR Format (Varuna extension)
```
# Comment line
10.0.0.0/8
192.168.0.0/16
2001:db8::/32
```

Format detection heuristic:
1. If the first non-comment, non-empty line contains ` - ` and `,` -> DAT format.
2. If it contains `:` followed by an IP and `-` -> P2P format.
3. If it contains `/` -> CIDR format.
4. Otherwise, try each parser in order.

Parsing runs on the SQLite background thread (it reads a file and may be slow for
large lists). The parsed rules are atomically swapped into the BanList.

### Enforcement Points

The ban check must happen at these locations in the event loop:

#### 1. Inbound Connection Accept (`src/io/peer_handler.zig:handleAccept`)

After the `accept` CQE returns a new fd, before allocating a peer slot:

```zig
// After: const new_fd: posix.fd_t = @intCast(cqe.res);
// Before: const slot = self.allocSlot() ...

// Extract peer address from accept_addr (stored in EventLoop for ACCEPT_MULTISHOT
// or from the sockaddr filled by the accept SQE).
if (self.ban_list) |bl| {
    if (bl.isBanned(peer_addr)) {
        log.debug("rejected banned inbound peer: {}", .{peer_addr});
        posix.close(new_fd);
        self.submitAccept() catch {};
        return;
    }
}
```

Note: The current `handleAccept` does not extract the peer address from the accept.
This will require adding an `accept_addr` buffer to the EventLoop and using the
`IORING_OP_ACCEPT` addr/addrlen parameters to capture the connecting peer's address.

#### 2. Outbound Connection Attempt (`src/io/event_loop.zig:addPeerForTorrent`)

Before creating the socket:

```zig
if (self.ban_list) |bl| {
    if (bl.isBanned(address)) {
        return error.BannedPeer;
    }
}
```

This catches peers from tracker responses, PEX, and DHT before wasting a socket
and SQE on the connection.

#### 3. Outbound uTP Connection (`src/io/event_loop.zig:addUtpPeer`)

Same check as TCP, before allocating the uTP socket.

#### 4. Tracker/PEX/DHT Peer Addition

The `addPeerForTorrent` check (point 2) covers all three sources since they all
flow through that function. No additional check is needed.

#### 5. Active Peer Disconnection

When a new ban is added at runtime (via API), the event loop must scan connected
peers and disconnect any that match:

```zig
pub fn enforceBans(self: *EventLoop) void {
    const bl = self.ban_list orelse return;
    for (self.peers, 0..) |*peer, i| {
        if (peer.state == .free) continue;
        if (bl.isBanned(peer.address)) {
            log.info("disconnecting banned peer: {}", .{peer.address});
            self.removePeer(@intCast(i));
        }
    }
}
```

This is triggered by an atomic flag set by the API handler and checked in the
event loop tick, similar to how rate limit updates are communicated.

### Event Loop Integration

The `BanList` is owned by the `EventLoop` and protected by the same pattern used
for rate limits: API handlers set an atomic flag, the event loop reads it during
the next tick.

```
API handler (RPC thread)                EventLoop (io_uring thread)
    |                                       |
    |-- ban_list.banIp(addr) ------------->|  (mutex-protected write)
    |-- ban_list_dirty.store(true) ------->|
    |                                       |
    |                                    tick:
    |                                    if ban_list_dirty.load():
    |                                        enforceBans()
    |                                        ban_list_dirty.store(false)
```

The `BanList` itself uses a `std.Thread.Mutex` for thread safety, since writes
are infrequent (only on API calls) and reads happen once per tick at most for
the dirty check. The hot-path `isBanned` call during accept/connect uses a
read-only snapshot or the mutex -- either way, contention is minimal since bans
change rarely.

### CLI Commands (`varuna-ctl`)

#### `varuna-ctl ban <ip> [--reason <text>]`

Calls `POST /api/v2/transfer/banPeers` with `peers=<ip>:0`.

#### `varuna-ctl unban <ip>`

Calls `POST /api/v2/transfer/unbanPeers` with `ips=<ip>`.

#### `varuna-ctl banlist [--json]`

Calls `GET /api/v2/transfer/bannedPeers`.
Default output (human-readable):
```
Banned IPs (3 individual, 1542 from ipfilter):
  192.168.1.1  (manual, "bad peer", 2026-03-30 14:00:00)
  10.0.0.5     (ipfilter, 2026-03-30 14:00:00)
  ...

Banned Ranges (1540):
  10.0.0.0 - 10.255.255.255 (ipfilter)
  ...

Total rules: 1545
```

With `--json`, prints the raw API response.

#### `varuna-ctl import-banlist <file> [--format auto|dat|p2p|cidr]`

Reads the file locally and uploads it via `POST /api/v2/transfer/importBanList`
as multipart form-data.

### TOML Configuration

Add to `[network]` section in `varuna.toml`:

```toml
[network]
# IP filter file path (eMule DAT, P2P plaintext, or CIDR format)
# Loaded on startup and when changed via API.
ip_filter_path = ""
ip_filter_enabled = false

# Apply IP filter to tracker connections too (default: false)
ip_filter_trackers = false
```

Individual bans are not stored in the config file -- they live only in SQLite,
consistent with qBittorrent's approach (which stores them in application state,
not the config file).

### Module Organization

```
src/net/ban_list.zig          -- BanList data structure + isBanned/banIp/unbanIp
src/net/ipfilter_parser.zig   -- DAT/P2P/CIDR file parser
src/storage/resume.zig        -- Extended with banned_ips/banned_ranges/ipfilter_config tables
src/io/event_loop.zig         -- ban_list field, enforceBans(), accept/connect checks
src/io/peer_handler.zig       -- isBanned check in handleAccept
src/rpc/handlers.zig          -- banPeers, unbanPeers, bannedPeers, importBanList endpoints
                                  + ip_filter fields in preferences
src/ctl/main.zig              -- ban, unban, banlist, import-banlist subcommands
```

### Implementation Phases

#### Phase 1: Core Data Structure + Individual Bans
- Implement `BanList` with hash map for individual IPs.
- Add `banned_ips` table to SQLite schema in `resume.zig`.
- Load bans from SQLite at startup.
- Add `isBanned` check to `addPeerForTorrent` and `handleAccept`.
- Add peer address extraction to `handleAccept` (currently missing).
- Implement `POST /api/v2/transfer/banPeers` endpoint.
- Implement `GET /api/v2/transfer/bannedPeers` endpoint.
- Implement `POST /api/v2/transfer/unbanPeers` endpoint.
- Add `banned_IPs` field to preferences GET/SET.
- Add active peer disconnection on new ban.
- Add `varuna-ctl ban`, `varuna-ctl unban`, `varuna-ctl banlist` commands.
- Tests: ban/unban individual IPs, isBanned correctness, IPv4/IPv6,
  IPv4-mapped IPv6 normalization, persistence round-trip, API endpoint tests.

#### Phase 2: CIDR Ranges
- Add sorted range arrays to `BanList`.
- Add binary search range matching to `isBanned`.
- Add `banned_ranges` table to SQLite schema.
- Support CIDR notation in `banned_IPs` preference (`10.0.0.0/8`).
- Expand `banPeers` to accept CIDR notation.
- Tests: CIDR parsing, range boundary correctness (/8, /16, /24, /32, /0),
  IPv6 CIDR, overlapping ranges, range + individual interaction.

#### Phase 3: IP Filter File Import
- Implement `ipfilter_parser.zig` with DAT, P2P, and CIDR format support.
- Add `ipfilter_config` table to SQLite.
- Add `ip_filter_enabled`/`ip_filter_path` to preferences and TOML config.
- Background-thread parsing (reuse SQLite thread or spawn a task on it).
- Atomic swap of ipfilter rules into BanList.
- Implement `POST /api/v2/transfer/importBanList` multipart endpoint.
- Implement `varuna-ctl import-banlist` command.
- Tests: parse real-world ipfilter.dat samples, format auto-detection,
  malformed lines, empty files, large files (100K+ rules performance test).

### Test Strategy

#### Unit Tests (`src/net/ban_list.zig`)
- `test "bans and unbans individual IPv4"` -- basic add/remove/check cycle.
- `test "bans and unbans individual IPv6"` -- same for IPv6.
- `test "normalizes IPv4-mapped IPv6"` -- `::ffff:1.2.3.4` matches `1.2.3.4`.
- `test "rejects invalid addresses"` -- malformed input returns error.
- `test "CIDR /8 range covers all addresses"` -- `10.0.0.0/8` matches `10.255.255.255`.
- `test "CIDR /32 is single IP"` -- equivalent to individual ban.
- `test "CIDR /0 matches everything"` -- edge case.
- `test "overlapping ranges merge correctly"` -- no double-counting.
- `test "clearSource removes only ipfilter entries"` -- manual bans survive.
- `test "generation increments on mutation"` -- event loop cache invalidation.
- `test "concurrent read and write safety"` -- mutex correctness under contention.

#### Unit Tests (`src/net/ipfilter_parser.zig`)
- `test "parses eMule DAT format"` -- standard lines with access levels.
- `test "parses P2P plaintext format"` -- `description:start-end` lines.
- `test "parses CIDR format"` -- one CIDR per line with comments.
- `test "auto-detects DAT format"` -- heuristic picks correctly.
- `test "auto-detects P2P format"` -- heuristic picks correctly.
- `test "skips comment lines"` -- `#` and `//` prefixes.
- `test "handles malformed lines gracefully"` -- parse errors counted, not fatal.
- `test "access level above 127 is not blocked"` -- DAT format semantics.
- `test "handles empty file"` -- no rules, no error.

#### Integration Tests
- `test "banned peer rejected on inbound accept"` -- connect to daemon, verify
  RST/close before handshake.
- `test "banned peer skipped on outbound connect"` -- add peer from tracker
  response, verify no SQE submitted.
- `test "existing peer disconnected on ban"` -- establish connection, ban the IP
  via API, verify disconnect.
- `test "bans persist across daemon restart"` -- ban IP, restart daemon, verify
  still banned.
- `test "import large ipfilter.dat"` -- performance: parse 100K rules under 1 second.
- `test "banPeers API matches qBittorrent format"` -- pipe-separated peers with ports.
- `test "preferences round-trip banned_IPs"` -- set via setPreferences, read via
  preferences, verify identical.

### Performance Considerations

- The `isBanned` check runs on every inbound accept and outbound connect. For
  individual IPs, this is a hash map lookup (O(1)). For ranges, it is a binary
  search (O(log n)). With 100K ranges, this is ~17 comparisons per check.
- The hash map uses raw address bytes as keys (4 or 16 bytes), avoiding string
  allocation on the hot path.
- CIDR ranges are pre-expanded to `(start, end)` integer pairs at import time,
  so `isBanned` does simple integer comparison, not prefix math.
- The BanList is read-mostly. Writes (bans/unbans) are rare and trigger at most
  one enforceBans scan of the peer array per tick.
- Memory: 100K individual IPs ~ 100K * (16 + 24) bytes = ~4 MB. 100K ranges ~
  100K * 16 bytes = ~1.6 MB. Both are well within acceptable limits.
