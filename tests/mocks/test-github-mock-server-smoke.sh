#!/usr/bin/env bash
# tests/mocks/test-github-mock-server-smoke.sh
# Smoke test for the scaffolded GitHub HTTP mock (audit P3-1).
#
# Verifies:
#   1. The server binds and reports its auto-assigned port.
#   2. A default GET returns the canned 200 response.
#   3. A scenario-configured 429 with Retry-After header is observable.
#   4. Requests are logged to $STATE_DIR/requests.jsonl.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SERVER="$REPO_ROOT/tests/mocks/github-api-server.py"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-github-mock-server-smoke.sh ==="

if [[ ! -f "$SERVER" ]]; then
    echo "SKIP: $SERVER not found"
    printf "PASSED: %d  FAILED: %d\n" "$PASS" "$FAIL"
    exit 0
fi

TEST_TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/gh-mock-smoke.XXXXXX")
STATE_DIR="$TEST_TMPDIR/state"

_start_server() {
    python3 "$SERVER" --port 0 --state-dir "$STATE_DIR" &
    SERVER_PID=$!
    # Wait for the server to print its port.
    sleep 0.5
}

_stop_server() {
    [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null || true
    rm -rf "$TEST_TMPDIR"
}
trap _stop_server EXIT

# ─── Test 1 — server starts and accepts a default 200 GET ────────────────────
echo ""
echo "--- test_default_200_response ---"

test_default_200_response() {
    _snapshot_fail
    mkdir -p "$STATE_DIR"

    # Start with stdout to a tmpfile so we can read the bound port.
    local port_file
    port_file=$(mktemp "$TEST_TMPDIR/port.XXXXXX")
    python3 "$SERVER" --port 0 --state-dir "$STATE_DIR" > "$port_file" 2>/dev/null &
    SERVER_PID=$!
    local i=0
    local port=""
    while [[ -z "$port" && $i -lt 20 ]]; do
        sleep 0.1
        port=$(head -n1 "$port_file" 2>/dev/null | tr -d '[:space:]')
        i=$(( i + 1 ))
    done

    if [[ -z "$port" ]]; then
        (( ++FAIL ))
        echo "FAIL: mock server did not report a bound port within 2s" >&2
        kill "$SERVER_PID" 2>/dev/null || true
        return
    fi

    local status
    status=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${port}/healthz" || echo "000")
    assert_eq "default response is 200" "200" "$status"

    # And the request was logged.
    local logged_count
    logged_count=$(wc -l < "$STATE_DIR/requests.jsonl" 2>/dev/null | tr -d ' ')
    assert_eq "request logged to requests.jsonl" "1" "$logged_count"

    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
    assert_pass_if_clean "test_default_200_response"
}
test_default_200_response

# ─── Test 2 — scenario configured 429 with Retry-After ───────────────────────
echo ""
echo "--- test_scenario_429_with_retry_after ---"

test_scenario_429_with_retry_after() {
    _snapshot_fail
    : > "$STATE_DIR/requests.jsonl"

    cat > "$STATE_DIR/scenario.json" <<'JSON'
{
  "routes": [
    {
      "method": "GET",
      "path_prefix": "/repos/",
      "response": {
        "status": 429,
        "headers": {"Retry-After": "1"},
        "body": "{\"message\":\"slow down\"}"
      }
    }
  ]
}
JSON

    local port_file
    port_file=$(mktemp "$TEST_TMPDIR/port2.XXXXXX")
    python3 "$SERVER" --port 0 --state-dir "$STATE_DIR" > "$port_file" 2>/dev/null &
    SERVER_PID=$!
    local i=0
    local port=""
    while [[ -z "$port" && $i -lt 20 ]]; do
        sleep 0.1
        port=$(head -n1 "$port_file" 2>/dev/null | tr -d '[:space:]')
        i=$(( i + 1 ))
    done

    local status retry headers_file
    headers_file=$(mktemp "$TEST_TMPDIR/headers.XXXXXX")
    # Use GET (not HEAD) — the mock server's BaseHTTPRequestHandler only
    # implements do_GET/POST/etc., not do_HEAD.
    status=$(curl -s -o /dev/null -D "$headers_file" -w '%{http_code}' "http://127.0.0.1:${port}/repos/anthropic-internal/dso/pulls/1")
    retry=$(awk '/^[Rr]etry-[Aa]fter:/{print $2}' "$headers_file" | tr -d '\r\n')

    assert_eq "scenario 429 returned" "429" "$status"
    assert_eq "Retry-After header forwarded" "1" "$retry"

    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
    SERVER_PID=""
    assert_pass_if_clean "test_scenario_429_with_retry_after"
}
test_scenario_429_with_retry_after

print_summary
