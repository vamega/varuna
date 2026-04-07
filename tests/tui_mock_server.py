#!/usr/bin/env python3
"""Mock qBittorrent WebAPI server for TUI integration tests.

Responds to the same endpoints that varuna-tui expects, returning
canned JSON data.  Runs on localhost:18080 by default.
"""

import json
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

PORT = int(sys.argv[1]) if len(sys.argv) > 1 else 18080

TORRENTS = [
    {
        "hash": "aaaa1111bbbb2222cccc3333dddd4444eeee5555",
        "name": "ubuntu-24.04-desktop-amd64.iso",
        "size": 4700000000,
        "progress": 0.75,
        "dlspeed": 5242880,
        "upspeed": 1048576,
        "num_seeds": 42,
        "num_leechs": 7,
        "state": "downloading",
        "eta": 600,
        "ratio": 0.35,
        "added_on": 1712400000,
        "completed": 3525000000,
        "total_size": 4700000000,
        "downloaded": 3525000000,
        "uploaded": 1234567,
        "save_path": "/downloads",
        "category": "linux",
        "tags": "iso,ubuntu",
        "tracker": "http://tracker.example.com/announce",
        "num_complete": 100,
        "num_incomplete": 15,
        "seq_dl": False,
        "super_seeding": False,
        "dl_limit": 0,
        "up_limit": 0,
    },
    {
        "hash": "ffff6666aaaa7777bbbb8888cccc9999dddd0000",
        "name": "archlinux-2024.04.01-x86_64.iso",
        "size": 900000000,
        "progress": 1.0,
        "dlspeed": 0,
        "upspeed": 524288,
        "num_seeds": 0,
        "num_leechs": 3,
        "state": "uploading",
        "eta": 8640000,
        "ratio": 2.5,
        "added_on": 1712300000,
        "completed": 900000000,
        "total_size": 900000000,
        "downloaded": 900000000,
        "uploaded": 2250000000,
        "save_path": "/downloads",
        "category": "linux",
        "tags": "iso,arch",
        "tracker": "http://tracker.example.com/announce",
        "num_complete": 50,
        "num_incomplete": 3,
        "seq_dl": False,
        "super_seeding": False,
        "dl_limit": 0,
        "up_limit": 0,
    },
]

TRANSFER_INFO = {
    "dl_info_speed": 5242880,
    "dl_info_data": 3525000000,
    "up_info_speed": 1572864,
    "up_info_data": 2250000000,
    "dl_rate_limit": 0,
    "up_rate_limit": 0,
    "dht_nodes": 450,
    "connection_status": "connected",
}

PREFERENCES = {
    "listen_port": 6881,
    "dl_limit": 0,
    "up_limit": 0,
    "max_connec": 500,
    "max_connec_per_torrent": 100,
    "max_uploads": 20,
    "max_uploads_per_torrent": 5,
    "dht": True,
    "pex": True,
    "save_path": "/downloads",
    "enable_utp": True,
    "web_ui_port": 18080,
}

FILES = [
    {"index": 0, "name": "ubuntu-24.04-desktop-amd64.iso", "size": 4700000000, "progress": 0.75, "priority": 1, "availability": 1.0},
]

TRACKERS = [
    {"url": "http://tracker.example.com/announce", "status": 2, "tier": 0, "num_peers": 49, "num_seeds": 100, "num_leeches": 15, "msg": ""},
]

PROPERTIES = {
    "save_path": "/downloads",
    "total_size": 4700000000,
    "pieces_num": 4492,
    "piece_size": 1048576,
    "creation_date": 1712000000,
    "comment": "Ubuntu 24.04 LTS Desktop",
    "nb_connections": 25,
    "seeds": 42,
    "peers": 7,
    "seeds_total": 100,
    "peers_total": 15,
    "dl_speed": 5242880,
    "up_speed": 1048576,
    "addition_date": 1712400000,
    "completion_date": 0,
}

# Track state changes
removed_hashes = set()
paused_hashes = set()


class Handler(BaseHTTPRequestHandler):
    def log_message(self, format, *args):
        # Suppress request logging for cleaner test output
        pass

    def _json(self, data, status=200):
        body = json.dumps(data).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _ok(self):
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"Ok")

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/api/v2/torrents/info":
            visible = [t for t in TORRENTS if t["hash"] not in removed_hashes]
            for t in visible:
                if t["hash"] in paused_hashes:
                    t = dict(t, state="pausedDL")
            self._json(visible)
        elif path == "/api/v2/transfer/info":
            self._json(TRANSFER_INFO)
        elif path == "/api/v2/torrents/properties":
            self._json(PROPERTIES)
        elif path == "/api/v2/torrents/files":
            self._json(FILES)
        elif path == "/api/v2/torrents/trackers":
            self._json(TRACKERS)
        elif path == "/api/v2/app/preferences":
            self._json(PREFERENCES)
        else:
            self.send_error(404)

    def do_POST(self):
        parsed = urlparse(self.path)
        path = parsed.path
        content_len = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_len).decode() if content_len > 0 else ""

        if path == "/api/v2/auth/login":
            self.send_response(200)
            self.send_header("Set-Cookie", "SID=test_session_id; path=/")
            self.send_header("Content-Length", "2")
            self.end_headers()
            self.wfile.write(b"Ok")
        elif path == "/api/v2/torrents/add":
            self._ok()
        elif path == "/api/v2/torrents/delete":
            params = parse_qs(body)
            hashes = params.get("hashes", [""])[0].split("|")
            for h in hashes:
                removed_hashes.add(h)
            self._ok()
        elif path == "/api/v2/torrents/pause":
            params = parse_qs(body)
            hashes = params.get("hashes", [""])[0].split("|")
            for h in hashes:
                paused_hashes.add(h)
            self._ok()
        elif path == "/api/v2/torrents/resume":
            params = parse_qs(body)
            hashes = params.get("hashes", [""])[0].split("|")
            for h in hashes:
                paused_hashes.discard(h)
            self._ok()
        elif path == "/api/v2/app/setPreferences":
            self._ok()
        else:
            self.send_error(404)


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", PORT), Handler)
    print(f"Mock qBittorrent API running on http://127.0.0.1:{PORT}")
    sys.stdout.flush()
    server.serve_forever()
