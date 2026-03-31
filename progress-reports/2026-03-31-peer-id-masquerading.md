# Peer ID Masquerading

## What was done

Added configurable peer ID masquerading so Varuna can identify as a different BitTorrent client. This is important for private trackers that whitelist specific clients.

**Config**: new `masquerade_as` option under `[network]` in the TOML config file:
```toml
[network]
masquerade_as = "qBittorrent 5.1.4"
```

**Supported clients** (Azureus-style peer ID prefixes):
- qBittorrent: `-qBXYZW-` (e.g. `-qB5140-` for 5.1.4)
- rTorrent: `-ltXYZW-` with hex-extended version encoding (e.g. `-lt0G60-` for 0.16.6, where G=16)
- uTorrent: `-UTXYZW-` (e.g. `-UT3560-` for 3.5.6)
- Deluge: `-DEXYZW-` (e.g. `-DE2110-` for 2.1.1)
- Transmission: `-TRXYZW-` (e.g. `-TR4060-` for 4.0.6)

When `masquerade_as` is unset (default), the normal `-VR0001-` Varuna prefix is used. If an unsupported client name is given, a warning is logged and Varuna falls back to its own prefix.

## Key design decisions

- The masquerade config is a simple string ("ClientName X.Y.Z") parsed at peer ID generation time. No separate enum config needed.
- rTorrent uses libtorrent-rakshasa's peer ID format (`-lt`), not its own prefix. The version uses hex-extended encoding (0-9 for digits, A=10, B=11, ..., G=16) to handle rTorrent's versioning where minor versions exceed 9.
- The random suffix uses alphanumeric characters (62-char alphabet) matching what most clients use.
- Client name matching is case-insensitive for user convenience.

## Files changed

- `src/torrent/peer_id.zig`: Complete rewrite. Added `parseMasquerade()`, `generate()` now takes optional masquerade spec, 17 tests covering all client formats.
- `src/config.zig`: Added `masquerade_as: ?[]const u8 = null` to `Network` struct.
- `src/daemon/torrent_session.zig`: `create()` and `createFromMagnet()` now accept `masquerade_as` parameter.
- `src/daemon/session_manager.zig`: Added `masquerade_as` field, passed through to session creation.
- `src/main.zig`: Wires `cfg.network.masquerade_as` to session manager.
- `src/app.zig`: Standalone download/seed commands pass masquerade config to `generate()`.

## What was learned

- BitTorrent peer ID formats vary significantly between clients. rTorrent is especially tricky because it uses libtorrent-rakshasa's peer ID (prefix `-lt`), not an rTorrent-branded one, and the version encoding uses a hex-extended scheme for minor versions >= 10.
- The Azureus-style format (`-CCXYZW-` + 12 random bytes) is the de facto standard for modern clients. All five supported clients use this format.

## Remaining work

- User agent string masquerading for HTTP tracker announces (some trackers also check the HTTP User-Agent header)
- Key parameter format differences between clients in tracker announces
- Testing against actual private trackers to validate acceptance
