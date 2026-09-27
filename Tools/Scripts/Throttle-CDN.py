#!/usr/bin/env python3
"""Rate-limited local CDN with HTTP Range support.
Run: python Throttle-CDN.py [mbps] [root] [port] [drop_once_bytes]
Defaults: 8 MB/s, sibling Cloud directory, port 8080.
"""
import http.server
import mimetypes
import os
import re
import sys
import time
from urllib.parse import unquote, urlsplit

ROOT = os.path.realpath(sys.argv[2]) if len(sys.argv) > 2 else os.path.realpath(
    os.path.join(os.path.dirname(os.path.abspath(__file__)), "Cloud"))
RATE_MBPS = float(sys.argv[1]) if len(sys.argv) > 1 else 8.0
if RATE_MBPS <= 0:
    raise SystemExit("mbps must be positive")
PORT = int(sys.argv[3]) if len(sys.argv) > 3 else 8080
DROP_ONCE_BYTES = int(sys.argv[4]) if len(sys.argv) > 4 else 0
CHUNK = 256 * 1024
DELAY = CHUNK / (RATE_MBPS * 1024 * 1024)


class Handler(http.server.BaseHTTPRequestHandler):
    dropped = False

    def do_HEAD(self):
        self._serve(head_only=True)

    def do_GET(self):
        self._serve(head_only=False)

    def _serve(self, head_only):
        path = unquote(urlsplit(self.path).path).lstrip("/").replace("/", os.sep)
        fp = os.path.realpath(os.path.join(ROOT, path))
        if os.path.commonpath((ROOT, fp)) != ROOT:
            self.send_error(403)
            return
        if not os.path.isfile(fp):
            self.send_error(404)
            return
        size = os.path.getsize(fp)
        start, end = 0, size - 1
        requested = self.headers.get("Range")
        if requested:
            match = re.fullmatch(r"bytes=(\d+)-(\d*)", requested)
            if not match or int(match.group(1)) >= size:
                self.send_error(416)
                return
            start = int(match.group(1))
            if match.group(2):
                end = min(int(match.group(2)), end)
            if end < start:
                self.send_error(416)
                return
        self.send_response(206 if requested else 200)
        self.send_header("Accept-Ranges", "bytes")
        self.send_header("Content-Type", mimetypes.guess_type(fp)[0] or "application/octet-stream")
        self.send_header("Content-Length", str(end - start + 1))
        if requested:
            self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.end_headers()
        if head_only:
            return
        try:
            with open(fp, "rb") as f:
                f.seek(start)
                remaining = end - start + 1
                # ponytail: test-only one-shot truncation; default 0 keeps the local CDN normal.
                if DROP_ONCE_BYTES and not Handler.dropped and "/Full/Objects/" in self.path:
                    Handler.dropped = True
                    remaining = min(remaining, DROP_ONCE_BYTES)
                while remaining:
                    buf = f.read(min(CHUNK, remaining))
                    if not buf:
                        break
                    self.wfile.write(buf)
                    self.wfile.flush()
                    remaining -= len(buf)
                    time.sleep(DELAY)
        except (BrokenPipeError, ConnectionResetError):
            pass  # client aborted mid-transfer

print("Local CDN: {} on 127.0.0.1:{} @ {} MB/s".format(ROOT, PORT, RATE_MBPS), flush=True)
http.server.ThreadingHTTPServer(("127.0.0.1", PORT), Handler).serve_forever()
