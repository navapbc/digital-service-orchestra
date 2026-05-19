#!/usr/bin/env python3
"""SDET audit P3-1: scaffolded HTTP mock server for GitHub API.

This is the scaffolded minimum for the audit's "stand up an HTTP mock server"
recommendation. It exposes a tiny stdlib-only HTTP server that:

  - Responds to canned `gh`-equivalent paths (e.g., /repos/X/Y/pulls/Z).
  - Can be configured to return any status code plus headers / body via a
    JSON `--scenario` file or via per-path environment variables.
  - Logs every request to a state directory so tests can assert call
    sequences and headers.

Today's scope is the SCAFFOLD only: structure + 429/Retry-After response
codepath + request logging. The audit notes that wiring `wait-for-pr.sh`,
`mirror-defenses-to-pr.sh`, and `respond-to-pr-comments` against this server
is a multi-day follow-up that should not block the audit's initial commit
series.

Usage:
  python3 tests/mocks/github-api-server.py --port 0 --state-dir /tmp/gh-mock-state
  # The server prints the bound port on stdout (port 0 = auto-assign).

Once started, tests should:
  - Drop a scenario JSON in $STATE_DIR/scenario.json controlling response
    codes / headers / bodies per (method, path-prefix) tuple.
  - Read $STATE_DIR/requests.jsonl to assert which calls were made.

Stdlib only — no Flask, no pytest-httpserver dependency.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

DEFAULT_RESPONSE = {
    "status": 200,
    "headers": {"Content-Type": "application/json"},
    "body": "{}",
}


class _State:
    """Holds the per-test scenario and the request log."""

    def __init__(self, state_dir: str) -> None:
        self.state_dir = state_dir
        os.makedirs(state_dir, exist_ok=True)
        self.scenario_path = os.path.join(state_dir, "scenario.json")
        self.requests_path = os.path.join(state_dir, "requests.jsonl")

    def load_scenario(self) -> dict:
        if not os.path.isfile(self.scenario_path):
            return {}
        try:
            with open(self.scenario_path) as f:
                return json.load(f)
        except (OSError, json.JSONDecodeError):
            return {}

    def log_request(self, method: str, path: str, headers: dict, body: bytes) -> None:
        entry = {
            "method": method,
            "path": path,
            "headers": {k: v for k, v in headers.items()},
            "body_len": len(body),
        }
        with open(self.requests_path, "a") as f:
            f.write(json.dumps(entry) + "\n")


def _match_response(scenario: dict, method: str, path: str) -> dict:
    """Resolve the response for (method, path) from a scenario file.

    Scenario shape:
      {
        "routes": [
          {"method": "GET", "path_prefix": "/repos/X/Y/pulls", "response": {
              "status": 429,
              "headers": {"Retry-After": "1"},
              "body": "{\"message\":\"slow down\"}"
          }}
        ]
      }
    """
    for route in scenario.get("routes", []):
        if route.get("method", method).upper() != method.upper():
            continue
        prefix = route.get("path_prefix", "")
        if prefix and path.startswith(prefix):
            return route.get("response", DEFAULT_RESPONSE)
    return DEFAULT_RESPONSE


class _Handler(BaseHTTPRequestHandler):
    state: _State  # set by the server before serving

    def _handle(self, method: str) -> None:
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else b""
        self.state.log_request(method, self.path, dict(self.headers), body)

        scenario = self.state.load_scenario()
        resp = _match_response(scenario, method, self.path)

        self.send_response(int(resp.get("status", 200)))
        for k, v in (resp.get("headers") or {}).items():
            self.send_header(k, str(v))
        out = (resp.get("body") or "").encode("utf-8")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)

    # silence default access log to stderr — tests parse requests.jsonl instead
    def log_message(self, fmt: str, *args) -> None:  # noqa: ARG002
        return

    def do_GET(self) -> None:
        self._handle("GET")

    def do_POST(self) -> None:
        self._handle("POST")

    def do_PUT(self) -> None:
        self._handle("PUT")

    def do_DELETE(self) -> None:
        self._handle("DELETE")

    def do_PATCH(self) -> None:
        self._handle("PATCH")


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    parser.add_argument("--port", type=int, default=0, help="0 = auto-assign")
    parser.add_argument("--state-dir", required=True)
    args = parser.parse_args(argv)

    state = _State(args.state_dir)

    handler = _Handler
    handler.state = state  # type: ignore[attr-defined]
    server = ThreadingHTTPServer(("127.0.0.1", args.port), handler)
    bound = server.server_address[1]
    print(bound, flush=True)

    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
