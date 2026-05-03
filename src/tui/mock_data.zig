const std = @import("std");

pub const TorrentStatus = enum {
    downloading,
    seeding,
    paused,
    errored,
    queued,

    pub fn label(self: TorrentStatus) []const u8 {
        return switch (self) {
            .downloading => "downloading",
            .seeding => "seeding",
            .paused => "paused",
            .errored => "errored",
            .queued => "queued",
        };
    }

    pub fn short(self: TorrentStatus) []const u8 {
        return switch (self) {
            .downloading => "DN",
            .seeding => "SD",
            .paused => "PA",
            .errored => "ER",
            .queued => "QU",
        };
    }
};

pub const FileInfo = struct {
    path: []const u8,
    size_gib: f64,
    skipped: bool = false,
};

pub const PeerInfo = struct {
    address: []const u8,
    client: []const u8,
    down_mib: f64,
    up_mib: f64,
    progress: f64,
};

pub const Torrent = struct {
    name: []const u8,
    tracker: []const u8,
    category: []const u8,
    size_gib: f64,
    progress: f64,
    down_mib: f64,
    up_mib: f64,
    seeds: u16,
    peers: u16,
    ratio: f64,
    eta_min: u32,
    status: TorrentStatus,
    paused: bool = false,
    files: []const FileInfo,
    peers_list: []const PeerInfo,
};

const libreoffice_files = [_]FileInfo{
    .{ .path = "subs/LibreOffice.25.2.5.Linux.x86-64/README.txt", .size_gib = 0.01 },
    .{ .path = "LibreOffice.25.2.5.Linux.x86-64.tar.gz", .size_gib = 7.25 },
    .{ .path = "extras/LibreOffice.25.2.5.Linux.x86-64.lang.tar.gz", .size_gib = 2.08 },
    .{ .path = "src/LibreOffice.25.2.5.Linux.x86-64.src.tar.gz", .size_gib = 8.38 },
    .{ .path = "docs/LibreOffice.25.2.5.Linux.x86-64.pdf", .size_gib = 0.18, .skipped = true },
};

const media_files = [_]FileInfo{
    .{ .path = "video/main.mkv", .size_gib = 21.72 },
    .{ .path = "video/sample.mkv", .size_gib = 0.24, .skipped = true },
    .{ .path = "subs/english.srt", .size_gib = 0.01 },
    .{ .path = "extras/cover.jpg", .size_gib = 0.01 },
};

const archive_files = [_]FileInfo{
    .{ .path = "archive/data-000.tar", .size_gib = 8.00 },
    .{ .path = "archive/data-001.tar", .size_gib = 8.00 },
    .{ .path = "archive/index.sqlite", .size_gib = 0.42 },
};

const linux_files = [_]FileInfo{
    .{ .path = "iso/ubuntu-24.04.2-desktop-amd64.iso", .size_gib = 5.84 },
    .{ .path = "iso/SHA256SUMS", .size_gib = 0.01 },
    .{ .path = "iso/SHA256SUMS.gpg", .size_gib = 0.01 },
};

const peers_fast = [_]PeerInfo{
    .{ .address = "10.20.1.18:51413", .client = "qBittorrent 5.0", .down_mib = 6.1, .up_mib = 1.2, .progress = 0.84 },
    .{ .address = "10.20.4.72:6881", .client = "Transmission 4.0", .down_mib = 3.4, .up_mib = 0.8, .progress = 0.62 },
    .{ .address = "10.20.9.11:42000", .client = "libtorrent", .down_mib = 1.1, .up_mib = 0.3, .progress = 0.31 },
};

const peers_seed = [_]PeerInfo{
    .{ .address = "10.30.2.88:51413", .client = "rTorrent", .down_mib = 0.0, .up_mib = 2.4, .progress = 1.0 },
    .{ .address = "10.30.7.14:6881", .client = "varuna", .down_mib = 0.0, .up_mib = 1.6, .progress = 1.0 },
};

pub const initial_torrents = [_]Torrent{
    .{ .name = "LibreOffice.25.2.5.Linux.x86-64.tar.gz", .tracker = "linuxtracker.org", .category = "#linux", .size_gib = 28.14, .progress = 0.56, .down_mib = 7.0, .up_mib = 1.2, .seeds = 32, .peers = 56, .ratio = 0.42, .eta_min = 18, .status = .downloading, .files = libreoffice_files[0..], .peers_list = peers_fast[0..] },
    .{ .name = "Blender.4.2.LTS.linux-x64.tar.xz", .tracker = "flacsforall.org", .category = "#art", .size_gib = 42.02, .progress = 0.43, .down_mib = 1.1, .up_mib = 0.5, .seeds = 61, .peers = 171, .ratio = 0.17, .eta_min = 94, .status = .downloading, .files = archive_files[0..], .peers_list = peers_fast[0..] },
    .{ .name = "Vivaldi.Four.Seasons.HiRes.flac", .tracker = "opensubs.net", .category = "#audio", .size_gib = 6.93, .progress = 0.20, .down_mib = 0.9, .up_mib = 0.9, .seeds = 33, .peers = 1, .ratio = 1.31, .eta_min = 52, .status = .downloading, .files = media_files[0..], .peers_list = peers_fast[0..] },
    .{ .name = "ubuntu-24.04.2-desktop-amd64.iso", .tracker = "linuxtracker.org", .category = "#linux", .size_gib = 18.55, .progress = 0.48, .down_mib = 0.0, .up_mib = 0.0, .seeds = 0, .peers = 131, .ratio = 0.00, .eta_min = 0, .status = .paused, .paused = true, .files = linux_files[0..], .peers_list = peers_seed[0..] },
    .{ .name = "OpenStreetMap.Planet.2026-04-20.pbf", .tracker = "archive.org", .category = "#docs", .size_gib = 1.18, .progress = 0.98, .down_mib = 5.3, .up_mib = 0.4, .seeds = 59, .peers = 61, .ratio = 2.27, .eta_min = 2, .status = .downloading, .files = archive_files[0..], .peers_list = peers_fast[0..] },
    .{ .name = "Common.Crawl.CC-MAIN-2026-17.warc.gz", .tracker = "archive.org", .category = "#archive", .size_gib = 8.06, .progress = 0.89, .down_mib = 0.0, .up_mib = 0.0, .seeds = 56, .peers = 55, .ratio = 4.81, .eta_min = 0, .status = .seeding, .files = archive_files[0..], .peers_list = peers_seed[0..] },
    .{ .name = "EndeavourOS.Mercury.2026.04.iso", .tracker = "linuxtracker.org", .category = "#linux", .size_gib = 45.78, .progress = 0.03, .down_mib = 3.0, .up_mib = 0.6, .seeds = 75, .peers = 119, .ratio = 0.05, .eta_min = 205, .status = .downloading, .files = linux_files[0..], .peers_list = peers_fast[0..] },
    .{ .name = "debian-12.5.0-amd64-DVD-1.iso", .tracker = "linuxtracker.org", .category = "#linux", .size_gib = 22.62, .progress = 0.71, .down_mib = 4.4, .up_mib = 0.3, .seeds = 62, .peers = 85, .ratio = 0.88, .eta_min = 21, .status = .downloading, .files = linux_files[0..], .peers_list = peers_fast[0..] },
    .{ .name = "Slackware-15.1-install-dvd.iso", .tracker = "linuxtracker.org", .category = "#linux", .size_gib = 6.05, .progress = 0.25, .down_mib = 4.5, .up_mib = 1.4, .seeds = 55, .peers = 189, .ratio = 0.21, .eta_min = 31, .status = .downloading, .files = linux_files[0..], .peers_list = peers_fast[0..] },
    .{ .name = "Wikipedia.Dump.en.2026-04-15.xml.bz2", .tracker = "archive.org", .category = "#docs", .size_gib = 8.41, .progress = 0.14, .down_mib = 0.8, .up_mib = 1.4, .seeds = 14, .peers = 14, .ratio = 0.12, .eta_min = 122, .status = .downloading, .files = archive_files[0..], .peers_list = peers_fast[0..] },
    .{ .name = "CC0.Photography.Pack.4K.zip", .tracker = "pubtorrent.io", .category = "#video", .size_gib = 40.20, .progress = 0.47, .down_mib = 1.3, .up_mib = 0.2, .seeds = 65, .peers = 133, .ratio = 0.34, .eta_min = 75, .status = .downloading, .files = media_files[0..], .peers_list = peers_fast[0..] },
    .{ .name = "Cosmos.Laundromat.2015.1080p.mkv", .tracker = "cinemaarchive.tv", .category = "#video", .size_gib = 37.82, .progress = 0.01, .down_mib = 4.6, .up_mib = 0.6, .seeds = 12, .peers = 28, .ratio = 0.02, .eta_min = 340, .status = .downloading, .files = media_files[0..], .peers_list = peers_fast[0..] },
};

pub const torrents = initial_torrents[0..];

test "mock torrents have detail data" {
    try std.testing.expect(torrents.len >= 8);
    try std.testing.expect(torrents[0].files.len > 0);
    try std.testing.expect(torrents[0].peers_list.len > 0);
}
