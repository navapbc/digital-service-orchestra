#!/usr/bin/env bash
# tests/scripts/test-preconditions-ack.sh
# Behavioral tests for preconditions-ack.sh — CLI subcommand that writes an
# ACK event JSON acknowledging a degradation decision from a PRECONDITIONS event.
#
# Tests:
#  1. test_ack_creates_ack_json_file               — valid args → exactly one *-ACK.json file written
#  2. test_ack_file_format_s1_frozen               — ACK file has all 5 S1-frozen fields with correct types
#  3. test_ack_decision_ids_contains_input_id      — decision_ids array contains exactly ["sess:abc123"]
#  4. test_ack_rejects_invalid_rationale           — rationale "bad" → exit 1; no ACK file written
#  5. test_ack_timestamp_is_iso8601                — timestamp matches YYYY-MM-DDTHH:MM:SSZ pattern
#  6. test_ack_sampled_set_is_null_for_single_decision — sampled_set is JSON null
#
# Usage: bash tests/scripts/test-preconditions-ack.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/preconditions-ack.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-preconditions-ack.sh ==="

STORY_ID="test-story-0001"
DECISION_ID="sess:abc123"
VALID_RATIONALE="checked that implementation plan must be complete before sprint executes this story"
PRECONDITIONS_FILENAME="1700000000000000000-aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee-PRECONDITIONS.json"
PRECONDITIONS_CONTENT='{"event_type":"PRECONDITIONS","schema_version":2,"manifest_depth":"standard","gate_name":"story_gate","session_id":"sess-test","worktree_id":"test-branch","tier":"standard","timestamp":1700000000000,"gate_verdicts":[],"evidence_ref":{},"affects_fields":[],"data":{"degradation":true,"decision_ids":["sess:abc123"],"condition_text":"implementation plan must be complete before sprint executes"}}'

# Helper: create a fresh tmpdir with PRECONDITIONS fixture, export DSO_TICKETS_TRACKER_DIR
_setup_tmpdir() {
    local tmpdir
    tmpdir=$(mktemp -d)
    mkdir -p "$tmpdir/$STORY_ID"
    printf '%s' "$PRECONDITIONS_CONTENT" > "$tmpdir/$STORY_ID/$PRECONDITIONS_FILENAME"
    echo "$tmpdir"
}

# ── test_ack_creates_ack_json_file ────────────────────────────────────────────
# Call preconditions-ack with valid args → exactly one *-ACK.json file must
# exist in the story directory afterward.
test_ack_creates_ack_json_file() {
    _snapshot_fail
    local tmpdir
    tmpdir=$(_setup_tmpdir)

    local _exit=0
    DSO_TICKETS_TRACKER_DIR="$tmpdir" bash "$SCRIPT" "$STORY_ID" "$DECISION_ID" \
        --if-skipped "$VALID_RATIONALE" 2>/dev/null || _exit=$?

    local ack_count
    ack_count=$(find "$tmpdir/$STORY_ID" -name '*-ACK.json' | wc -l | tr -d ' ')

    assert_eq "test_ack_creates_ack_json_file: exit 0" "0" "$_exit"
    assert_eq "test_ack_creates_ack_json_file: exactly one ACK file" "1" "$ack_count"
    assert_pass_if_clean "test_ack_creates_ack_json_file"
    rm -rf "$tmpdir"
}

# ── test_ack_file_format_s1_frozen ────────────────────────────────────────────
# Parse the ACK file; verify all 5 S1-frozen fields are present with correct types:
#   schema_version (int == 1), decision_ids (array), if_skipped (string),
#   timestamp (string), sampled_set (null).
test_ack_file_format_s1_frozen() {
    _snapshot_fail
    local tmpdir
    tmpdir=$(_setup_tmpdir)

    local _exit=0
    DSO_TICKETS_TRACKER_DIR="$tmpdir" bash "$SCRIPT" "$STORY_ID" "$DECISION_ID" \
        --if-skipped "$VALID_RATIONALE" 2>/dev/null || _exit=$?
    assert_eq "test_ack_file_format_s1_frozen: script exits 0" "0" "$_exit"

    local ack_file
    ack_file=$(find "$tmpdir/$STORY_ID" -name '*-ACK.json' | head -1)

    python3 - "$ack_file" <<'PYEOF'
import sys, json
path = sys.argv[1]
try:
    d = json.load(open(path))
except Exception as e:
    print(f"FAIL: could not parse ACK JSON: {e}", file=sys.stderr)
    sys.exit(1)
errors = []
if d.get("schema_version") != 1:
    errors.append(f"schema_version must be 1, got {d.get('schema_version')!r}")
if not isinstance(d.get("decision_ids"), list):
    errors.append(f"decision_ids must be array, got {type(d.get('decision_ids'))}")
if not isinstance(d.get("if_skipped"), str):
    errors.append(f"if_skipped must be string, got {type(d.get('if_skipped'))}")
if not isinstance(d.get("timestamp"), str):
    errors.append(f"timestamp must be string, got {type(d.get('timestamp'))}")
if "sampled_set" not in d:
    errors.append("sampled_set field missing")
elif d["sampled_set"] is not None:
    errors.append(f"sampled_set must be null, got {d['sampled_set']!r}")
if errors:
    for e in errors:
        print(f"FAIL: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
    local py_exit=$?
    assert_eq "test_ack_file_format_s1_frozen: all S1 fields valid" "0" "$py_exit"
    assert_pass_if_clean "test_ack_file_format_s1_frozen"
    rm -rf "$tmpdir"
}

# ── test_ack_decision_ids_contains_input_id ───────────────────────────────────
# Parse the ACK file; verify decision_ids array is exactly ["sess:abc123"].
test_ack_decision_ids_contains_input_id() {
    _snapshot_fail
    local tmpdir
    tmpdir=$(_setup_tmpdir)

    local _exit=0
    DSO_TICKETS_TRACKER_DIR="$tmpdir" bash "$SCRIPT" "$STORY_ID" "$DECISION_ID" \
        --if-skipped "$VALID_RATIONALE" 2>/dev/null || _exit=$?
    assert_eq "test_ack_decision_ids_contains_input_id: script exits 0" "0" "$_exit"

    local ack_file
    ack_file=$(find "$tmpdir/$STORY_ID" -name '*-ACK.json' | head -1)

    python3 - "$ack_file" "$DECISION_ID" <<'PYEOF'
import sys, json
path, expected_id = sys.argv[1], sys.argv[2]
d = json.load(open(path))
ids = d.get("decision_ids", [])
if ids != [expected_id]:
    print(f"FAIL: expected decision_ids==[{expected_id!r}], got {ids!r}", file=sys.stderr)
    sys.exit(1)
PYEOF
    local py_exit=$?
    assert_eq "test_ack_decision_ids_contains_input_id: decision_ids == [sess:abc123]" "0" "$py_exit"
    assert_pass_if_clean "test_ack_decision_ids_contains_input_id"
    rm -rf "$tmpdir"
}

# ── test_ack_rejects_invalid_rationale ───────────────────────────────────────
# Calling with a rationale that fails 3-word-window validation ("bad") must
# exit 1 and must NOT write any ACK file.
test_ack_rejects_invalid_rationale() {
    _snapshot_fail
    local tmpdir
    tmpdir=$(_setup_tmpdir)

    local _exit=0
    DSO_TICKETS_TRACKER_DIR="$tmpdir" bash "$SCRIPT" "$STORY_ID" "$DECISION_ID" \
        --if-skipped "bad" 2>/dev/null || _exit=$?

    local ack_count
    ack_count=$(find "$tmpdir/$STORY_ID" -name '*-ACK.json' | wc -l | tr -d ' ')

    assert_eq "test_ack_rejects_invalid_rationale: exit 1" "1" "$_exit"
    assert_eq "test_ack_rejects_invalid_rationale: no ACK file written" "0" "$ack_count"
    assert_pass_if_clean "test_ack_rejects_invalid_rationale"
    rm -rf "$tmpdir"
}

# ── test_ack_timestamp_is_iso8601 ─────────────────────────────────────────────
# Parse the ACK file; verify the timestamp field matches YYYY-MM-DDTHH:MM:SSZ.
test_ack_timestamp_is_iso8601() {
    _snapshot_fail
    local tmpdir
    tmpdir=$(_setup_tmpdir)

    local _exit=0
    DSO_TICKETS_TRACKER_DIR="$tmpdir" bash "$SCRIPT" "$STORY_ID" "$DECISION_ID" \
        --if-skipped "$VALID_RATIONALE" 2>/dev/null || _exit=$?
    assert_eq "test_ack_timestamp_is_iso8601: script exits 0" "0" "$_exit"

    local ack_file
    ack_file=$(find "$tmpdir/$STORY_ID" -name '*-ACK.json' | head -1)

    python3 - "$ack_file" <<'PYEOF'
import sys, json, re
path = sys.argv[1]
d = json.load(open(path))
ts = d.get("timestamp", "")
pattern = r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$'
if not re.match(pattern, ts):
    print(f"FAIL: timestamp {ts!r} does not match YYYY-MM-DDTHH:MM:SSZ", file=sys.stderr)
    sys.exit(1)
PYEOF
    local py_exit=$?
    assert_eq "test_ack_timestamp_is_iso8601: timestamp format valid" "0" "$py_exit"
    assert_pass_if_clean "test_ack_timestamp_is_iso8601"
    rm -rf "$tmpdir"
}

# ── test_ack_sampled_set_is_null_for_single_decision ─────────────────────────
# When a single decision_id is given, sampled_set in the ACK file must be JSON null.
test_ack_sampled_set_is_null_for_single_decision() {
    _snapshot_fail
    local tmpdir
    tmpdir=$(_setup_tmpdir)

    local _exit=0
    DSO_TICKETS_TRACKER_DIR="$tmpdir" bash "$SCRIPT" "$STORY_ID" "$DECISION_ID" \
        --if-skipped "$VALID_RATIONALE" 2>/dev/null || _exit=$?
    assert_eq "test_ack_sampled_set_is_null_for_single_decision: script exits 0" "0" "$_exit"

    local ack_file
    ack_file=$(find "$tmpdir/$STORY_ID" -name '*-ACK.json' | head -1)

    python3 - "$ack_file" <<'PYEOF'
import sys, json
path = sys.argv[1]
d = json.load(open(path))
if "sampled_set" not in d:
    print("FAIL: sampled_set field missing", file=sys.stderr)
    sys.exit(1)
if d["sampled_set"] is not None:
    print(f"FAIL: sampled_set must be null for single decision, got {d['sampled_set']!r}", file=sys.stderr)
    sys.exit(1)
PYEOF
    local py_exit=$?
    assert_eq "test_ack_sampled_set_is_null_for_single_decision: sampled_set is null" "0" "$py_exit"
    assert_pass_if_clean "test_ack_sampled_set_is_null_for_single_decision"
    rm -rf "$tmpdir"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_ack_creates_ack_json_file
test_ack_file_format_s1_frozen
test_ack_decision_ids_contains_input_id
test_ack_rejects_invalid_rationale
test_ack_timestamp_is_iso8601
test_ack_sampled_set_is_null_for_single_decision

print_summary
