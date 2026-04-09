#!/usr/bin/env bash
# tests/scripts/test-suggestion-record.sh
# RED tests for plugins/dso/scripts/suggestion-record.sh (does NOT exist yet).
#
# Covers:
#   1. Calling with --observation creates a JSON file in .tickets-tracker/.suggestions/
#   2. Written file has required fields: timestamp, session_id, source
#   3. Observation field is present in file when --observation is given
#   4. Recommendation field is present when --recommendation is given
#   5. File naming convention: <timestamp>-<session-id>-<uuid>.json
#   6. Two concurrent calls produce two distinct files (unique filenames)
#   7. Graceful failure when .tickets-tracker/ does not exist (warn, exit non-zero)
#   8. ticket list does not include suggestion records
#
# Usage: bash tests/scripts/test-suggestion-record.sh

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SUGGESTION_SCRIPT="$REPO_ROOT/plugins/dso/scripts/suggestion-record.sh"
TICKET_INIT="$REPO_ROOT/plugins/dso/scripts/ticket-init.sh"
TICKET_LIST="$REPO_ROOT/plugins/dso/scripts/ticket-list.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-suggestion-record.sh ==="

# ── Helper: create a fresh temp git repo ─────────────────────────────────────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_test_repo "$tmp/repo"
    echo "$tmp/repo"
}

# ── Helper: initialize ticket system in a test repo ──────────────────────────
_init_tickets() {
    local repo="$1"
    (cd "$repo" && bash "$REPO_ROOT/plugins/dso/scripts/ticket-init.sh" 2>/dev/null) || true
}

# ── Test 1: creates a JSON file in .tickets-tracker/.suggestions/ ────────────
echo "Test 1: suggestion-record.sh creates a JSON file in .tickets-tracker/.suggestions/"
test_creates_json_file() {
    if [ ! -f "$SUGGESTION_SCRIPT" ]; then
        assert_eq "suggestion-record.sh exists" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _init_tickets "$repo"

    local exit_code=0
    (cd "$repo" && bash "$SUGGESTION_SCRIPT" \
        --observation "test observation" \
        --source "test") || exit_code=$?

    assert_eq "exits zero" "0" "$exit_code"

    local file_count
    file_count=$(find "$repo/.tickets-tracker/.suggestions" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "one JSON file written to .suggestions/" "1" "$file_count"
}
test_creates_json_file

# ── Test 2: file has required fields: timestamp, session_id, source ───────────
echo "Test 2: suggestion-record.sh writes JSON with required fields (timestamp, session_id, source)"
test_required_fields() {
    if [ ! -f "$SUGGESTION_SCRIPT" ]; then
        assert_eq "suggestion-record.sh exists for required-fields test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _init_tickets "$repo"

    (cd "$repo" && bash "$SUGGESTION_SCRIPT" \
        --observation "check required fields" \
        --source "unit-test") 2>/dev/null || true

    local event_file
    event_file=$(find "$repo/.tickets-tracker/.suggestions" -name '*.json' -type f 2>/dev/null | head -1)

    if [ -z "$event_file" ]; then
        assert_eq "event file written" "found" "not-found"
        return
    fi

    # Check all required fields are present and non-null/non-empty
    local check_result
    check_result=$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
missing = []
for field in ('timestamp', 'session_id', 'source'):
    if not data.get(field):
        missing.append(field)
if missing:
    print('missing:' + ','.join(missing))
else:
    print('ok')
" "$event_file" 2>/dev/null || echo "parse-error")

    assert_eq "required fields present" "ok" "$check_result"
}
test_required_fields

# ── Test 3: observation field is present when --observation is given ──────────
echo "Test 3: suggestion-record.sh writes observation field when --observation given"
test_observation_field() {
    if [ ! -f "$SUGGESTION_SCRIPT" ]; then
        assert_eq "suggestion-record.sh exists for observation-field test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _init_tickets "$repo"

    local obs_text="wall clock time was 45s"
    (cd "$repo" && bash "$SUGGESTION_SCRIPT" \
        --observation "$obs_text" \
        --source "unit-test") 2>/dev/null || true

    local event_file
    event_file=$(find "$repo/.tickets-tracker/.suggestions" -name '*.json' -type f 2>/dev/null | head -1)

    if [ -z "$event_file" ]; then
        assert_eq "event file written for observation test" "found" "not-found"
        return
    fi

    local obs_actual
    obs_actual=$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
print(data.get('observation', ''))
" "$event_file" 2>/dev/null || echo "")

    assert_eq "observation field contains input text" "$obs_text" "$obs_actual"
}
test_observation_field

# ── Test 4: recommendation field is present when --recommendation is given ────
echo "Test 4: suggestion-record.sh writes recommendation field when --recommendation given"
test_recommendation_field() {
    if [ ! -f "$SUGGESTION_SCRIPT" ]; then
        assert_eq "suggestion-record.sh exists for recommendation-field test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _init_tickets "$repo"

    local rec_text="reduce token budget per step"
    (cd "$repo" && bash "$SUGGESTION_SCRIPT" \
        --observation "step took too long" \
        --recommendation "$rec_text" \
        --source "unit-test") 2>/dev/null || true

    local event_file
    event_file=$(find "$repo/.tickets-tracker/.suggestions" -name '*.json' -type f 2>/dev/null | head -1)

    if [ -z "$event_file" ]; then
        assert_eq "event file written for recommendation test" "found" "not-found"
        return
    fi

    local rec_actual
    rec_actual=$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
print(data.get('recommendation', ''))
" "$event_file" 2>/dev/null || echo "")

    assert_eq "recommendation field contains input text" "$rec_text" "$rec_actual"
}
test_recommendation_field

# ── Test 5: file naming follows <timestamp>-<session-id>-<uuid>.json ──────────
echo "Test 5: suggestion-record.sh uses <timestamp>-<session-id>-<uuid>.json filename"
test_file_naming_convention() {
    if [ ! -f "$SUGGESTION_SCRIPT" ]; then
        assert_eq "suggestion-record.sh exists for naming test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _init_tickets "$repo"

    (cd "$repo" && bash "$SUGGESTION_SCRIPT" \
        --observation "naming convention check" \
        --source "unit-test") 2>/dev/null || true

    local event_file
    event_file=$(find "$repo/.tickets-tracker/.suggestions" -name '*.json' -type f 2>/dev/null | head -1)

    if [ -z "$event_file" ]; then
        assert_eq "event file written for naming test" "found" "not-found"
        return
    fi

    local basename
    basename=$(basename "$event_file" .json)

    # Filename must have at least 3 dash-delimited segments: timestamp, session-id parts, uuid
    # Pattern: at least 3 segments separated by '-'
    local segment_count
    segment_count=$(echo "$basename" | tr '-' '\n' | wc -l | tr -d ' ')

    # Must have timestamp (13-digit Unix ms) as first segment
    local first_segment
    first_segment=$(echo "$basename" | cut -d'-' -f1)
    local is_numeric
    is_numeric=$(echo "$first_segment" | grep -E '^[0-9]+$' | wc -l | tr -d ' ')

    assert_eq "filename starts with numeric timestamp" "1" "$is_numeric"
    assert_eq "filename has at least 3 segments" "1" "$([ "$segment_count" -ge 3 ] && echo 1 || echo 0)"
    assert_eq "filename ends in .json" "1" "$(echo "$event_file" | grep -c '\.json$' | tr -d ' ')"
}
test_file_naming_convention

# ── Test 6: two calls produce two distinct files ──────────────────────────────
echo "Test 6: suggestion-record.sh produces unique filenames on successive calls"
test_unique_filenames() {
    if [ ! -f "$SUGGESTION_SCRIPT" ]; then
        assert_eq "suggestion-record.sh exists for unique-filename test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _init_tickets "$repo"

    (cd "$repo" && bash "$SUGGESTION_SCRIPT" \
        --observation "first call" \
        --source "unit-test") 2>/dev/null || true

    (cd "$repo" && bash "$SUGGESTION_SCRIPT" \
        --observation "second call" \
        --source "unit-test") 2>/dev/null || true

    local file_count
    file_count=$(find "$repo/.tickets-tracker/.suggestions" -name '*.json' -type f 2>/dev/null | wc -l | tr -d ' ')
    assert_eq "two calls produce two files" "2" "$file_count"

    if [ "$file_count" -ge 2 ]; then
        local files
        files=$(find "$repo/.tickets-tracker/.suggestions" -name '*.json' -type f 2>/dev/null | sort)
        local first second
        first=$(echo "$files" | head -1)
        second=$(echo "$files" | tail -1)
        assert_ne "filenames differ" "$first" "$second"
    fi
}
test_unique_filenames

# ── Test 7: graceful failure when .tickets-tracker does not exist ──────────────
echo "Test 7: suggestion-record.sh fails gracefully when .tickets-tracker does not exist"
test_graceful_failure_no_tracker() {
    if [ ! -f "$SUGGESTION_SCRIPT" ]; then
        assert_eq "suggestion-record.sh exists for no-tracker test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    # Do NOT run ticket init — .tickets-tracker should not exist

    local exit_code=0
    local stderr_out
    stderr_out=$(cd "$repo" && bash "$SUGGESTION_SCRIPT" \
        --observation "should fail gracefully" \
        --source "unit-test" 2>&1) || exit_code=$?

    assert_eq "exits non-zero without .tickets-tracker" "1" "$([ "$exit_code" -ne 0 ] && echo 1 || echo 0)"

    local has_error_text
    has_error_text=$(echo "$stderr_out" | grep -ic "error\|not found\|not initialized\|warning" || true)
    assert_eq "error message printed on missing tracker" "1" "$([ "${has_error_text:-0}" -gt 0 ] && echo 1 || echo 0)"
}
test_graceful_failure_no_tracker

# ── Test 8: ticket list does not include suggestion records ───────────────────
echo "Test 8: ticket list does not include suggestion records from .suggestions/"
test_ticket_list_excludes_suggestions() {
    if [ ! -f "$SUGGESTION_SCRIPT" ]; then
        assert_eq "suggestion-record.sh exists for list-exclusion test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _init_tickets "$repo"

    # Record a suggestion
    (cd "$repo" && bash "$SUGGESTION_SCRIPT" \
        --observation "should not appear in ticket list" \
        --source "unit-test") 2>/dev/null || true

    # Run ticket list and check suggestions dir is excluded
    local list_output
    local list_exit=0
    list_output=$(TICKETS_TRACKER_DIR="$repo/.tickets-tracker" \
        bash "$TICKET_LIST" 2>/dev/null) || list_exit=$?

    # The output should be a valid JSON array
    local is_array
    is_array=$(python3 -c "
import json, sys
data = json.loads(sys.argv[1])
print('array' if isinstance(data, list) else 'not-array')
" "$list_output" 2>/dev/null || echo "parse-error")

    assert_eq "ticket list returns valid JSON array" "array" "$is_array"

    # The array must not contain any entry whose ticket_id matches the suggestion filename pattern
    # (timestamp_ms-session-prefix-uuid format from .suggestions/).
    # This is a fresh repo with no real tickets, so the list must be empty.
    local suggestion_in_list
    suggestion_in_list=$(python3 -c "
import json, sys, re
try:
    data = json.loads(sys.argv[1])
    suggestion_pattern = re.compile(r'^\d{13}-[a-zA-Z0-9]+-[0-9a-f-]{36}$')
    for t in data:
        tid = t.get('ticket_id', '')
        if suggestion_pattern.match(tid):
            print('found')
            sys.exit(0)
    # Fresh repo: no real tickets were created, so list must be empty
    if len(data) > 0:
        print('unexpected-tickets')
        sys.exit(0)
    print('not-found')
except Exception:
    print('not-found')
" "$list_output" 2>/dev/null || echo "not-found")

    assert_eq "suggestion records not in ticket list" "not-found" "$suggestion_in_list"
}
test_ticket_list_excludes_suggestions

# ── Test 9: --source is required (exits non-zero without it) ─────────────────
echo "Test 9: suggestion-record.sh exits non-zero when --source is omitted"
test_source_required() {
    if [ ! -f "$SUGGESTION_SCRIPT" ]; then
        assert_eq "suggestion-record.sh exists for source-required test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _init_tickets "$repo"

    local exit_code=0
    (cd "$repo" && bash "$SUGGESTION_SCRIPT" \
        --observation "no source given") 2>/dev/null || exit_code=$?

    assert_eq "exits non-zero without --source" "1" "$([ "$exit_code" -ne 0 ] && echo 1 || echo 0)"
}
test_source_required

# ── Test 10: schema_version is present and equals 1 ──────────────────────────
echo "Test 10: suggestion-record.sh writes schema_version=1 in JSON output"
test_schema_version_present() {
    if [ ! -f "$SUGGESTION_SCRIPT" ]; then
        assert_eq "suggestion-record.sh exists for schema-version test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _init_tickets "$repo"

    (cd "$repo" && bash "$SUGGESTION_SCRIPT" \
        --observation "schema version check" \
        --source "unit-test") 2>/dev/null || true

    local event_file
    event_file=$(find "$repo/.tickets-tracker/.suggestions" -name '*.json' -type f 2>/dev/null | head -1)

    if [ -z "$event_file" ]; then
        assert_eq "event file written for schema-version test" "found" "not-found"
        return
    fi

    local schema_ver
    schema_ver=$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
print(data.get('schema_version', 'missing'))
" "$event_file" 2>/dev/null || echo "parse-error")

    assert_eq "schema_version is 1" "1" "$schema_ver"
}
test_schema_version_present

# ── Test 11: --metrics valid JSON is written to the metrics field ─────────────
echo "Test 11: suggestion-record.sh writes valid metrics JSON to the metrics field"
test_metrics_valid() {
    if [ ! -f "$SUGGESTION_SCRIPT" ]; then
        assert_eq "suggestion-record.sh exists for metrics-valid test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _init_tickets "$repo"

    (cd "$repo" && bash "$SUGGESTION_SCRIPT" \
        --observation "metrics check" \
        --source "unit-test" \
        --metrics '{"wall_clock_s": 45, "tokens": 3000}') 2>/dev/null || true

    local event_file
    event_file=$(find "$repo/.tickets-tracker/.suggestions" -name '*.json' -type f 2>/dev/null | head -1)

    if [ -z "$event_file" ]; then
        assert_eq "event file written for metrics-valid test" "found" "not-found"
        return
    fi

    local metrics_result
    metrics_result=$(python3 -c "
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    data = json.load(f)
m = data.get('metrics', {})
if m.get('wall_clock_s') == 45 and m.get('tokens') == 3000:
    print('ok')
else:
    print('wrong:' + json.dumps(m))
" "$event_file" 2>/dev/null || echo "parse-error")

    assert_eq "metrics field contains parsed JSON" "ok" "$metrics_result"
}
test_metrics_valid

# ── Test 12: --metrics invalid JSON exits non-zero ────────────────────────────
echo "Test 12: suggestion-record.sh exits non-zero when --metrics is invalid JSON"
test_metrics_invalid() {
    if [ ! -f "$SUGGESTION_SCRIPT" ]; then
        assert_eq "suggestion-record.sh exists for metrics-invalid test" "exists" "missing"
        return
    fi

    local repo
    repo=$(_make_test_repo)
    _init_tickets "$repo"

    local exit_code=0
    (cd "$repo" && bash "$SUGGESTION_SCRIPT" \
        --observation "bad metrics" \
        --source "unit-test" \
        --metrics 'not-valid-json') 2>/dev/null || exit_code=$?

    assert_eq "exits non-zero on invalid --metrics JSON" "1" "$([ "$exit_code" -ne 0 ] && echo 1 || echo 0)"
}
test_metrics_invalid

print_summary
