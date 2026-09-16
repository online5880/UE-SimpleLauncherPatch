#!/usr/bin/env python3
"""Rate-limited local CDN for testing launcher progress UI.
Serves Patch\\Cloud on 127.0.0.1:8080 at ~MB/s. Run:
    python Patch\\Throttle-CDN.py [mbps]      # default 8 MB/s
HEAD requests answered instantly (Content-Length); GET bodies are throttled.
"""
import http.server
import os
import sys
import time

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "Cloud")
RATE_MBPS = float(sys.argv[1]) if len(sys.argv) > 1 else 8.0
CHUNK = 256 * 1024
DELAY = CHUNK / (RATE_MBPS * 1024 * 1024)


class Handler(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self):
        self._serve(head_only=True)

    def do_GET(self):
        self._serve(head_only=False)

    def _serve(self, head_only):
        path = self.path.split("?")[0].lstrip("/").lstrip("\\").replace("/", os.sep).replace("\\", os.sep)
        fp = os.path.join(ROOT, path)
        if not os.path.isfile(fp):
            self.send_error(404)
            return
        size = os.path.getsize(fp)
        self.send_response(200)
        self.send_header("Content-Length", str(size))
        self.end_headers()
        if head_only:
            return
        try:
            with open(fp, "rb") as f:
                while True:
                    buf = f.read(CHUNK)
                    if not buf:
                        break
                    self.wfile.write(buf)
                    self.wfile.flush()
                    time.sleep(DELAY)
        except (BrokenPipeError, ConnectionResetError):
            pass  # client aborted mid-transfer

    def log_message(self, fmt, *args):
        pass


print("Throttle CDN: {} on 127.0.0.1:8080 @ {} MB/s".format(ROOT, RATE_MBPS), flush=True)
http.server.ThreadingHTTPServer(("127.0.0.1", 8080), Handler).serve_forever()