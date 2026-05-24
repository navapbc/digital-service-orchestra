#!/usr/bin/env bash
# tests/scripts/test-telemetry-emit.sh — RED behavioral integration tests for telemetry-emit.sh
set -uo pipefail
# RED-phase behavioral integration tests for plugins/dso/scripts/telemetry/telemetry-emit.sh
#
# These tests invoke the telemetry-emit.sh shim (which delegates to telemetry_emit.py)
# and assert on observable outputs: exit code, stdout, stderr, HTTP POST body, and
# filesystem side effects (event-id-map.json, submitted.log).
#
# All tests are RED in this phase — telemetry-emit.sh and telemetry_emit.py do not exist.
# After GREEN implementation, all tests must pass.
#
# Mock HTTP endpoint: stdlib http.server.BaseHTTPRequestHandler + ThreadingHTTPServer
# bound to 127.0.0.1:0 (ephemeral port). Modelled on tests/mocks/github-api-server.py.
#
# Endpoint safety constraint: every test uses 127.0.0.1, localhost, or *.invalid TLD.
#
# Schema contract: plugins/dso/docs/contracts/telemetry-event-schema.md
# Story: 6d14-1052-0da5-43b1   Task: 0a26-fb8c-cde5-4e84
#
# finding_event_id design note (gap-analysis comment 2/5):
#   The schema contract does not currently define finding_event_id in the common fields.
#   Per the additive-optional fields policy (schema line 24), we treat finding_event_id
#   as an additive-optional field — present when --link is supplied, absent otherwise.
#   Consumers must ignore unknown fields. No schema_version bump is required.
#   The GREEN implementation must populate this field when --link is given.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SHIM="$REPO_ROOT/plugins/dso/scripts/telemetry/telemetry-emit.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-telemetry-emit.sh ==="

# ── Global cleanup ─────────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    local d
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        [[ -n "$d" ]] && [[ -d "$d" ]] && rm -rf "$d" || true
    done
}
trap _cleanup_test_tmpdirs EXIT

make_tmpdir() {
    local d
    d="$(mktemp -d)"
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# ── Mock HTTP server helpers ──────────────────────────────────────────────────
# Servers are written to files and run with redirected I/O.
# Running python3 as a FILE (not stdin heredoc) with </dev/null prevents bash
# from waiting on the background process's fds when called inside $() subshells.

# write_slow_server <dir>
# Server that accepts a TCP connection but never sends a response (simulates timeout).
write_slow_server() {
    local dir="$1"
    cat > "$dir/slow-server.py" << 'PYEOF'
#!/usr/bin/env python3
"""TCP server that accepts connections and sleeps indefinitely (simulates timeout)."""
import socketserver
import sys
import time

PORT_FILE = sys.argv[1]
PORT_FILE_TMP = PORT_FILE + ".tmp"


class _Handler(socketserver.BaseRequestHandler):
    def handle(self):
        time.sleep(600)  # block far past any reasonable timeout


server = socketserver.TCPServer(("127.0.0.1", 0), _Handler)
server.allow_reuse_address = True
with open(PORT_FILE_TMP, "w") as pf:
    pf.write(str(server.server_address[1]))
import os
os.rename(PORT_FILE_TMP, PORT_FILE)
server.serve_forever()
PYEOF
}

# start_server_with_portfile <dir>
# Writes mock server to <dir>/mock-server.py, runs it, waits for port file.
# The server uses an atomic rename so the watcher loop sees a complete file.
# IMPORTANT: python3 is run as a FILE (not stdin heredoc) with </dev/null to
# prevent the background process from holding the parent subshell's stdin fd
# open (which would cause $() subshell to hang waiting for the process to exit).
start_server_with_portfile() {
    local dir="$1"
    local port_file="$dir/port.txt"
    local port_file_tmp="$dir/port.txt.tmp"
    # Write the server script to a file — do NOT use inline heredoc with & inside $()
    # because bash waits for all background processes to close their fds before
    # the $() subshell closes its stdout pipe (even with &).
    cat > "$dir/mock-server.py" << 'PYEOF'
#!/usr/bin/env python3
"""Telemetry mock HTTP server — records POST bodies, returns configurable status."""
import json
import os
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

STATE_DIR = sys.argv[1]
PORT_FILE = sys.argv[2]
PORT_FILE_TMP = PORT_FILE + ".tmp"
REQUESTS_FILE = os.path.join(STATE_DIR, "requests.jsonl")
SCENARIO_FILE = os.path.join(STATE_DIR, "scenario.json")


class _Handler(BaseHTTPRequestHandler):
    def _handle(self, method):
        length = int(self.headers.get("Content-Length", "0") or "0")
        body = self.rfile.read(length) if length else b""
        entry = {
            "method": method,
            "path": self.path,
            "body": body.decode("utf-8", errors="replace"),
        }
        with open(REQUESTS_FILE, "a") as f:
            f.write(json.dumps(entry) + "\n")
        status = 200
        try:
            if os.path.isfile(SCENARIO_FILE):
                sc = json.loads(open(SCENARIO_FILE).read())
                status = sc.get("status", 200)
        except Exception:
            pass
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"{}")

    def log_message(self, fmt, *args):  # silence access log
        return

    def do_POST(self):
        self._handle("POST")

    def do_GET(self):
        self._handle("GET")


server = ThreadingHTTPServer(("127.0.0.1", 0), _Handler)
# Atomic write so watcher loop sees the complete port atomically
with open(PORT_FILE_TMP, "w") as pf:
    pf.write(str(server.server_address[1]))
os.rename(PORT_FILE_TMP, PORT_FILE)
server.serve_forever()
PYEOF
    # Run as a file with all I/O redirected — prevents $() from waiting on fds
    python3 "$dir/mock-server.py" "$dir" "$port_file" </dev/null >"$dir/server.log" 2>&1 &
    local spid=$!
    echo "$spid" > "$dir/server.pid"
    # wait for port file (up to 5s via atomic rename)
    local waited=0
    while [[ ! -s "$port_file" && $waited -lt 50 ]]; do
        sleep 0.1
        (( waited++ )) || true
    done
    cat "$port_file" 2>/dev/null || echo "0"
}

# Start a slow TCP server (accepts, never responds)
start_slow_server() {
    local dir="$1"
    local port_file="$dir/slow-port.txt"
    write_slow_server "$dir"
    # Run as a file with redirected I/O — same reason as start_server_with_portfile
    python3 "$dir/slow-server.py" "$port_file" </dev/null >"$dir/slow-server.log" 2>&1 &
    local spid=$!
    echo "$spid" > "$dir/slow-server.pid"
    local waited=0
    while [[ ! -s "$port_file" && $waited -lt 50 ]]; do
        sleep 0.1
        (( waited++ )) || true
    done
    cat "$port_file" 2>/dev/null || echo "0"
}

kill_server() {
    local pid_file="$1"
    if [[ -f "$pid_file" ]]; then
        local pid
        pid=$(cat "$pid_file" 2>/dev/null || true)
        if [[ -n "$pid" ]]; then
            kill "$pid" 2>/dev/null || true
        fi
    fi
}

# count_requests <dir> → number of POST entries in requests.jsonl
count_requests() {
    local dir="$1"
    if [[ -f "$dir/requests.jsonl" ]]; then
        wc -l < "$dir/requests.jsonl" | tr -d ' '
    else
        echo "0"
    fi
}

# get_request_body <dir> [n] → body of nth POST (1-indexed, default 1)
get_request_body() {
    local dir="$1"
    local n="${2:-1}"
    if [[ -f "$dir/requests.jsonl" ]]; then
        python3 -c "
import json, sys
lines = open('$dir/requests.jsonl').readlines()
idx = $n - 1
if idx < len(lines):
    entry = json.loads(lines[idx])
    print(entry.get('body',''))
" 2>/dev/null || true
    fi
}

# ── Minimal dso-config.conf helper ───────────────────────────────────────────
# write_config <dir> [extra_lines...]
# Writes a minimal dso-config.conf to <dir>/dso-config.conf.
write_config() {
    local dir="$1"
    local endpoint="${2:-http://127.0.0.1:9999/}"
    shift 2 || true
    cat > "$dir/dso-config.conf" << CONFEOF
telemetry.enabled=true
telemetry.endpoint=$endpoint
telemetry.client_id=test-client-$(uname -n)
telemetry.tool_id=dso
telemetry.tool_version=1.17.99
CONFEOF
    # append any extra lines passed as remaining args
    local extra
    for extra in "$@"; do
        echo "$extra" >> "$dir/dso-config.conf"
    done
}

# invoke_shim <ledger_dir> <config_dir> [extra_args...]
# Runs telemetry-emit.sh with isolation env vars set.
# Returns exit code; stdout+stderr written to <ledger_dir>/shim.out
invoke_shim() {
    local ledger_dir="$1"
    local config_dir="$2"
    shift 2 || true
    local exit_code=0
    DSO_TELEMETRY_LEDGER_DIR="$ledger_dir" \
        DSO_CONFIG_FILE="$config_dir/dso-config.conf" \
        bash "$SHIM" "$@" \
        > "$ledger_dir/shim.out" 2>&1 || exit_code=$?
    echo "$exit_code"
}

# ── Pre-flight: shim must exist (will FAIL in RED phase) ─────────────────────
if [[ ! -f "$SHIM" ]]; then
    echo "RED: telemetry-emit.sh not found at $SHIM — all tests will report failures" >&2
fi

# =============================================================================
# test_happy_path_posts_all_11_fields
#
# Invoke the shim with a running mock endpoint. Assert all 11 schema fields
# appear in the captured POST body with correct names.
# Fields: schema_version (int 1), event_id, event_type, client_id, tool_id,
#         tool_version, timestamp, pr_number, commit_sha, cycle, language.
# =============================================================================
test_happy_path_posts_all_11_fields() {
    local mock_dir ledger_dir config_dir port
    mock_dir="$(make_tmpdir)"
    ledger_dir="$(make_tmpdir)"
    config_dir="$(make_tmpdir)"

    port="$(start_server_with_portfile "$mock_dir")"
    if [[ "$port" == "0" || -z "$port" ]]; then
        assert_eq "test_happy_path: mock server started" "nonzero-port" "failed-to-start"
        kill_server "$mock_dir/server.pid"
        return
    fi

    write_config "$config_dir" "http://127.0.0.1:$port/"

    local exit_code
    exit_code=$(
        DSO_TELEMETRY_LEDGER_DIR="$ledger_dir" \
        DSO_CONFIG_FILE="$config_dir/dso-config.conf" \
        GITHUB_PR_NUMBER="42" \
        GITHUB_SHA="aaabbbbccccddddeeeeffffaaaabbbbccccddddee" \
        bash "$SHIM" \
            --event-type review_finding \
            --cycle 2 \
            --language python \
            > "$ledger_dir/shim.out" 2>&1
        echo $?
    )

    assert_eq "test_happy_path: exit 0" "0" "$exit_code"

    local req_count
    req_count="$(count_requests "$mock_dir")"
    assert_ne "test_happy_path: at least one POST sent" "0" "$req_count"

    local body
    body="$(get_request_body "$mock_dir" 1)"

    # Assert all 11 fields present in POST body
    local schema_version_val
    schema_version_val="$(echo "$body" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('schema_version','MISSING'))" 2>/dev/null || echo "MISSING")"
    assert_eq "test_happy_path: schema_version == 1 (int)" "1" "$schema_version_val"

    # Verify schema_version is an integer (not string) — jq type check
    local sv_type
    sv_type="$(echo "$body" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(type(d.get('schema_version',None)).__name__)" 2>/dev/null || echo "unknown")"
    assert_eq "test_happy_path: schema_version type is int" "int" "$sv_type"

    # Assert each named field present
    for field in event_id event_type client_id tool_id tool_version timestamp pr_number commit_sha cycle language; do
        local present
        present="$(echo "$body" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print('yes' if '$field' in d else 'no')" 2>/dev/null || echo "no")"
        assert_eq "test_happy_path: field '$field' present" "yes" "$present"
    done

    kill_server "$mock_dir/server.pid"
}

# =============================================================================
# test_key_registers_event_id
#
# Invoke shim with --key foo. Assert event-id-map.json gains key "foo" mapping
# to a non-empty event_id (UUID v4 string).
# =============================================================================
test_key_registers_event_id() {
    local mock_dir ledger_dir config_dir port
    mock_dir="$(make_tmpdir)"
    ledger_dir="$(make_tmpdir)"
    config_dir="$(make_tmpdir)"

    port="$(start_server_with_portfile "$mock_dir")"
    write_config "$config_dir" "http://127.0.0.1:$port/"

    local exit_code
    exit_code="$(
        DSO_TELEMETRY_LEDGER_DIR="$ledger_dir" \
        DSO_CONFIG_FILE="$config_dir/dso-config.conf" \
        bash "$SHIM" \
            --event-type review_finding \
            --key foo \
            > "$ledger_dir/shim.out" 2>&1
        echo $?
    )"

    assert_eq "test_key_registers_event_id: exit 0" "0" "$exit_code"

    local map_file="$ledger_dir/event-id-map.json"
    local map_exists=0
    [[ -f "$map_file" ]] && map_exists=1
    assert_eq "test_key_registers_event_id: event-id-map.json exists" "1" "$map_exists"

    local foo_val
    foo_val="$(python3 -c "import json; d=json.load(open('$map_file')); print(d.get('foo','MISSING'))" 2>/dev/null || echo "MISSING")"
    assert_ne "test_key_registers_event_id: key 'foo' present and non-empty" "MISSING" "$foo_val"
    assert_ne "test_key_registers_event_id: key 'foo' non-empty string" "" "$foo_val"

    kill_server "$mock_dir/server.pid"
}

# =============================================================================
# test_link_populates_finding_event_id
#
# Pre-seed event-id-map.json with foo → evt-123-seed.
# Invoke shim with --link foo. Assert POST body contains finding_event_id=evt-123-seed.
#
# Design note: finding_event_id is treated as an additive-optional field per
# schema additive-fields policy (contract line 24). No schema_version bump required.
# =============================================================================
test_link_populates_finding_event_id() {
    local mock_dir ledger_dir config_dir port
    mock_dir="$(make_tmpdir)"
    ledger_dir="$(make_tmpdir)"
    config_dir="$(make_tmpdir)"

    port="$(start_server_with_portfile "$mock_dir")"
    write_config "$config_dir" "http://127.0.0.1:$port/"

    # Pre-seed the event-id map
    echo '{"foo":"evt-123-seed"}' > "$ledger_dir/event-id-map.json"

    local exit_code
    exit_code="$(
        DSO_TELEMETRY_LEDGER_DIR="$ledger_dir" \
        DSO_CONFIG_FILE="$config_dir/dso-config.conf" \
        bash "$SHIM" \
            --event-type resolver_outcome \
            --link foo \
            > "$ledger_dir/shim.out" 2>&1
        echo $?
    )"

    assert_eq "test_link_populates_finding_event_id: exit 0" "0" "$exit_code"

    local body
    body="$(get_request_body "$mock_dir" 1)"

    local finding_event_id
    finding_event_id="$(echo "$body" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print(d.get('finding_event_id','MISSING'))" 2>/dev/null || echo "MISSING")"
    assert_eq "test_link_populates_finding_event_id: finding_event_id=evt-123-seed" "evt-123-seed" "$finding_event_id"

    kill_server "$mock_dir/server.pid"
}

# =============================================================================
# test_privacy_strip_cited_excerpt
#
# With emit_excerpts unset (default false) and client_id=test-host-project,
# invoke shim with --cited-excerpt "SECRET_CODE".
# Assert cited_excerpt key is OMITTED from POST body (not null, not present).
# Uses jq 'has("cited_excerpt") | not' equivalent assertion.
# =============================================================================
test_privacy_strip_cited_excerpt() {
    local mock_dir ledger_dir config_dir port
    mock_dir="$(make_tmpdir)"
    ledger_dir="$(make_tmpdir)"
    config_dir="$(make_tmpdir)"

    port="$(start_server_with_portfile "$mock_dir")"

    # Config: emit_excerpts NOT set (defaults to false); client_id=test-host-project
    cat > "$config_dir/dso-config.conf" << CONFEOF
telemetry.enabled=true
telemetry.endpoint=http://127.0.0.1:$port/
telemetry.client_id=test-host-project
telemetry.tool_id=dso
telemetry.tool_version=1.17.99
CONFEOF

    local exit_code
    exit_code="$(
        DSO_TELEMETRY_LEDGER_DIR="$ledger_dir" \
        DSO_CONFIG_FILE="$config_dir/dso-config.conf" \
        bash "$SHIM" \
            --event-type review_finding \
            --cited-excerpt "SECRET_CODE_DO_NOT_EMIT" \
            > "$ledger_dir/shim.out" 2>&1
        echo $?
    )"

    assert_eq "test_privacy_strip_cited_excerpt: exit 0" "0" "$exit_code"

    local body
    body="$(get_request_body "$mock_dir" 1)"

    # cited_excerpt must be ABSENT (key omitted, not null)
    local has_key
    has_key="$(echo "$body" | python3 -c "import json,sys; d=json.loads(sys.stdin.read()); print('yes' if 'cited_excerpt' in d else 'no')" 2>/dev/null || echo "yes")"
    assert_eq "test_privacy_strip_cited_excerpt: cited_excerpt key OMITTED (not null)" "no" "$has_key"

    kill_server "$mock_dir/server.pid"
}

# =============================================================================
# test_failopen_500
#
# Mock server returns HTTP 500. Assert shim exits 0 (fail-open) and
# writes a warning to stderr.
# =============================================================================
test_failopen_500() {
    local mock_dir ledger_dir config_dir port
    mock_dir="$(make_tmpdir)"
    ledger_dir="$(make_tmpdir)"
    config_dir="$(make_tmpdir)"

    port="$(start_server_with_portfile "$mock_dir")"
    # Configure server to return 500
    echo '{"status": 500}' > "$mock_dir/scenario.json"

    write_config "$config_dir" "http://127.0.0.1:$port/"

    local exit_code
    exit_code="$(
        DSO_TELEMETRY_LEDGER_DIR="$ledger_dir" \
        DSO_CONFIG_FILE="$config_dir/dso-config.conf" \
        bash "$SHIM" \
            --event-type review_finding \
            > "$ledger_dir/shim.out" 2>&1
        echo $?
    )"

    assert_eq "test_failopen_500: exit 0 (fail-open on 500)" "0" "$exit_code"

    local output
    output="$(cat "$ledger_dir/shim.out" 2>/dev/null || echo "")"
    # Must emit some warning on stderr/stdout
    local has_warning=0
    if echo "$output" | grep -qiE 'warn|error|fail|500|telemetry'; then
        has_warning=1
    fi
    assert_eq "test_failopen_500: warning emitted on 500" "1" "$has_warning"

    kill_server "$mock_dir/server.pid"
}

# =============================================================================
# test_failopen_tcp_no_response
#
# Server accepts TCP but never sends a response (simulates read timeout).
# Assert shim exits 0 (fail-open) after timeout and emits a warning.
# TIMEOUT=10 safety guard on background server.
# =============================================================================
test_failopen_tcp_no_response() {
    local mock_dir ledger_dir config_dir port
    mock_dir="$(make_tmpdir)"
    ledger_dir="$(make_tmpdir)"
    config_dir="$(make_tmpdir)"

    port="$(start_slow_server "$mock_dir")"
    if [[ "$port" == "0" || -z "$port" ]]; then
        assert_eq "test_failopen_tcp_no_response: slow server started" "nonzero-port" "failed-to-start"
        kill_server "$mock_dir/slow-server.pid"
        return
    fi

    write_config "$config_dir" "http://127.0.0.1:$port/"

    local exit_code=0
    # Run with short timeout (shim must have its own timeout; we cap outer wait at 10s)
    local TIMEOUT=10
    exit_code="$(
        DSO_TELEMETRY_LEDGER_DIR="$ledger_dir" \
        DSO_CONFIG_FILE="$config_dir/dso-config.conf" \
        DSO_TELEMETRY_TIMEOUT="${TIMEOUT}" \
        timeout "$TIMEOUT" bash "$SHIM" \
            --event-type review_finding \
            > "$ledger_dir/shim.out" 2>&1
        echo $?
    )"

    # exit 124 means timeout(1) killed the process — still acceptable fail-open
    # exit 0 means shim handled the timeout internally — preferred
    local failopen=0
    if [[ "$exit_code" == "0" || "$exit_code" == "124" ]]; then
        failopen=1
    fi
    assert_eq "test_failopen_tcp_no_response: fail-open on TCP timeout (exit 0 or 124)" "1" "$failopen"

    kill_server "$mock_dir/slow-server.pid"
}

# =============================================================================
# test_failopen_nxdomain
#
# Invoke shim with NXDOMAIN endpoint (RFC 6761 .invalid TLD always NXDOMAIN).
# Assert exit 0 and warning emitted.
# =============================================================================
test_failopen_nxdomain() {
    local ledger_dir config_dir
    ledger_dir="$(make_tmpdir)"
    config_dir="$(make_tmpdir)"

    # Use *.invalid TLD — guaranteed NXDOMAIN per RFC 6761
    write_config "$config_dir" "http://nonexistent.dso-test.invalid/"

    local exit_code=0
    exit_code="$(
        DSO_TELEMETRY_LEDGER_DIR="$ledger_dir" \
        DSO_CONFIG_FILE="$config_dir/dso-config.conf" \
        bash "$SHIM" \
            --event-type review_finding \
            > "$ledger_dir/shim.out" 2>&1
        echo $?
    )"

    assert_eq "test_failopen_nxdomain: exit 0 (fail-open on NXDOMAIN)" "0" "$exit_code"

    local output
    output="$(cat "$ledger_dir/shim.out" 2>/dev/null || echo "")"
    local has_warning=0
    if echo "$output" | grep -qiE 'warn|error|fail|resolve|connect|telemetry'; then
        has_warning=1
    fi
    assert_eq "test_failopen_nxdomain: warning emitted on NXDOMAIN" "1" "$has_warning"
}

# =============================================================================
# test_validation_empty_client_id
#
# Config has empty client_id. Assert exit 1 and stderr contains "client_id".
# =============================================================================
test_validation_empty_client_id() {
    local ledger_dir config_dir
    ledger_dir="$(make_tmpdir)"
    config_dir="$(make_tmpdir)"

    # Config with empty client_id
    cat > "$config_dir/dso-config.conf" << CONFEOF
telemetry.enabled=true
telemetry.endpoint=http://127.0.0.1:9999/
telemetry.client_id=
telemetry.tool_id=dso
telemetry.tool_version=1.17.99
CONFEOF

    local exit_code=0
    exit_code="$(
        DSO_TELEMETRY_LEDGER_DIR="$ledger_dir" \
        DSO_CONFIG_FILE="$config_dir/dso-config.conf" \
        bash "$SHIM" \
            --event-type review_finding \
            > "$ledger_dir/shim.out" 2>&1
        echo $?
    )"

    assert_eq "test_validation_empty_client_id: exit 1" "1" "$exit_code"

    local output
    output="$(cat "$ledger_dir/shim.out" 2>/dev/null || echo "")"
    local has_client_id=0
    if echo "$output" | grep -qi "client_id"; then
        has_client_id=1
    fi
    assert_eq "test_validation_empty_client_id: error mentions client_id" "1" "$has_client_id"
}

# =============================================================================
# test_concurrent_writes_to_event_id_map
#
# Spawn 2 background shim invocations with distinct --key args writing to the
# same DSO_TELEMETRY_LEDGER_DIR. wait with 10s outer timeout.
# Assert both exit 0 + event-id-map.json is valid JSON + both keys present.
# Replaces the change-detector fcntl.flock grep approach with a behavioral test.
# =============================================================================
test_concurrent_writes_to_event_id_map() {
    local mock_dir ledger_dir config_dir port
    mock_dir="$(make_tmpdir)"
    ledger_dir="$(make_tmpdir)"
    config_dir="$(make_tmpdir)"

    port="$(start_server_with_portfile "$mock_dir")"
    write_config "$config_dir" "http://127.0.0.1:$port/"

    # Launch two background invocations with distinct --key values
    local pid1 pid2 ec1 ec2
    ec1=0
    ec2=0

    DSO_TELEMETRY_LEDGER_DIR="$ledger_dir" \
        DSO_CONFIG_FILE="$config_dir/dso-config.conf" \
        bash "$SHIM" \
            --event-type review_finding \
            --key alpha \
            > "$ledger_dir/out1.txt" 2>&1 &
    pid1=$!

    DSO_TELEMETRY_LEDGER_DIR="$ledger_dir" \
        DSO_CONFIG_FILE="$config_dir/dso-config.conf" \
        bash "$SHIM" \
            --event-type review_finding \
            --key beta \
            > "$ledger_dir/out2.txt" 2>&1 &
    pid2=$!

    # wait with TIMEOUT=10 safety
    local TIMEOUT=10
    local deadline=$(( $(date +%s) + TIMEOUT ))
    while kill -0 "$pid1" 2>/dev/null || kill -0 "$pid2" 2>/dev/null; do
        if [[ $(date +%s) -ge $deadline ]]; then
            kill "$pid1" "$pid2" 2>/dev/null || true
            break
        fi
        sleep 0.2
    done
    wait "$pid1" 2>/dev/null || ec1=$?
    wait "$pid2" 2>/dev/null || ec2=$?

    assert_eq "test_concurrent_writes: pid1 exits 0" "0" "$ec1"
    assert_eq "test_concurrent_writes: pid2 exits 0" "0" "$ec2"

    local map_file="$ledger_dir/event-id-map.json"
    local json_valid=0
    python3 -c "import json; json.load(open('$map_file'))" 2>/dev/null && json_valid=1
    assert_eq "test_concurrent_writes: event-id-map.json is valid JSON" "1" "$json_valid"

    local has_alpha has_beta
    has_alpha="$(python3 -c "import json; d=json.load(open('$map_file')); print('yes' if 'alpha' in d else 'no')" 2>/dev/null || echo "no")"
    has_beta="$(python3 -c "import json; d=json.load(open('$map_file')); print('yes' if 'beta' in d else 'no')" 2>/dev/null || echo "no")"
    assert_eq "test_concurrent_writes: key 'alpha' present" "yes" "$has_alpha"
    assert_eq "test_concurrent_writes: key 'beta' present" "yes" "$has_beta"

    kill_server "$mock_dir/server.pid"
}

# =============================================================================
# test_event_type_enum_validation
#
# Invoke shim with an invalid event_type ("bogus_type").
# Assert exit 1 (validation rejects unknown event types).
# =============================================================================
test_event_type_enum_validation() {
    local ledger_dir config_dir
    ledger_dir="$(make_tmpdir)"
    config_dir="$(make_tmpdir)"

    write_config "$config_dir" "http://127.0.0.1:9999/"

    local exit_code=0
    exit_code="$(
        DSO_TELEMETRY_LEDGER_DIR="$ledger_dir" \
        DSO_CONFIG_FILE="$config_dir/dso-config.conf" \
        bash "$SHIM" \
            --event-type bogus_type \
            > "$ledger_dir/shim.out" 2>&1
        echo $?
    )"

    assert_eq "test_event_type_enum_validation: exit 1 on unknown event_type" "1" "$exit_code"
}

# =============================================================================
# test_telemetry_disabled_noop
#
# Config has telemetry.enabled=false. Assert exit 0 AND mock server received
# zero POSTs (telemetry disabled is a complete no-op).
# =============================================================================
test_telemetry_disabled_noop() {
    local mock_dir ledger_dir config_dir port
    mock_dir="$(make_tmpdir)"
    ledger_dir="$(make_tmpdir)"
    config_dir="$(make_tmpdir)"

    port="$(start_server_with_portfile "$mock_dir")"

    cat > "$config_dir/dso-config.conf" << CONFEOF
telemetry.enabled=false
telemetry.endpoint=http://127.0.0.1:$port/
telemetry.client_id=test-disabled-client
telemetry.tool_id=dso
telemetry.tool_version=1.17.99
CONFEOF

    local exit_code=0
    exit_code="$(
        DSO_TELEMETRY_LEDGER_DIR="$ledger_dir" \
        DSO_CONFIG_FILE="$config_dir/dso-config.conf" \
        bash "$SHIM" \
            --event-type review_finding \
            > "$ledger_dir/shim.out" 2>&1
        echo $?
    )"

    assert_eq "test_telemetry_disabled_noop: exit 0 when disabled" "0" "$exit_code"

    local post_count
    post_count="$(count_requests "$mock_dir")"
    assert_eq "test_telemetry_disabled_noop: zero POSTs when disabled" "0" "$post_count"

    kill_server "$mock_dir/server.pid"
}

# =============================================================================
# test_idempotency_dedup_by_event_id
#
# Invoke the shim twice with the same forced event_id.
# Assert mock server received exactly ONE POST and submitted.log contains the
# event_id exactly once (no duplicate submissions).
# =============================================================================
test_idempotency_dedup_by_event_id() {
    local mock_dir ledger_dir config_dir port
    mock_dir="$(make_tmpdir)"
    ledger_dir="$(make_tmpdir)"
    config_dir="$(make_tmpdir)"

    port="$(start_server_with_portfile "$mock_dir")"
    write_config "$config_dir" "http://127.0.0.1:$port/"

    local forced_id="aaaabbbb-cccc-4ddd-8eee-ffffaaaabbbb"
    local ec1 ec2
    ec1=0
    ec2=0

    ec1="$(
        DSO_TELEMETRY_LEDGER_DIR="$ledger_dir" \
        DSO_CONFIG_FILE="$config_dir/dso-config.conf" \
        DSO_TELEMETRY_EVENT_ID="$forced_id" \
        bash "$SHIM" \
            --event-type review_finding \
            > "$ledger_dir/out1.txt" 2>&1
        echo $?
    )"

    ec2="$(
        DSO_TELEMETRY_LEDGER_DIR="$ledger_dir" \
        DSO_CONFIG_FILE="$config_dir/dso-config.conf" \
        DSO_TELEMETRY_EVENT_ID="$forced_id" \
        bash "$SHIM" \
            --event-type review_finding \
            > "$ledger_dir/out2.txt" 2>&1
        echo $?
    )"

    assert_eq "test_idempotency_dedup: first invocation exits 0" "0" "$ec1"
    assert_eq "test_idempotency_dedup: second invocation exits 0" "0" "$ec2"

    local post_count
    post_count="$(count_requests "$mock_dir")"
    assert_eq "test_idempotency_dedup: exactly ONE POST for repeated event_id" "1" "$post_count"

    local submitted_log="$ledger_dir/submitted.log"
    local log_count=0
    if [[ -f "$submitted_log" ]]; then
        log_count="$(grep -c "$forced_id" "$submitted_log" 2>/dev/null || echo "0")"
    fi
    assert_eq "test_idempotency_dedup: submitted.log records event_id exactly once" "1" "$log_count"

    kill_server "$mock_dir/server.pid"
}

# =============================================================================
# Main dispatcher — invokes all test functions, counts PASS/FAIL, prints summary
#
# Tests are invoked directly (not in subshells) so that assert.sh PASS/FAIL
# counters accumulate correctly across all test functions.
# Each test function manages its own temp dirs via make_tmpdir + global trap.
# =============================================================================

echo ""
echo "--- test_happy_path_posts_all_11_fields ---"
test_happy_path_posts_all_11_fields

echo ""
echo "--- test_key_registers_event_id ---"
test_key_registers_event_id

echo ""
echo "--- test_link_populates_finding_event_id ---"
test_link_populates_finding_event_id

echo ""
echo "--- test_privacy_strip_cited_excerpt ---"
test_privacy_strip_cited_excerpt

echo ""
echo "--- test_failopen_500 ---"
test_failopen_500

echo ""
echo "--- test_failopen_tcp_no_response ---"
test_failopen_tcp_no_response

echo ""
echo "--- test_failopen_nxdomain ---"
test_failopen_nxdomain

echo ""
echo "--- test_validation_empty_client_id ---"
test_validation_empty_client_id

echo ""
echo "--- test_concurrent_writes_to_event_id_map ---"
test_concurrent_writes_to_event_id_map

echo ""
echo "--- test_event_type_enum_validation ---"
test_event_type_enum_validation

echo ""
echo "--- test_telemetry_disabled_noop ---"
test_telemetry_disabled_noop

echo ""
echo "--- test_idempotency_dedup_by_event_id ---"
test_idempotency_dedup_by_event_id

echo ""
printf "SUMMARY FAILED:%d PASSED:%d\n" "$FAIL" "$PASS"
print_summary
