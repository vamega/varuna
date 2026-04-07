#!/usr/bin/env python3
"""Mock qBittorrent-compatible API server for TUI integration tests.

Responds to the API endpoints used by varuna-tui with static test data.
"""

import json
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.parse import urlparse, parse_qs

# Test data
TORRENTS = [
    {
        "name": "ubuntu-24.04-desktop-amd64.iso",
        "hash": "abc123def456abc123def456abc123def456abcd",
        "state": "downloading",
        "size": 5242880000,
        "progress": 0.42,
        "dlspeed": 1048576,
        "upspeed": 262144,
        "num_seeds": 15,
        "num_leechs": 3,
        "eta": 3600,
        "ratio": 0.25,
        "downloaded": 2201580800,
        "uploaded": 550395200,
        "save_path": "/downloads",
        "tracker": "http://tracker.example.com:6969/announce",
        "category": "linux",
        "tags": "iso,ubuntu",
        "added_on": 1712000000,
    },
    {
        "name": "archlinux-2024.04.01-x86_64.iso",
        "hash": "def789ghi012def789ghi012def789ghi012defg",
        "state": "uploading",
        "size": 1073741824,
        "progress": 1.0,
        "dlspeed": 0,
        "upspeed": 524288,
        "num_seeds": 0,
        "num_leechs": 8,
        "eta": -1,
        "ratio": 2.5,
        "downloaded": 1073741824,
        "uploaded": 2684354560,
        "save_path": "/downloads",
        "tracker": "http://tracker.archlinux.org:6969/announce",
        "category": "linux",
        "tags": "iso,arch",
        "added_on": 1711000000,
    },
    {
        "name": "test-paused-torrent.tar.gz",
        "hash": "111222333444555666777888999000aaabbbcccdd",
        "state": "pausedDL",
        "size": 52428800,
        "progress": 0.1,
        "dlspeed": 0,
        "upspeed": 0,
        "num_seeds": 0,
        "num_leechs": 0,
        "eta": -1,
        "ratio": 0.0,
        "downloaded": 5242880,
        "uploaded": 0,
        "save_path": "/downloads",
        "tracker": "http://tracker.example.com:6969/announce",
        "category": "",
        "tags": "",
        "added_on": 1710000000,
    },
]

TRANSFER_INFO = {
    "dl_info_speed": 1048576,
    "up_info_speed": 786432,
    "dl_info_data": 10737418240,
    "up_info_data": 5368709120,
    "dht_nodes": 42,
}

PROPERTIES = {
    "save_path": "/downloads",
    "total_size": 5242880000,
    "pieces_num": 2500,
    "piece_size": 2097152,
    "nb_connections": 25,
    "seeds_total": 150,
    "peers_total": 45,
    "addition_date": 1712000000,
    "comment": "Ubuntu 24.04 LTS",
}

TRACKERS = [
    {
        "url": "http://tracker.example.com:6969/announce",
        "status": 2,
        "msg": "",
        "num_seeds": 150,
        "num_leeches": 45,
        "num_peers": 195,
    },
    {
        "url": "udp://tracker2.example.com:6969/announce",
        "status": 4,
        "msg": "Connection timed out",
        "num_seeds": 0,
        "num_leeches": 0,
        "num_peers": 0,
    },
]

FILES = [
    {
        "name": "ubuntu-24.04-desktop-amd64.iso",
        "size": 5242880000,
        "progress": 0.42,
        "priority": 1,
        "index": 0,
    },
]

PREFERENCES = {
    "listen_port": 6881,
    "dl_limit": 0,
    "up_limit": 0,
    "max_connec": 500,
    "max_connec_per_torrent": 100,
    "max_uploads": 20,
    "max_uploads_per_torrent": 4,
    "dht": True,
    "pex": True,
    "enable_utp": True,
    "save_path": "/downloads",
    "web_ui_port": 8080,
}

# Track state changes for test verification
state = {
    "torrents": list(TORRENTS),
    "paused": set(),
    "deleted": set(),
}


class MockHandler(BaseHTTPRequestHandler):
    def log_message(self, fmt, *args):
        # Suppress default logging
        pass

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        params = parse_qs(parsed.query)

        if path == "/api/v2/torrents/info":
            active = [t for t in state["torrents"] if t["hash"] not in state["deleted"]]
            for t in active:
                if t["hash"] in state["paused"]:
                    t["state"] = "pausedDL"
                    t["dlspeed"] = 0
                    t["upspeed"] = 0
            self.respond_json(active)

        elif path == "/api/v2/transfer/info":
            self.respond_json(TRANSFER_INFO)

        elif path == "/api/v2/torrents/properties":
            self.respond_json(PROPERTIES)

        elif path == "/api/v2/torrents/trackers":
            self.respond_json(TRACKERS)

        elif path == "/api/v2/torrents/files":
            self.respond_json(FILES)

        elif path == "/api/v2/app/preferences":
            self.respond_json(PREFERENCES)

        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        content_length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(content_length).decode() if content_length > 0 else ""
        parsed = urlparse(self.path)
        path = parsed.path

        if path == "/api/v2/auth/login":
            # Accept any credentials
            self.send_response(200)
            self.send_header("Content-Type", "text/plain")
            self.send_header("Set-Cookie", "SID=test_session_id; Path=/")
            self.end_headers()
            self.wfile.write(b"Ok.")

        elif path == "/api/v2/torrents/add":
            # Add a new mock torrent
            new_torrent = {
                "name": "newly-added-torrent.iso",
                "hash": "new123new456new789new012new345new678new90",
                "state": "downloading",
                "size": 100000000,
                "progress": 0.0,
                "dlspeed": 0,
                "upspeed": 0,
                "num_seeds": 0,
                "num_leechs": 0,
                "eta": -1,
                "ratio": 0.0,
                "downloaded": 0,
                "uploaded": 0,
                "save_path": "/downloads",
                "tracker": "",
                "category": "",
                "tags": "",
                "added_on": 1712100000,
            }
            state["torrents"].append(new_torrent)
            self.send_response(200)
            self.end_headers()

        elif path == "/api/v2/torrents/delete":
            # Parse hash from body
            for pair in body.split("&"):
                if pair.startswith("hashes="):
                    hash_val = pair[7:]
                    state["deleted"].add(hash_val)
            self.send_response(200)
            self.end_headers()

        elif path == "/api/v2/torrents/pause":
            for pair in body.split("&"):
                if pair.startswith("hashes="):
                    hash_val = pair[7:]
                    state["paused"].add(hash_val)
            self.send_response(200)
            self.end_headers()

        elif path == "/api/v2/torrents/resume":
            for pair in body.split("&"):
                if pair.startswith("hashes="):
                    hash_val = pair[7:]
                    state["paused"].discard(hash_val)
            self.send_response(200)
            self.end_headers()

        elif path == "/api/v2/app/setPreferences":
            self.send_response(200)
            self.end_headers()

        else:
            self.send_response(404)
            self.end_headers()

    def respond_json(self, data):
        body = json.dumps(data).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


def main():
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 18080
    server = HTTPServer(("127.0.0.1", port), MockHandler)
    print(f"Mock API server listening on http://127.0.0.1:{port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()


if __name__ == "__main__":
    main()
