#!/usr/bin/env python3
"""Backchannel - Slack slash-command shim.

Slack posts slash commands as `application/x-www-form-urlencoded`, and this
build of Jac only binds JSON request bodies onto walker fields (a form body
returns 422). This is a ~60-line translator: it accepts Slack's form POST,
verifies the HMAC signature, and forwards the fields as JSON to the brain's
`/slack/command` endpoint.

Run it beside the brain:

    python3 ears/slack_shim.py --brain http://localhost:8000 --port 3030

Then point the slash command's Request URL at this process (via a tunnel, or
run it on the same host as a public deployment).

If you would rather not run a second process at all, skip this entirely and
talk to the bot by mentioning it: `@Backchannel <same commands>` works through
the polling bridge with no public URL.
"""

import argparse
import hashlib
import hmac
import json
import os
import time
import urllib.parse
import urllib.request
from http.server import BaseHTTPRequestHandler, HTTPServer

BRAIN = "http://localhost:8000"
SIGNING_SECRET = os.environ.get("SLACK_SIGNING_SECRET", "")


def verify(body: str, timestamp: str, signature: str) -> bool:
    """Slack's v0 HMAC scheme. Without a secret configured we accept (dev only)."""
    if not SIGNING_SECRET:
        return True
    if not timestamp or not signature:
        return False
    try:
        if abs(time.time() - float(timestamp)) > 300:
            return False  # replay of an old captured request
    except ValueError:
        return False
    digest = hmac.new(
        SIGNING_SECRET.encode(), f"v0:{timestamp}:{body}".encode(), hashlib.sha256
    ).hexdigest()
    return hmac.compare_digest(f"v0={digest}", signature)


class Handler(BaseHTTPRequestHandler):
    def _send(self, payload, status=200):
        blob = json.dumps(payload).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(blob)))
        self.end_headers()
        self.wfile.write(blob)

    def do_POST(self):
        length = int(self.headers.get("Content-Length", 0))
        body = self.rfile.read(length).decode()

        if not verify(
            body,
            self.headers.get("X-Slack-Request-Timestamp", ""),
            self.headers.get("X-Slack-Signature", ""),
        ):
            self._send({"text": "Signature verification failed."}, 401)
            return

        # Form fields arrive as lists; Slack sends one value for each.
        fields = {k: v[0] for k, v in urllib.parse.parse_qs(body).items()}
        payload = {
            "command": fields.get("command", ""),
            "text": fields.get("text", ""),
            "user_name": fields.get("user_name", ""),
            "channel_name": fields.get("channel_name", ""),
            "response_url": fields.get("response_url", ""),
        }

        try:
            req = urllib.request.Request(
                f"{BRAIN}/slack/command",
                data=json.dumps(payload).encode(),
                headers={"Content-Type": "application/json"},
            )
            with urllib.request.urlopen(req, timeout=10) as resp:
                envelope = json.loads(resp.read().decode())
            reports = (envelope.get("data") or {}).get("reports") or []
            self._send(reports[0] if reports else {"text": "No response."})
        except Exception as exc:
            self._send({"text": f"Backchannel is unreachable: {exc}"})

    def log_message(self, fmt, *args):
        print(f"  [shim] {fmt % args}")


def main():
    global BRAIN
    ap = argparse.ArgumentParser(description="Slack form -> Jac JSON shim")
    ap.add_argument("--brain", default="http://localhost:8000")
    ap.add_argument("--port", type=int, default=3030)
    args = ap.parse_args()
    BRAIN = args.brain.rstrip("/")

    if not SIGNING_SECRET:
        print("  [shim] SLACK_SIGNING_SECRET unset - signature checks disabled (dev only)")
    print(f"  [shim] listening on :{args.port}, forwarding to {BRAIN}/slack/command")
    HTTPServer(("0.0.0.0", args.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
