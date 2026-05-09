#!/usr/bin/env bash
# tests/skills/dso_ci_review/test-ci-review-corpus-delta.sh
# Smoke tests for ci-review-corpus-delta.sh — verifies basic output structure
# and exit-code semantics without requiring a real corpus of LLM-generated findings.
#
# Usage: bash tests/skills/dso_ci_review/test-ci-review-corpus-delta.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
DELTA_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ci-review-corpus-delta.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-ci-review-corpus-delta.sh ==="

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_make_findings() {
    # $1: output file path
    # $2: JSON findings array string
    printf '%s\n' "$2" > "$1"
}

_make_fixture() {
    # $1: corpus dir, $2: fixture name, $3: pre-findings JSON (empty = skip), $4: post-findings JSON
    local dir="$1/$2"
    mkdir -p "$dir"
    if [[ -n "$3" ]]; then
        _make_findings "$dir/pre-loop-findings.json" "$3"
    fi
    _make_findings "$dir/post-loop-findings.json" "$4"
}

# ---------------------------------------------------------------------------
# Test 1: Missing corpus dir → exit 2
# ---------------------------------------------------------------------------
_snapshot_fail
exit_code=0
bash "$DELTA_SCRIPT" --corpus-dir=/nonexistent/path 2>/dev/null || exit_code=$?
assert_eq "test_missing_corpus_dir: exit code 2" "2" "$exit_code"

# ---------------------------------------------------------------------------
# Test 2: Empty corpus (no fixtures) → exit 2
# ---------------------------------------------------------------------------
CORPUS_EMPTY="$(mktemp -d)"
trap 'rm -rf "$CORPUS_EMPTY"' EXIT
_snapshot_fail
exit_code=0
bash "$DELTA_SCRIPT" --corpus-dir="$CORPUS_EMPTY" 2>/dev/null || exit_code=$?
assert_eq "test_empty_corpus: exit code 2" "2" "$exit_code"

# ---------------------------------------------------------------------------
# Test 3: All fixtures improved (pre=0 → post>0) → exit 0, PRESENCE CHECK PASS
# ---------------------------------------------------------------------------
CORPUS_PASS="$(mktemp -d)"
trap 'rm -rf "$CORPUS_PASS"' EXIT

_make_fixture "$CORPUS_PASS" "fix-a" "" \
    '[{"severity":"important","description":"Bad pattern","cited_lines":["src/app.py:10"]}]'
_make_fixture "$CORPUS_PASS" "fix-b" "" \
    '[{"severity":"minor","description":"Typo found","cited_lines":["src/utils.py:5"]}]'

_snapshot_fail
exit_code=0
output=""
output=$(bash "$DELTA_SCRIPT" --corpus-dir="$CORPUS_PASS" 2>&1) || exit_code=$?
assert_eq "test_all_improved: exit code 0" "0" "$exit_code"
assert_contains "test_all_improved: PRESENCE PASS" "PRESENCE CHECK: PASS" "$output"

# ---------------------------------------------------------------------------
# Test 4: No fixtures improved (pre=0, post=0 for all) → exit 1, PRESENCE CHECK FAIL
# ---------------------------------------------------------------------------
CORPUS_FAIL="$(mktemp -d)"
trap 'rm -rf "$CORPUS_FAIL"' EXIT

_make_fixture "$CORPUS_FAIL" "no-grounding-a" "" \
    '[{"severity":"minor","description":"Looks bad","cited_lines":[]}]'
_make_fixture "$CORPUS_FAIL" "no-grounding-b" "" \
    '[{"severity":"minor","description":"Seems wrong","cited_lines":[]}]'

_snapshot_fail
exit_code=0
output=""
output=$(bash "$DELTA_SCRIPT" --corpus-dir="$CORPUS_FAIL" 2>&1) || exit_code=$?
assert_eq "test_none_improved: exit code 1" "1" "$exit_code"
assert_contains "test_none_improved: PRESENCE FAIL" "PRESENCE CHECK: FAIL" "$output"

# ---------------------------------------------------------------------------
# Test 5: --output flag writes valid JSON summary
# ---------------------------------------------------------------------------
CORPUS_JSON="$(mktemp -d)"
trap 'rm -rf "$CORPUS_JSON"' EXIT
OUT_JSON="$(mktemp /tmp/delta-summary.XXXXXX.json)"
trap 'rm -f "$OUT_JSON"' EXIT

_make_fixture "$CORPUS_JSON" "grounded-one" "" \
    '[{"severity":"critical","description":"Real bug","cited_lines":["main.py:42"]}]'

_snapshot_fail
bash "$DELTA_SCRIPT" --corpus-dir="$CORPUS_JSON" --output="$OUT_JSON" >/dev/null 2>&1
assert_eq "test_json_output: file exists" "0" "$(test -f "$OUT_JSON" && echo 0 || echo 1)"

json_total=""
json_total=$(python3 -c "import json; d=json.load(open('$OUT_JSON')); print(d['total_fixtures'])" 2>/dev/null) || true
assert_eq "test_json_output: total_fixtures" "1" "$json_total"

# ---------------------------------------------------------------------------
# Test 6: git rev-parse --show-toplevel portability (not relative path traversal)
# ---------------------------------------------------------------------------
# Verify the script uses git rev-parse, not cd ../../
_snapshot_fail
grep_result=0
grep -q "rev-parse --show-toplevel" "$DELTA_SCRIPT" || grep_result=$?
assert_eq "test_portability: uses git rev-parse" "0" "$grep_result"

neg_result=0
# shellcheck disable=SC2016
grep -q 'cd "$_PLUGIN_ROOT/../.."' "$DELTA_SCRIPT" && neg_result=1 || true
assert_eq "test_portability: no relative traversal" "0" "$neg_result"

# ---------------------------------------------------------------------------
# Test 7: _count_speculation does NOT hardcode inline MARKERS list
# (RED before fix: script has inline MARKERS = [...] in heredoc;
#  GREEN after fix: script imports from speculation_markers.py)
# ---------------------------------------------------------------------------
_snapshot_fail
inline_markers=0
grep -q 'MARKERS = \[' "$DELTA_SCRIPT" && inline_markers=1 || true
assert_eq "test_no_inline_markers: _count_speculation imports from module, not hardcoded" \
    "0" "$inline_markers"

# Also verify the import from speculation_markers is present in the script
import_present=0
grep -q 'speculation_markers' "$DELTA_SCRIPT" && import_present=1 || true
assert_eq "test_import_present: script references speculation_markers module" \
    "1" "$import_present"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary
