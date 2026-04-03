#!/usr/bin/env bash
# tests/scripts/test-skill-trace-analyze.sh
# TDD tests for plugins/dso/scripts/skill-trace-analyze.py
#
# Tests cover: CONTROL_LOSS detection, no false positives on complete pairs,
# H7 hypothesis classification (confirmed/refuted/insufficient-data), empty/
# nonexistent log graceful exit, malformed line tolerance, and multiple nested
# invocation correct pairing.
#
# Usage: bash tests/scripts/test-skill-trace-analyze.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# RED STATE: All tests currently fail because skill-trace-analyze.py does not
# yet exist. They will pass (GREEN) after the script is implemented.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/skill-trace-analyze.py"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

echo "=== test-skill-trace-analyze.sh ==="

# ── Helper: write a breadcrumb line to a log file ────────────────────────────
_write_breadcrumb() {
    local logfile="$1"
    local type="$2"
    local skill="$3"
    local ordinal="$4"
    local depth="${5:-1}"
    printf '{"type":"%s","timestamp":"2026-04-02T17:39:27Z","skill_name":"%s","nesting_depth":%d,"session_ordinal":%d,"tool_call_count":42,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}\n' \
        "$type" "$skill" "$depth" "$ordinal" >> "$logfile"
}

# ── Helper: run analysis script on a log file and get JSON output ────────────
_run_analyze() {
    local logfile="$1"
    python3 "$SCRIPT" --log "$logfile" 2>/dev/null
}

# ── Helper: extract a top-level field from JSON array or object output ────────
_get_field() {
    local json="$1" field="$2"
    python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
# support both array of session objects and a single object
if isinstance(data, list):
    d = data[0] if data else {}
else:
    d = data
print(d.get('$field', ''))
" <<< "$json" 2>/dev/null || echo ""
}

# ── test_control_loss_detected ────────────────────────────────────────────────
# INVOKE with no matching RESUMED must produce CONTROL_LOSS in output
test_control_loss_detected() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local logfile="$tmpdir/dso-skill-trace-sess1.log"

    # Write INVOKE but no RESUMED
    _write_breadcrumb "$logfile" "SKILL_INVOKE" "implementation-plan" 3 1

    local output exit_code=0
    output=$(_run_analyze "$logfile") || exit_code=$?

    assert_eq "test_control_loss_detected: exits 0" "0" "$exit_code"

    # Output must contain CONTROL_LOSS somewhere
    local has_control_loss
    has_control_loss=$(python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
text = json.dumps(data)
print('yes' if 'CONTROL_LOSS' in text else 'no')
" <<< "$output" 2>/dev/null) || has_control_loss="no"
    assert_eq "test_control_loss_detected: CONTROL_LOSS appears in output" "yes" "$has_control_loss"

    assert_pass_if_clean "test_control_loss_detected"
}

# ── test_no_false_positive_complete_pairs ─────────────────────────────────────
# Complete INVOKE/RESUMED pairs must NOT produce CONTROL_LOSS
test_no_false_positive_complete_pairs() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local logfile="$tmpdir/dso-skill-trace-sess2.log"

    # Write matched INVOKE + RESUMED pair
    _write_breadcrumb "$logfile" "SKILL_INVOKE"  "preplanning" 1 1
    _write_breadcrumb "$logfile" "SKILL_RESUMED" "preplanning" 1 1

    local output exit_code=0
    output=$(_run_analyze "$logfile") || exit_code=$?

    assert_eq "test_no_false_positive_complete_pairs: exits 0" "0" "$exit_code"

    local has_control_loss
    has_control_loss=$(python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
text = json.dumps(data)
print('yes' if 'CONTROL_LOSS' in text else 'no')
" <<< "$output" 2>/dev/null) || has_control_loss="yes"
    assert_eq "test_no_false_positive_complete_pairs: no CONTROL_LOSS for complete pairs" "no" "$has_control_loss"

    assert_pass_if_clean "test_no_false_positive_complete_pairs"
}

# ── test_h7_confirmed_depth3_with_control_loss ────────────────────────────────
# depth=3 + CONTROL_LOSS → H7 classified as confirmed
test_h7_confirmed_depth3_with_control_loss() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local logfile="$tmpdir/dso-skill-trace-sess3.log"

    # Write INVOKE at depth=3 but no RESUMED (causes CONTROL_LOSS)
    _write_breadcrumb "$logfile" "SKILL_INVOKE" "implementation-plan" 5 3

    local output exit_code=0
    output=$(_run_analyze "$logfile") || exit_code=$?

    assert_eq "test_h7_confirmed_depth3_with_control_loss: exits 0" "0" "$exit_code"

    local h7_status
    h7_status=$(python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
# Support list of sessions or single session object
if isinstance(data, list):
    d = data[0] if data else {}
else:
    d = data
hypotheses = d.get('hypotheses', {})
h7 = hypotheses.get('H7', hypotheses.get('h7', ''))
print(h7)
" <<< "$output" 2>/dev/null) || h7_status=""

    assert_eq "test_h7_confirmed_depth3_with_control_loss: H7=confirmed when depth>=3 and CONTROL_LOSS" "confirmed" "$h7_status"

    assert_pass_if_clean "test_h7_confirmed_depth3_with_control_loss"
}

# ── test_h7_refuted_depth1_with_control_loss ─────────────────────────────────
# depth=1 + CONTROL_LOSS → H7 classified as refuted
test_h7_refuted_depth1_with_control_loss() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local logfile="$tmpdir/dso-skill-trace-sess4.log"

    # Write INVOKE at depth=1 but no RESUMED (causes CONTROL_LOSS at shallow depth)
    _write_breadcrumb "$logfile" "SKILL_INVOKE" "implementation-plan" 2 1

    local output exit_code=0
    output=$(_run_analyze "$logfile") || exit_code=$?

    assert_eq "test_h7_refuted_depth1_with_control_loss: exits 0" "0" "$exit_code"

    local h7_status
    h7_status=$(python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
if isinstance(data, list):
    d = data[0] if data else {}
else:
    d = data
hypotheses = d.get('hypotheses', {})
h7 = hypotheses.get('H7', hypotheses.get('h7', ''))
print(h7)
" <<< "$output" 2>/dev/null) || h7_status=""

    assert_eq "test_h7_refuted_depth1_with_control_loss: H7=refuted when depth<3 and CONTROL_LOSS" "refuted" "$h7_status"

    assert_pass_if_clean "test_h7_refuted_depth1_with_control_loss"
}

# ── test_h7_insufficient_data_no_depth ───────────────────────────────────────
# Log with no depth field on INVOKE → H7 classified as insufficient-data
test_h7_insufficient_data_no_depth() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local logfile="$tmpdir/dso-skill-trace-sess5.log"

    # Write INVOKE with nesting_depth omitted (use raw JSON without depth)
    printf '{"type":"SKILL_INVOKE","timestamp":"2026-04-02T17:39:27Z","skill_name":"preplanning","session_ordinal":1,"tool_call_count":10}\n' \
        >> "$logfile"

    local output exit_code=0
    output=$(_run_analyze "$logfile") || exit_code=$?

    assert_eq "test_h7_insufficient_data_no_depth: exits 0" "0" "$exit_code"

    local h7_status
    h7_status=$(python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
if isinstance(data, list):
    d = data[0] if data else {}
else:
    d = data
hypotheses = d.get('hypotheses', {})
h7 = hypotheses.get('H7', hypotheses.get('h7', ''))
print(h7)
" <<< "$output" 2>/dev/null) || h7_status=""

    assert_eq "test_h7_insufficient_data_no_depth: H7=insufficient-data when no depth field" "insufficient-data" "$h7_status"

    assert_pass_if_clean "test_h7_insufficient_data_no_depth"
}

# ── test_empty_log_graceful_exit ──────────────────────────────────────────────
# Empty log file → graceful exit with empty/stub report (no crash)
test_empty_log_graceful_exit() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local logfile="$tmpdir/dso-skill-trace-empty.log"

    # Create empty log file
    touch "$logfile"

    local output exit_code=0
    output=$(_run_analyze "$logfile") || exit_code=$?

    assert_eq "test_empty_log_graceful_exit: exits 0 on empty log" "0" "$exit_code"

    # Output must be valid JSON (empty array, empty object, or stub report is fine)
    local is_valid_json
    is_valid_json=$(python3 -c "import sys, json; json.loads(sys.stdin.read()); print('yes')" <<< "$output" 2>/dev/null) || is_valid_json="no"
    assert_eq "test_empty_log_graceful_exit: output is valid JSON" "yes" "$is_valid_json"

    assert_pass_if_clean "test_empty_log_graceful_exit"
}

# ── test_nonexistent_log_graceful_exit ────────────────────────────────────────
# Nonexistent log file → graceful exit with no crash
test_nonexistent_log_graceful_exit() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local logfile="$tmpdir/dso-skill-trace-nonexistent.log"
    # Do NOT create the file

    local output exit_code=0
    output=$(_run_analyze "$logfile") || exit_code=$?

    assert_eq "test_nonexistent_log_graceful_exit: exits 0 on nonexistent log" "0" "$exit_code"

    # Output must be valid JSON
    local is_valid_json
    is_valid_json=$(python3 -c "import sys, json; json.loads(sys.stdin.read()); print('yes')" <<< "$output" 2>/dev/null) || is_valid_json="no"
    assert_eq "test_nonexistent_log_graceful_exit: output is valid JSON" "yes" "$is_valid_json"

    assert_pass_if_clean "test_nonexistent_log_graceful_exit"
}

# ── test_malformed_lines_skipped_without_crash ────────────────────────────────
# Malformed and truncated log lines must be skipped without crash
test_malformed_lines_skipped_without_crash() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local logfile="$tmpdir/dso-skill-trace-malformed.log"

    # Mix of malformed, truncated, and valid lines
    printf 'this is not json at all\n'                                >> "$logfile"
    printf '{"type":"SKILL_INVOKE","skill_name":"sprint"\n'          >> "$logfile"  # truncated JSON
    printf '{broken json with "type":"SKILL_INVOKE"}\n'              >> "$logfile"  # broken
    printf '   \n'                                                    >> "$logfile"  # whitespace only
    # One valid complete pair so there is parseable content
    _write_breadcrumb "$logfile" "SKILL_INVOKE"  "sprint" 1 1
    _write_breadcrumb "$logfile" "SKILL_RESUMED" "sprint" 1 1

    local output exit_code=0
    output=$(_run_analyze "$logfile") || exit_code=$?

    assert_eq "test_malformed_lines_skipped_without_crash: exits 0 despite malformed lines" "0" "$exit_code"

    local is_valid_json
    is_valid_json=$(python3 -c "import sys, json; json.loads(sys.stdin.read()); print('yes')" <<< "$output" 2>/dev/null) || is_valid_json="no"
    assert_eq "test_malformed_lines_skipped_without_crash: output is valid JSON" "yes" "$is_valid_json"

    assert_pass_if_clean "test_malformed_lines_skipped_without_crash"
}

# ── test_multiple_nested_invocations_correct_pairing ─────────────────────────
# Multiple interleaved INVOKE/RESUMED pairs must be correctly paired
# (two invocations: one complete, one missing RESUMED = 1 CONTROL_LOSS)
test_multiple_nested_invocations_correct_pairing() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local logfile="$tmpdir/dso-skill-trace-multi.log"

    # Ordinal 1: complete pair (no CONTROL_LOSS)
    _write_breadcrumb "$logfile" "SKILL_INVOKE"  "preplanning"        1 1
    _write_breadcrumb "$logfile" "SKILL_RESUMED" "preplanning"        1 1

    # Ordinal 2: complete pair (no CONTROL_LOSS)
    _write_breadcrumb "$logfile" "SKILL_INVOKE"  "implementation-plan" 2 2
    _write_breadcrumb "$logfile" "SKILL_RESUMED" "implementation-plan" 2 2

    # Ordinal 3: missing RESUMED (CONTROL_LOSS)
    _write_breadcrumb "$logfile" "SKILL_INVOKE"  "sprint"             3 1
    # No RESUMED for ordinal 3

    local output exit_code=0
    output=$(_run_analyze "$logfile") || exit_code=$?

    assert_eq "test_multiple_nested_invocations_correct_pairing: exits 0" "0" "$exit_code"

    # Must detect exactly one CONTROL_LOSS event
    local control_loss_count
    control_loss_count=$(python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
if isinstance(data, list):
    d = data[0] if data else {}
else:
    d = data
# Look for control_loss_events list or count
events = d.get('control_loss_events', d.get('control_loss', []))
if isinstance(events, list):
    print(len(events))
elif isinstance(events, int):
    print(events)
else:
    print(0)
" <<< "$output" 2>/dev/null) || control_loss_count="0"

    assert_eq "test_multiple_nested_invocations_correct_pairing: exactly 1 CONTROL_LOSS detected" "1" "$control_loss_count"

    assert_pass_if_clean "test_multiple_nested_invocations_correct_pairing"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_control_loss_detected
test_no_false_positive_complete_pairs
test_h7_confirmed_depth3_with_control_loss
test_h7_refuted_depth1_with_control_loss
test_h7_insufficient_data_no_depth
test_empty_log_graceful_exit
test_nonexistent_log_graceful_exit
test_malformed_lines_skipped_without_crash
test_multiple_nested_invocations_correct_pairing

print_summary
