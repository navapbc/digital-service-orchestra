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

# ── Helper: extract a hypothesis verdict from JSON output ─────────────────────
_get_hypothesis() {
    local json="$1" hyp="$2"
    python3 -c "
import sys, json
data = json.loads(sys.stdin.read())
if isinstance(data, list):
    d = data[0] if data else {}
else:
    d = data
hypotheses = d.get('hypotheses', {})
print(hypotheses.get('$hyp', ''))
" <<< "$json" 2>/dev/null || echo ""
}

# ── test_h1_confirmed_high_tool_call_count ────────────────────────────────────
# CONTROL_LOSS + tool_call_count >= 60 → H1=confirmed
test_h1_confirmed_high_tool_call_count() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local logfile="$tmpdir/dso-skill-trace-h1.log"

    # INVOKE with tool_call_count=65 (>= threshold 60), no RESUMED = CONTROL_LOSS
    printf '{"type":"SKILL_INVOKE","timestamp":"2026-04-02T17:39:27Z","skill_name":"sprint","nesting_depth":1,"session_ordinal":1,"tool_call_count":65,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}\n' \
        >> "$logfile"

    local output exit_code=0
    output=$(_run_analyze "$logfile") || exit_code=$?

    assert_eq "test_h1_confirmed_high_tool_call_count: exits 0" "0" "$exit_code"

    local h1_status
    h1_status=$(_get_hypothesis "$output" "H1")
    assert_eq "test_h1_confirmed_high_tool_call_count: H1=confirmed when tool_call_count>=60 and CONTROL_LOSS" "confirmed" "$h1_status"

    assert_pass_if_clean "test_h1_confirmed_high_tool_call_count"
}

# ── test_h1_refuted_low_tool_call_count ───────────────────────────────────────
# CONTROL_LOSS + tool_call_count < 60 → H1=refuted
test_h1_refuted_low_tool_call_count() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local logfile="$tmpdir/dso-skill-trace-h1r.log"

    # INVOKE with tool_call_count=20 (< threshold 60), no RESUMED = CONTROL_LOSS
    printf '{"type":"SKILL_INVOKE","timestamp":"2026-04-02T17:39:27Z","skill_name":"sprint","nesting_depth":1,"session_ordinal":1,"tool_call_count":20,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}\n' \
        >> "$logfile"

    local output exit_code=0
    output=$(_run_analyze "$logfile") || exit_code=$?

    assert_eq "test_h1_refuted_low_tool_call_count: exits 0" "0" "$exit_code"

    local h1_status
    h1_status=$(_get_hypothesis "$output" "H1")
    assert_eq "test_h1_refuted_low_tool_call_count: H1=refuted when tool_call_count<60 and CONTROL_LOSS" "refuted" "$h1_status"

    assert_pass_if_clean "test_h1_refuted_low_tool_call_count"
}

# ── test_h2_confirmed_high_cumulative_bytes ───────────────────────────────────
# CONTROL_LOSS + cumulative_bytes >= 50000 → H2=confirmed
test_h2_confirmed_high_cumulative_bytes() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local logfile="$tmpdir/dso-skill-trace-h2.log"

    # INVOKE (no RESUMED = CONTROL_LOSS) plus a breadcrumb with high cumulative_bytes
    printf '{"type":"SKILL_INVOKE","timestamp":"2026-04-02T17:39:27Z","skill_name":"sprint","nesting_depth":1,"session_ordinal":1,"tool_call_count":10,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":55000,"termination_directive":null,"user_interaction_count":0}\n' \
        >> "$logfile"

    local output exit_code=0
    output=$(_run_analyze "$logfile") || exit_code=$?

    assert_eq "test_h2_confirmed_high_cumulative_bytes: exits 0" "0" "$exit_code"

    local h2_status
    h2_status=$(_get_hypothesis "$output" "H2")
    assert_eq "test_h2_confirmed_high_cumulative_bytes: H2=confirmed when cumulative_bytes>=50000 and CONTROL_LOSS" "confirmed" "$h2_status"

    assert_pass_if_clean "test_h2_confirmed_high_cumulative_bytes"
}

# ── test_h3_confirmed_long_elapsed_ms ────────────────────────────────────────
# CONTROL_LOSS + elapsed_ms >= 300000 on SKILL_EXIT → H3=confirmed
test_h3_confirmed_long_elapsed_ms() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local logfile="$tmpdir/dso-skill-trace-h3.log"

    # INVOKE (no RESUMED = CONTROL_LOSS)
    printf '{"type":"SKILL_INVOKE","timestamp":"2026-04-02T17:39:27Z","skill_name":"sprint","nesting_depth":1,"session_ordinal":1,"tool_call_count":10,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}\n' \
        >> "$logfile"
    # SKILL_EXIT with elapsed_ms >= 300000
    printf '{"type":"SKILL_EXIT","timestamp":"2026-04-02T17:44:27Z","skill_name":"preplanning","nesting_depth":1,"session_ordinal":2,"tool_call_count":50,"skill_file_size":null,"elapsed_ms":350000,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}\n' \
        >> "$logfile"

    local output exit_code=0
    output=$(_run_analyze "$logfile") || exit_code=$?

    assert_eq "test_h3_confirmed_long_elapsed_ms: exits 0" "0" "$exit_code"

    local h3_status
    h3_status=$(_get_hypothesis "$output" "H3")
    assert_eq "test_h3_confirmed_long_elapsed_ms: H3=confirmed when elapsed_ms>=300000 and CONTROL_LOSS" "confirmed" "$h3_status"

    assert_pass_if_clean "test_h3_confirmed_long_elapsed_ms"
}

# ── test_h4_confirmed_high_user_interaction ───────────────────────────────────
# CONTROL_LOSS + user_interaction_count >= 3 on SKILL_EXIT → H4=confirmed
test_h4_confirmed_high_user_interaction() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local logfile="$tmpdir/dso-skill-trace-h4.log"

    # INVOKE (no RESUMED = CONTROL_LOSS)
    printf '{"type":"SKILL_INVOKE","timestamp":"2026-04-02T17:39:27Z","skill_name":"sprint","nesting_depth":1,"session_ordinal":1,"tool_call_count":10,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}\n' \
        >> "$logfile"
    # SKILL_EXIT with user_interaction_count >= 3 (threshold is 3)
    printf '{"type":"SKILL_EXIT","timestamp":"2026-04-02T17:44:27Z","skill_name":"preplanning","nesting_depth":1,"session_ordinal":2,"tool_call_count":50,"skill_file_size":null,"elapsed_ms":5000,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":4}\n' \
        >> "$logfile"

    local output exit_code=0
    output=$(_run_analyze "$logfile") || exit_code=$?

    assert_eq "test_h4_confirmed_high_user_interaction: exits 0" "0" "$exit_code"

    local h4_status
    h4_status=$(_get_hypothesis "$output" "H4")
    assert_eq "test_h4_confirmed_high_user_interaction: H4=confirmed when user_interaction_count>=3 and CONTROL_LOSS" "confirmed" "$h4_status"

    assert_pass_if_clean "test_h4_confirmed_high_user_interaction"
}

# ── test_h5_confirmed_late_session_ordinal ────────────────────────────────────
# CONTROL_LOSS at session_ordinal >= 10 → H5=confirmed
test_h5_confirmed_late_session_ordinal() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local logfile="$tmpdir/dso-skill-trace-h5.log"

    # INVOKE at ordinal=12 (>= threshold 10), no RESUMED = CONTROL_LOSS
    printf '{"type":"SKILL_INVOKE","timestamp":"2026-04-02T17:39:27Z","skill_name":"sprint","nesting_depth":1,"session_ordinal":12,"tool_call_count":10,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}\n' \
        >> "$logfile"

    local output exit_code=0
    output=$(_run_analyze "$logfile") || exit_code=$?

    assert_eq "test_h5_confirmed_late_session_ordinal: exits 0" "0" "$exit_code"

    local h5_status
    h5_status=$(_get_hypothesis "$output" "H5")
    assert_eq "test_h5_confirmed_late_session_ordinal: H5=confirmed when ordinal>=10 and CONTROL_LOSS" "confirmed" "$h5_status"

    assert_pass_if_clean "test_h5_confirmed_late_session_ordinal"
}

# ── test_h6_confirmed_large_skill_file_size ───────────────────────────────────
# CONTROL_LOSS + skill_file_size >= 20000 → H6=confirmed
test_h6_confirmed_large_skill_file_size() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local logfile="$tmpdir/dso-skill-trace-h6.log"

    # INVOKE with skill_file_size >= 20000, no RESUMED = CONTROL_LOSS
    printf '{"type":"SKILL_INVOKE","timestamp":"2026-04-02T17:39:27Z","skill_name":"sprint","nesting_depth":1,"session_ordinal":1,"tool_call_count":10,"skill_file_size":25000,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}\n' \
        >> "$logfile"

    local output exit_code=0
    output=$(_run_analyze "$logfile") || exit_code=$?

    assert_eq "test_h6_confirmed_large_skill_file_size: exits 0" "0" "$exit_code"

    local h6_status
    h6_status=$(_get_hypothesis "$output" "H6")
    assert_eq "test_h6_confirmed_large_skill_file_size: H6=confirmed when skill_file_size>=20000 and CONTROL_LOSS" "confirmed" "$h6_status"

    assert_pass_if_clean "test_h6_confirmed_large_skill_file_size"
}

# ── test_h8_confirmed_enter_without_exit ─────────────────────────────────────
# SKILL_ENTER with no matching SKILL_EXIT → H8=confirmed
test_h8_confirmed_enter_without_exit() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local logfile="$tmpdir/dso-skill-trace-h8.log"

    # INVOKE (no RESUMED = CONTROL_LOSS to ensure hypotheses are classified)
    printf '{"type":"SKILL_INVOKE","timestamp":"2026-04-02T17:39:27Z","skill_name":"sprint","nesting_depth":1,"session_ordinal":1,"tool_call_count":10,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}\n' \
        >> "$logfile"
    # SKILL_ENTER at ordinal=2 with no matching SKILL_EXIT
    printf '{"type":"SKILL_ENTER","timestamp":"2026-04-02T17:39:28Z","skill_name":"preplanning","nesting_depth":2,"session_ordinal":2,"tool_call_count":15,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}\n' \
        >> "$logfile"

    local output exit_code=0
    output=$(_run_analyze "$logfile") || exit_code=$?

    assert_eq "test_h8_confirmed_enter_without_exit: exits 0" "0" "$exit_code"

    local h8_status
    h8_status=$(_get_hypothesis "$output" "H8")
    assert_eq "test_h8_confirmed_enter_without_exit: H8=confirmed when SKILL_ENTER has no matching SKILL_EXIT" "confirmed" "$h8_status"

    assert_pass_if_clean "test_h8_confirmed_enter_without_exit"
}

# ── test_h9_confirmed_multiple_control_loss ───────────────────────────────────
# Two INVOKE without RESUMED → two CONTROL_LOSS events → H9=confirmed
test_h9_confirmed_multiple_control_loss() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local logfile="$tmpdir/dso-skill-trace-h9.log"

    # INVOKE ordinal=1 (no RESUMED)
    printf '{"type":"SKILL_INVOKE","timestamp":"2026-04-02T17:39:27Z","skill_name":"sprint","nesting_depth":1,"session_ordinal":1,"tool_call_count":10,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}\n' \
        >> "$logfile"
    # INVOKE ordinal=2 (no RESUMED)
    printf '{"type":"SKILL_INVOKE","timestamp":"2026-04-02T17:40:00Z","skill_name":"preplanning","nesting_depth":1,"session_ordinal":2,"tool_call_count":20,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}\n' \
        >> "$logfile"

    local output exit_code=0
    output=$(_run_analyze "$logfile") || exit_code=$?

    assert_eq "test_h9_confirmed_multiple_control_loss: exits 0" "0" "$exit_code"

    local h9_status
    h9_status=$(_get_hypothesis "$output" "H9")
    assert_eq "test_h9_confirmed_multiple_control_loss: H9=confirmed when >=2 CONTROL_LOSS events" "confirmed" "$h9_status"

    assert_pass_if_clean "test_h9_confirmed_multiple_control_loss"
}

# ── test_h10_confirmed_all_invokes_are_control_loss ───────────────────────────
# All INVOKEs lack RESUMED (every invoke is a CONTROL_LOSS) → H10=confirmed
test_h10_confirmed_all_invokes_are_control_loss() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local logfile="$tmpdir/dso-skill-trace-h10.log"

    # Two INVOKEs, neither has a RESUMED → both are CONTROL_LOSS → H10=confirmed
    printf '{"type":"SKILL_INVOKE","timestamp":"2026-04-02T17:39:27Z","skill_name":"sprint","nesting_depth":1,"session_ordinal":1,"tool_call_count":10,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}\n' \
        >> "$logfile"
    printf '{"type":"SKILL_INVOKE","timestamp":"2026-04-02T17:40:00Z","skill_name":"preplanning","nesting_depth":1,"session_ordinal":2,"tool_call_count":20,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}\n' \
        >> "$logfile"

    local output exit_code=0
    output=$(_run_analyze "$logfile") || exit_code=$?

    assert_eq "test_h10_confirmed_all_invokes_are_control_loss: exits 0" "0" "$exit_code"

    local h10_status
    h10_status=$(_get_hypothesis "$output" "H10")
    assert_eq "test_h10_confirmed_all_invokes_are_control_loss: H10=confirmed when all invokes lack RESUMED" "confirmed" "$h10_status"

    assert_pass_if_clean "test_h10_confirmed_all_invokes_are_control_loss"
}

# ── test_h10_refuted_some_invokes_resumed ─────────────────────────────────────
# One INVOKE has RESUMED, one does not → not all lost → H10=refuted
test_h10_refuted_some_invokes_resumed() {
    _snapshot_fail
    local tmpdir
    tmpdir="$(mktemp -d)"
    _CLEANUP_DIRS+=("$tmpdir")
    local logfile="$tmpdir/dso-skill-trace-h10r.log"

    # ordinal=1: complete pair (no CONTROL_LOSS)
    printf '{"type":"SKILL_INVOKE","timestamp":"2026-04-02T17:39:27Z","skill_name":"sprint","nesting_depth":1,"session_ordinal":1,"tool_call_count":10,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}\n' \
        >> "$logfile"
    printf '{"type":"SKILL_RESUMED","timestamp":"2026-04-02T17:39:28Z","skill_name":"sprint","nesting_depth":1,"session_ordinal":1,"tool_call_count":10,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}\n' \
        >> "$logfile"
    # ordinal=2: no RESUMED (CONTROL_LOSS)
    printf '{"type":"SKILL_INVOKE","timestamp":"2026-04-02T17:40:00Z","skill_name":"preplanning","nesting_depth":1,"session_ordinal":2,"tool_call_count":20,"skill_file_size":null,"elapsed_ms":null,"cumulative_bytes":null,"termination_directive":null,"user_interaction_count":0}\n' \
        >> "$logfile"

    local output exit_code=0
    output=$(_run_analyze "$logfile") || exit_code=$?

    assert_eq "test_h10_refuted_some_invokes_resumed: exits 0" "0" "$exit_code"

    local h10_status
    h10_status=$(_get_hypothesis "$output" "H10")
    assert_eq "test_h10_refuted_some_invokes_resumed: H10=refuted when only some invokes are CONTROL_LOSS" "refuted" "$h10_status"

    assert_pass_if_clean "test_h10_refuted_some_invokes_resumed"
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
test_h1_confirmed_high_tool_call_count
test_h1_refuted_low_tool_call_count
test_h2_confirmed_high_cumulative_bytes
test_h3_confirmed_long_elapsed_ms
test_h4_confirmed_high_user_interaction
test_h5_confirmed_late_session_ordinal
test_h6_confirmed_large_skill_file_size
test_h8_confirmed_enter_without_exit
test_h9_confirmed_multiple_control_loss
test_h10_confirmed_all_invokes_are_control_loss
test_h10_refuted_some_invokes_resumed

print_summary
