#!/usr/bin/env python3
"""Minimal HTTP server with Range request support for BEP 19 web seed testing.

Serves files from a directory with proper Range header handling:
- 200 for full file requests
- 206 with Content-Range for Range requests
- 416 for invalid ranges

Tracks request count in a JSON stats endpoint for test verification.

Usage:
    python3 scripts/web_seed_server.py --port 8888 --dir /path/to/files
"""

import argparse
import json
import os
import sys
import threading
from http.server import ThreadingHTTPServer, BaseHTTPRequestHandler


class RangeHTTPHandler(BaseHTTPRequestHandler):
    """HTTP handler that supports Range requests for web seed compatibility."""

    # Use HTTP/1.1 for keep-alive support (HTTP/1.0 closes after each response)
    protocol_version = "HTTP/1.1"
    serve_dir = "."

    # Shared request counter (thread-safe via lock)
    _stats_lock = threading.Lock()
    _request_count = 0
    _range_request_count = 0

    def do_GET(self):
        # URL-decode the path and resolve relative to serve_dir
        from urllib.parse import unquote
        rel_path = unquote(self.path.lstrip("/"))

        # Stats endpoint for test verification
        if rel_path == "_stats":
            self._serve_stats()
            return

        # Reset endpoint for between test scenarios
        if rel_path == "_reset":
            self._reset_stats()
            return

        file_path = os.path.join(self.serve_dir, rel_path)

        if not os.path.isfile(file_path):
            self.send_error(404, f"File not found: {rel_path}")
            return

        file_size = os.path.getsize(file_path)
        range_header = self.headers.get("Range")

        with RangeHTTPHandler._stats_lock:
            RangeHTTPHandler._request_count += 1
            if range_header:
                RangeHTTPHandler._range_request_count += 1

        if range_header:
            self._serve_range(file_path, file_size, range_header)
        else:
            self._serve_full(file_path, file_size)

    def _serve_full(self, file_path, file_size):
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(file_size))
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()
        with open(file_path, "rb") as f:
            self.wfile.write(f.read())

    def _serve_range(self, file_path, file_size, range_header):
        # Parse "bytes=start-end"
        if not range_header.startswith("bytes="):
            self.send_error(416, "Invalid Range header")
            return

        range_spec = range_header[6:]
        parts = range_spec.split("-")
        if len(parts) != 2:
            self.send_error(416, "Invalid Range format")
            return

        try:
            start = int(parts[0]) if parts[0] else 0
            end = int(parts[1]) if parts[1] else file_size - 1
        except ValueError:
            self.send_error(416, "Invalid Range values")
            return

        if start >= file_size or end >= file_size or start > end:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{file_size}")
            self.end_headers()
            return

        content_length = end - start + 1
        self.send_response(206)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Content-Length", str(content_length))
        self.send_header("Content-Range", f"bytes {start}-{end}/{file_size}")
        self.send_header("Accept-Ranges", "bytes")
        self.end_headers()

        with open(file_path, "rb") as f:
            f.seek(start)
            self.wfile.write(f.read(content_length))

    def _serve_stats(self):
        """Return request statistics as JSON."""
        with RangeHTTPHandler._stats_lock:
            stats = {
                "request_count": RangeHTTPHandler._request_count,
                "range_request_count": RangeHTTPHandler._range_request_count,
            }
        body = json.dumps(stats).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _reset_stats(self):
        """Reset request counters (called between test scenarios)."""
        with RangeHTTPHandler._stats_lock:
            RangeHTTPHandler._request_count = 0
            RangeHTTPHandler._range_request_count = 0
        body = b'{"status":"reset"}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, format, *args):
        # Suppress request logging unless DEBUG is set
        if os.environ.get("DEBUG"):
            super().log_message(format, *args)


def main():
    parser = argparse.ArgumentParser(description="Web seed HTTP server with Range support")
    parser.add_argument("--port", type=int, default=8888)
    parser.add_argument("--dir", default=".")
    parser.add_argument("--bind", default="127.0.0.1")
    args = parser.parse_args()

    RangeHTTPHandler.serve_dir = os.path.abspath(args.dir)
    ThreadingHTTPServer.allow_reuse_address = True
    server = ThreadingHTTPServer((args.bind, args.port), RangeHTTPHandler)
    print(f"web seed server: http://{args.bind}:{args.port}/ serving {args.dir}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    server.server_close()


if __name__ == "__main__":
    main()
