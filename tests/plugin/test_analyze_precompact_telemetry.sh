#!/usr/bin/env bash
# tests/plugin/test_analyze_precompact_telemetry.sh
#
# Tests for analyze-precompact-telemetry.sh analysis script.
#
# Usage: bash tests/plugin/test_analyze_precompact_telemetry.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
ANALYZE_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/analyze-precompact-telemetry.sh"

PASS=0
FAIL=0

assert_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected='$expected', actual='$actual')"
        FAIL=$((FAIL + 1))
    fi
}

assert_true() {
    local desc="$1"
    shift
    if "$@" 2>/dev/null; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc"
        FAIL=$((FAIL + 1))
    fi
}

assert_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -q "$needle"; then
        echo "  PASS: $desc"
        PASS=$((PASS + 1))
    else
        echo "  FAIL: $desc (expected output to contain '$needle')"
        FAIL=$((FAIL + 1))
    fi
}

# ── Helper: create fixture JSONL ─────────────────────────────────────────────
create_fixture() {
    local tmpfile
    tmpfile=$(mktemp /tmp/telemetry-test-XXXXXX.jsonl)

    cat > "$tmpfile" << 'FIXTURE_EOF'
{"timestamp":"2026-03-13T10:00:00Z","session_id":"sess-A","parent_session_id":null,"context_tokens":80000,"context_limit":200000,"active_task_count":1,"git_dirty":false,"hook_outcome":"skipped","exit_reason":"no_real_changes","working_directory":"/tmp/test","duration_ms":15}
{"timestamp":"2026-03-13T10:05:00Z","session_id":"sess-A","parent_session_id":null,"context_tokens":120000,"context_limit":200000,"active_task_count":2,"git_dirty":true,"hook_outcome":"skipped","exit_reason":"no_real_changes","working_directory":"/tmp/test","duration_ms":12}
{"timestamp":"2026-03-13T10:10:00Z","session_id":"sess-A","parent_session_id":null,"context_tokens":150000,"context_limit":200000,"active_task_count":3,"git_dirty":true,"hook_outcome":"committed","exit_reason":"committed","working_directory":"/tmp/test","duration_ms":250}
{"timestamp":"2026-03-13T11:00:00Z","session_id":"sess-B","parent_session_id":"parent-B","context_tokens":null,"context_limit":200000,"active_task_count":0,"git_dirty":false,"hook_outcome":"exited_early","exit_reason":"env_var_disabled","working_directory":"/tmp/test2","duration_ms":5}
{"timestamp":"2026-03-13T11:02:00Z","session_id":"sess-B","parent_session_id":"parent-B","context_tokens":50000,"context_limit":200000,"active_task_count":0,"git_dirty":false,"hook_outcome":"exited_early","exit_reason":"env_var_disabled","working_directory":"/tmp/test2","duration_ms":4}
FIXTURE_EOF
    echo "$tmpfile"
}

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 1: Script exits non-zero with no arguments
# ═══════════════════════════════════════════════════════════════════════════════
echo "TEST 1: missing_arguments_exits_nonzero"
_exit=0
bash "$ANALYZE_SCRIPT" 2>/dev/null || _exit=$?
assert_eq "exits non-zero with no arguments" "1" "$([ $_exit -ne 0 ] && echo 1 || echo 0)"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 2: Total fire count = 5
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "TEST 2: total_fire_count"
FIXTURE=$(create_fixture)
_exit=0
OUTPUT=$(bash "$ANALYZE_SCRIPT" "$FIXTURE" 2>/dev/null) || _exit=$?
assert_eq "script exits 0" "0" "$_exit"
assert_contains "output contains total 5" "$OUTPUT" "Total fires: 5"
rm -f "$FIXTURE"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 3: Per-session counts
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "TEST 3: per_session_counts"
FIXTURE=$(create_fixture)
OUTPUT=$(bash "$ANALYZE_SCRIPT" "$FIXTURE" 2>/dev/null)
assert_contains "output shows sess-A" "$OUTPUT" "sess-A"
assert_contains "output shows sess-B" "$OUTPUT" "sess-B"
rm -f "$FIXTURE"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 4: Outcome breakdown
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "TEST 4: outcome_breakdown"
FIXTURE=$(create_fixture)
OUTPUT=$(bash "$ANALYZE_SCRIPT" "$FIXTURE" 2>/dev/null)
assert_contains "output contains committed" "$OUTPUT" "committed"
assert_contains "output contains skipped" "$OUTPUT" "skipped"
assert_contains "output contains exited_early" "$OUTPUT" "exited_early"
rm -f "$FIXTURE"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 5: JSON output is valid
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "TEST 5: json_output_valid"
FIXTURE=$(create_fixture)
_exit=0
JSON_OUTPUT=$(bash "$ANALYZE_SCRIPT" --json "$FIXTURE" 2>/dev/null) || _exit=$?
assert_eq "script exits 0" "0" "$_exit"
_json_valid=0
echo "$JSON_OUTPUT" | python3 -c "import json,sys; json.load(sys.stdin)" 2>/dev/null && _json_valid=1
assert_eq "--json produces valid JSON" "1" "$_json_valid"
rm -f "$FIXTURE"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 6: JSON total_fires = 5
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "TEST 6: json_total_fires"
FIXTURE=$(create_fixture)
JSON_OUTPUT=$(bash "$ANALYZE_SCRIPT" --json "$FIXTURE" 2>/dev/null)
TOTAL=$(echo "$JSON_OUTPUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['total_fires'])")
assert_eq "total_fires is 5" "5" "$TOTAL"
rm -f "$FIXTURE"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 7: JSON outcome breakdown
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "TEST 7: json_outcome_breakdown"
FIXTURE=$(create_fixture)
JSON_OUTPUT=$(bash "$ANALYZE_SCRIPT" --json "$FIXTURE" 2>/dev/null)
COMMITTED=$(echo "$JSON_OUTPUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['outcome_breakdown']['committed'])")
SKIPPED=$(echo "$JSON_OUTPUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['outcome_breakdown']['skipped'])")
EXITED_EARLY=$(echo "$JSON_OUTPUT" | python3 -c "import json,sys; print(json.load(sys.stdin)['outcome_breakdown']['exited_early'])")
assert_eq "committed count" "1" "$COMMITTED"
assert_eq "skipped count" "2" "$SKIPPED"
assert_eq "exited_early count" "2" "$EXITED_EARLY"
rm -f "$FIXTURE"

# ═══════════════════════════════════════════════════════════════════════════════
# TEST 8: Potentially spurious entries flagged
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "TEST 8: potentially_spurious"
FIXTURE=$(create_fixture)
OUTPUT=$(bash "$ANALYZE_SCRIPT" "$FIXTURE" 2>/dev/null)
assert_contains "output flags potentially spurious entries" "$OUTPUT" "[Ss]purious"
rm -f "$FIXTURE"

# ═══════════════════════════════════════════════════════════════════════════════
# Summary
# ═══════════════════════════════════════════════════════════════════════════════
echo ""
echo "════════════════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
echo "════════════════════════════════════════"

[[ $FAIL -eq 0 ]] && exit 0 || exit 1
