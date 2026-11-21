"""Loopback-only fixture. Exit when the AppKit parent quits."""
import json
import os
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
import plistlib

script = Path(__file__).resolve()
apps = script.parents[3]
parent = os.getppid()
version = plistlib.loads((script.parents[1] / "Info.plist").read_bytes())["CFBundleVersion"]


class Health(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path != "/api/health":
            self.send_error(404)
            return
        data = dict(ok=True, version=version, parent_pid=parent, pid=os.getpid(), script_path=str(script))
        fault = apps / "fault"
        if fault.exists():
            field = fault.read_text().strip()
            data[field] = {"version": "other", "pid": -1, "parent_pid": -1, "script_path": "/wrong"}[field]
        body = json.dumps(data).encode()
        self.send_response(200)
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *args):
        pass


with HTTPServer(("127.0.0.1", 0), Health) as server:
    server.timeout = 0.2
    (apps / f"{parent}.port").write_text(str(server.server_port))
    while os.getppid() == parent:
        server.handle_request()
