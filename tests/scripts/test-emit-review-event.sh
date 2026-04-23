#!/usr/bin/env bash
# tests/scripts/test-emit-review-event.sh
# RED tests for plugins/dso/scripts/emit-review-event.sh (does NOT exist yet).
#
# Covers: valid JSONL output, unique filenames, graceful failure on missing
# tracker, invalid event type rejection, schema_version presence, and lock
# exhaustion behavior.
#
# Usage: bash tests/scripts/test-emit-review-event.sh

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
EMIT_SCRIPT="$REPO_ROOT/plugins/dso/scripts/emit-review-event.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-emit-review-event.sh ==="

# ── Helper: create a fresh temp git repo with ticket system initialized ──────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_test_repo "$tmp/repo"
    echo "$tmp/repo"
}

# ── Helper: build a minimal review_result event JSON payload ─────────────────
# Returns the JSON string on stdout.
_review_result_payload() {
    python3 -c "
import json, sys
data = {
    'schema_version': 1,
    'event_type': 'review_result',
    'timestamp': '2026-04-05T14:31:00Z',
    'session_id': 'sess-test-001',
    'epic_id': 'cb8a-6a7c',
    'tier': 'standard',
    'reviewer_agent': 'dso:code-reviewer-standard',
    'finding_count': 2,
    'critical_count': 0,
    'important_count': 1,
    'suggestion_count': 1,
    'dimensions_scored': ['correctness', 'verification', 'hygiene', 'design', 'maintainability'],
    'pass': True,
    'resolution_attempts': 1,
    'diff_hash': 'a1b2c3d4'
}
json.dump(data, sys.stdout)
"
}

# ── Test 1: emit writes valid JSONL ──────────────────────────────────────────
echo "Test 1: emit-review-event.sh writes valid JSONL (parseable by python3 json.loads)"
test_emit_writes_valid_jsonl() {
    # emit-review-event.sh must exist — RED: it does not exist yet
    if [ ! -f "$EMIT_SCRIPT" ]; then
        assert_eq "emit-review-event.sh exists" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Initialize ticket system so .tickets-tracker exists
    (cd "$repo" && bash "$REPO_ROOT/.claude/scripts/dso" ticket init 2>/dev/null) || true

    # Create .review-events directory
    mkdir -p "$repo/.tickets-tracker/.review-events"

    local payload
    payload=$(_review_result_payload)

    # Call emit-review-event.sh with the payload
    local exit_code=0
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmpdir"
    (cd "$repo" && bash "$EMIT_SCRIPT" "$payload") || exit_code=$?

    assert_eq "emit exits zero" "0" "$exit_code"

    # Find the written event file and parse it
    local event_file
    event_file=$(find "$repo/.tickets-tracker/.review-events" -name '*.jsonl' -o -name '*.json' 2>/dev/null | head -1)

    if [ -z "$event_file" ]; then
        assert_eq "event file written" "found" "not-found"
        return
    fi

    # Parse with python3 json.loads — must succeed
    local parse_exit=0
    python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            json.loads(line)
print('valid')
" "$event_file" 2>/dev/null || parse_exit=$?

    assert_eq "written event is valid JSON" "0" "$parse_exit"
}
test_emit_writes_valid_jsonl

# ── Test 2: emit produces unique filenames ───────────────────────────────────
echo "Test 2: emit-review-event.sh produces unique filenames on successive calls"
test_emit_unique_filenames() {
    # emit-review-event.sh must exist — RED: it does not exist yet
    if [ ! -f "$EMIT_SCRIPT" ]; then
        assert_eq "emit-review-event.sh exists for unique filename test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Initialize ticket system
    (cd "$repo" && bash "$REPO_ROOT/.claude/scripts/dso" ticket init 2>/dev/null) || true
    mkdir -p "$repo/.tickets-tracker/.review-events"

    local payload
    payload=$(_review_result_payload)

    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmpdir"

    # Call twice
    (cd "$repo" && bash "$EMIT_SCRIPT" "$payload") 2>/dev/null || true
    (cd "$repo" && bash "$EMIT_SCRIPT" "$payload") 2>/dev/null || true

    # Count unique filenames in .review-events
    local file_count
    file_count=$(find "$repo/.tickets-tracker/.review-events" -type f 2>/dev/null | wc -l | tr -d ' ')

    assert_eq "two calls produce two files" "2" "$file_count"

    # Verify filenames are actually different
    if [ "$file_count" -ge 2 ]; then
        local files
        files=$(find "$repo/.tickets-tracker/.review-events" -type f 2>/dev/null | sort)
        local first second
        first=$(echo "$files" | head -1)
        second=$(echo "$files" | tail -1)
        assert_ne "filenames differ" "$first" "$second"
    fi
}
test_emit_unique_filenames

# ── Test 3: graceful failure when .tickets-tracker missing ───────────────────
echo "Test 3: emit-review-event.sh fails gracefully when .tickets-tracker does not exist"
test_emit_graceful_failure_missing_tracker() {
    # emit-review-event.sh must exist — RED: it does not exist yet
    if [ ! -f "$EMIT_SCRIPT" ]; then
        assert_eq "emit-review-event.sh exists for missing-tracker test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Do NOT run ticket init — .tickets-tracker should not exist

    local payload
    payload=$(_review_result_payload)

    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmpdir"

    # Call emit-review-event.sh — must exit non-zero
    local exit_code=0
    local stderr_out
    stderr_out=$(cd "$repo" && bash "$EMIT_SCRIPT" "$payload" 2>&1) || exit_code=$?

    assert_eq "exits non-zero without .tickets-tracker" "1" "$([ "$exit_code" -ne 0 ] && echo 1 || echo 0)"

    # Assert: stderr contains an error message (not silent failure)
    if [ -n "$stderr_out" ]; then
        assert_eq "error message printed on missing tracker" "has-message" "has-message"
    else
        assert_eq "error message printed on missing tracker" "has-message" "silent"
    fi
}
test_emit_graceful_failure_missing_tracker

# ── Test 4: rejects invalid event type ───────────────────────────────────────
echo "Test 4: emit-review-event.sh rejects invalid event_type"
test_emit_rejects_invalid_type() {
    # emit-review-event.sh must exist — RED: it does not exist yet
    if [ ! -f "$EMIT_SCRIPT" ]; then
        assert_eq "emit-review-event.sh exists for invalid-type test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Initialize ticket system
    (cd "$repo" && bash "$REPO_ROOT/.claude/scripts/dso" ticket init 2>/dev/null) || true
    mkdir -p "$repo/.tickets-tracker/.review-events"

    # Build a payload with invalid event_type
    local bad_payload
    bad_payload=$(python3 -c "
import json, sys
data = {
    'schema_version': 1,
    'event_type': 'bad_type',
    'timestamp': '2026-04-05T14:31:00Z',
    'session_id': 'sess-test-bad',
    'epic_id': 'cb8a-6a7c'
}
json.dump(data, sys.stdout)
")

    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmpdir"

    # Call emit-review-event.sh with bad event_type — must exit non-zero
    local exit_code=0
    (cd "$repo" && bash "$EMIT_SCRIPT" "$bad_payload" 2>/dev/null) || exit_code=$?

    assert_eq "rejects invalid event_type with non-zero exit" "1" "$([ "$exit_code" -ne 0 ] && echo 1 || echo 0)"
}
test_emit_rejects_invalid_type

# ── Test 5: schema_version field present ─────────────────────────────────────
echo "Test 5: emit-review-event.sh writes events with schema_version=1"
test_emit_schema_version_present() {
    # emit-review-event.sh must exist — RED: it does not exist yet
    if [ ! -f "$EMIT_SCRIPT" ]; then
        assert_eq "emit-review-event.sh exists for schema-version test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Initialize ticket system
    (cd "$repo" && bash "$REPO_ROOT/.claude/scripts/dso" ticket init 2>/dev/null) || true
    mkdir -p "$repo/.tickets-tracker/.review-events"

    local payload
    payload=$(_review_result_payload)

    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmpdir"

    (cd "$repo" && bash "$EMIT_SCRIPT" "$payload") 2>/dev/null || true

    # Find the written event file
    local event_file
    event_file=$(find "$repo/.tickets-tracker/.review-events" -type f 2>/dev/null | head -1)

    if [ -z "$event_file" ]; then
        assert_eq "event file written for schema_version check" "found" "not-found"
        return
    fi

    # Parse and check schema_version=1
    local schema_version
    schema_version=$(python3 -c "
import json, sys
with open(sys.argv[1]) as f:
    for line in f:
        line = line.strip()
        if line:
            data = json.loads(line)
            print(data.get('schema_version', 'missing'))
            break
" "$event_file" 2>/dev/null || echo "parse-error")

    assert_eq "schema_version is 1" "1" "$schema_version"
}
test_emit_schema_version_present

# ── Test 6: graceful failure on lock exhaustion ──────────────────────────────
echo "Test 6: emit-review-event.sh fails gracefully when lock is held externally"
test_emit_graceful_failure_lock_exhaustion() {
    # emit-review-event.sh must exist — RED: it does not exist yet
    if [ ! -f "$EMIT_SCRIPT" ]; then
        assert_eq "emit-review-event.sh exists for lock-exhaustion test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Initialize ticket system
    (cd "$repo" && bash "$REPO_ROOT/.claude/scripts/dso" ticket init 2>/dev/null) || true
    mkdir -p "$repo/.tickets-tracker/.review-events"

    local payload
    payload=$(_review_result_payload)

    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmpdir"

    local lock_file="$repo/.tickets-tracker/.ticket-write.lock"

    # Hold the lock externally using Python fcntl.flock (portable — macOS + Linux)
    python3 -c "
import fcntl, os, time, sys
fd = os.open(sys.argv[1], os.O_CREAT | os.O_RDWR)
fcntl.flock(fd, fcntl.LOCK_EX)
time.sleep(10)
os.close(fd)
" "$lock_file" &
    local lock_pid=$!

    # Small delay to ensure lock is acquired
    sleep 0.2

    # Call emit-review-event.sh with a short lock timeout — must exit non-zero (no hang)
    local exit_code=0
    local stderr_out
    stderr_out=$(cd "$repo" && \
        REVIEW_EVENT_LOCK_TIMEOUT=1 \
        bash "$EMIT_SCRIPT" "$payload" 2>&1) || exit_code=$?

    # Kill the lock holder
    kill "$lock_pid" 2>/dev/null || true
    wait "$lock_pid" 2>/dev/null || true

    assert_eq "exits non-zero on lock exhaustion" "1" "$([ "$exit_code" -ne 0 ] && echo 1 || echo 0)"

    # Assert: stderr contains an error message (not silent, not a crash)
    if [ -n "$stderr_out" ]; then
        assert_eq "error message on lock exhaustion" "has-message" "has-message"
    else
        assert_eq "error message on lock exhaustion" "has-message" "silent"
    fi
}
test_emit_graceful_failure_lock_exhaustion

# ── Test 7: write_commit_event and emit-review-event.sh coexist in same tracker ──
echo "Test 7: write_commit_event and emit-review-event.sh produce valid JSON in the same tracker dir"
test_emit_review_event_write_commit_event_path() {
    # emit-review-event.sh must exist
    if [ ! -f "$EMIT_SCRIPT" ]; then
        assert_eq "emit-review-event.sh exists for coexistence test" "exists" "missing"
        return
    fi

    # Use clone_ticket_repo so .tickets-tracker is fully initialized
    local ticket_repo
    ticket_repo=$(mktemp -d)
    _CLEANUP_DIRS+=("$ticket_repo")
    clone_ticket_repo "$ticket_repo/repo"
    ticket_repo="$ticket_repo/repo"

    # Create .review-events directory (used by emit-review-event.sh)
    mkdir -p "$ticket_repo/.tickets-tracker/.review-events"

    # ── Step 1: create a ticket event via write_commit_event (bash-native) ──────
    local ticket_id="wce-coexist-01"
    mkdir -p "$ticket_repo/.tickets-tracker/$ticket_id"

    local event_json
    event_json=$(mktemp)
    _CLEANUP_DIRS+=("$event_json")
    python3 - "$event_json" "$ticket_id" <<'PYEOF'
import json, sys, uuid, datetime
out_path = sys.argv[1]
ticket_id = sys.argv[2]
event = {
    "event_type": "CREATE",
    "timestamp": datetime.datetime.utcnow().strftime("%Y%m%dT%H%M%S%f") + "Z",
    "uuid": str(uuid.uuid4()).replace("-", "")[:12],
    "data": {
        "ticket_id": ticket_id,
        "title": "coexistence integration test",
        "type": "task",
        "priority": 4,
        "status": "open",
        "tags": [],
    },
}
with open(out_path, "w", encoding="utf-8") as f:
    json.dump(event, f, ensure_ascii=False)
PYEOF

    local wce_exit=0
    (
        cd "$ticket_repo"
        _TICKET_TEST_NO_SYNC=1 \
        TICKETS_TRACKER_DIR="$ticket_repo/.tickets-tracker" \
        bash -c "
            source '$REPO_ROOT/plugins/dso/scripts/ticket-lib.sh'
            write_commit_event '$ticket_id' '$event_json'
        " 2>/dev/null
    ) || wce_exit=$?

    assert_eq "write_commit_event exits zero" "0" "$wce_exit"

    # Verify write_commit_event produced a JSON file in the ticket dir
    local wce_file_count
    wce_file_count=$(find "$ticket_repo/.tickets-tracker/$ticket_id" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "write_commit_event produces one event file" "1" "$wce_file_count"

    # ── Step 2: call emit-review-event.sh in the same tracker dir ───────────────
    local payload
    payload=$(_review_result_payload)

    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$tmpdir"

    local emit_exit=0
    (cd "$ticket_repo" && bash "$EMIT_SCRIPT" "$payload") 2>/dev/null || emit_exit=$?

    assert_eq "emit-review-event.sh exits zero" "0" "$emit_exit"

    # Verify emit-review-event produced a JSON file in .review-events
    local emit_file_count
    emit_file_count=$(find "$ticket_repo/.tickets-tracker/.review-events" -type f 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "emit-review-event.sh produces one review-events file" "1" "$emit_file_count"

    # ── Step 3: both output files are valid JSON ─────────────────────────────────
    local wce_file emit_file
    wce_file=$(find "$ticket_repo/.tickets-tracker/$ticket_id" -name '*.json' -type f 2>/dev/null | head -1)
    emit_file=$(find "$ticket_repo/.tickets-tracker/.review-events" -type f 2>/dev/null | head -1)

    if [ -n "$wce_file" ]; then
        local wce_parse_exit=0
        python3 -c "import json; json.load(open('$wce_file'))" 2>/dev/null || wce_parse_exit=$?
        assert_eq "write_commit_event output is valid JSON" "0" "$wce_parse_exit"
    fi

    if [ -n "$emit_file" ]; then
        local emit_parse_exit=0
        python3 -c "
import json
with open('$emit_file') as f:
    for line in f:
        line = line.strip()
        if line:
            json.loads(line)
" 2>/dev/null || emit_parse_exit=$?
        assert_eq "emit-review-event output is valid JSON" "0" "$emit_parse_exit"
    fi
}
test_emit_review_event_write_commit_event_path

print_summary
