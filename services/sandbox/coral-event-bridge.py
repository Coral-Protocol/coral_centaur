#!/usr/bin/env python3
"""Lightweight HTTP server that receives coral-server webhook events and
forwards them to the Centaur API for persistence in Postgres.

Runs inside the sandbox pod alongside coral-server. Listens on a local port
(default 5556) and POSTs events to the Centaur tool-server API.

Usage:
    python3 coral-event-bridge.py &

Environment:
    CENTAUR_API_URL     Base URL of the Centaur API (default: http://api:8000)
    CENTAUR_API_KEY     Bearer token for Centaur API auth
    CENTAUR_THREAD_KEY  Thread key for the current Centaur session
    CORAL_BRIDGE_PORT   Port to listen on (default: 5556)
"""

import json
import os
import sys
from http.server import HTTPServer, BaseHTTPRequestHandler
from urllib.request import Request, urlopen
from urllib.error import URLError


CENTAUR_API_URL = os.environ.get("CENTAUR_API_URL", "http://api:8000")
CENTAUR_API_KEY = os.environ.get("CENTAUR_API_KEY", "")
CENTAUR_THREAD_KEY = os.environ.get("CENTAUR_THREAD_KEY", "")
BRIDGE_PORT = int(os.environ.get("CORAL_BRIDGE_PORT", "5556"))


def forward_to_centaur(event: dict) -> None:
    """POST a coral event to Centaur API for persistence."""
    payload = {
        "thread_key": CENTAUR_THREAD_KEY,
        "coral_session_id": event.get("sessionId", ""),
        "event_type": event.get("type", "unknown"),
        "agent_name": event.get("agentName"),
        "payload": event,
    }
    body = json.dumps(payload).encode()
    headers = {
        "Content-Type": "application/json",
    }
    if CENTAUR_API_KEY:
        headers["Authorization"] = f"Bearer {CENTAUR_API_KEY}"

    req = Request(
        f"{CENTAUR_API_URL}/coral/events",
        data=body,
        headers=headers,
        method="POST",
    )
    try:
        with urlopen(req, timeout=5) as resp:
            resp.read()
    except URLError as exc:
        print(f"coral-event-bridge: failed to forward event: {exc}", file=sys.stderr)


class WebhookHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length) if length else b""
        try:
            event = json.loads(body) if body else {}
        except json.JSONDecodeError:
            self.send_response(400)
            self.end_headers()
            return

        forward_to_centaur(event)

        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}')

    def log_message(self, fmt, *args):
        # Suppress default request logging to reduce noise
        pass


if __name__ == "__main__":
    server = HTTPServer(("127.0.0.1", BRIDGE_PORT), WebhookHandler)
    print(f"coral-event-bridge listening on 127.0.0.1:{BRIDGE_PORT}")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
