pub const address = @import("address.zig");
pub const ban_list = @import("ban_list.zig");
pub const smart_ban = @import("smart_ban.zig");
pub const bencode_scanner = @import("bencode_scanner.zig");
pub const extensions = @import("extensions.zig");
pub const hash_exchange = @import("hash_exchange.zig");
pub const ipfilter_parser = @import("ipfilter_parser.zig");
pub const metadata_fetch = @import("metadata_fetch.zig");
pub const peer_id = @import("peer_id.zig");
pub const peer_wire = @import("peer_wire.zig");
pub const pex = @import("pex.zig");
pub const socket = @import("socket.zig");
pub const ut_metadata = @import("ut_metadata.zig");
pub const utp = @import("utp.zig");
pub const ledbat = @import("ledbat.zig");
pub const utp_manager = @import("utp_manager.zig");
pub const web_seed = @import("web_seed.zig");

// Pull subsystem source-side `test "..."` blocks into the test runner.
// Mirrors the pattern in `src/io/root.zig` and `src/dht/root.zig`. Wired
// into `mod_tests` via `_ = net;` in `src/root.zig`'s test block.
//
// `address.zig` has no inline tests today.
test {
    _ = ban_list;
    _ = bencode_scanner;
    _ = extensions;
    _ = hash_exchange;
    _ = ipfilter_parser;
    _ = ledbat;
    _ = metadata_fetch;
    _ = peer_id;
    _ = peer_wire;
    _ = pex;
    _ = smart_ban;
    _ = socket;
    _ = ut_metadata;
    _ = utp;
    _ = utp_manager;
    _ = web_seed;
}
