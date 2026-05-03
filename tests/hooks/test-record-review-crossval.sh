#!/usr/bin/env bash
# tests/hooks/test-record-review-crossval.sh
# Integration tests for record-review.sh.
#
# Tests the validation logic that reads findings and summary directly
# from reviewer-findings.json (2-key schema: no scores key).
# Cross-validation between scores and severities no longer applies —
# the schema change removes scores entirely.
#
# Usage:
#   ./tests/hooks/test-record-review-crossval.sh
#
# Must be run from within a git repository (uses git rev-parse).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
SCRIPT_UNDER_TEST="$DSO_PLUGIN_DIR/hooks/record-review.sh"

# Source deps.sh so we use the same get_artifacts_dir() as the hook does at runtime.
# shellcheck source=../../../hooks/lib/deps.sh
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

# Use an isolated temp directory so tests don't clobber production artifacts.
# Export WORKFLOW_PLUGIN_ARTIFACTS_DIR so record-review.sh (via get_artifacts_dir())
# uses this dir instead of the real one. Without this, concurrent test runs
# delete the production reviewer-findings.json — the root cause of the
# "reviewer-findings.json not found" bug that blocked the commit workflow.
ARTIFACTS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-record-review-crossval-XXXXXX")
export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_DIR"  # isolation-ok: test overrides hook artifact dir
FINDINGS_FILE="$ARTIFACTS_DIR/reviewer-findings.json"

PASS=0
FAIL=0
TOTAL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Use a synthetic filename for the overlap check instead of writing to the repo.
# record-review.sh accepts RECORD_REVIEW_CHANGED_FILES to inject changed files
# without creating untracked files in the working tree.
SENTINEL_BASENAME="test-overlap-target.sh"
export RECORD_REVIEW_CHANGED_FILES="$SENTINEL_BASENAME"  # isolation-ok: test injects overlap target without writing to repo

cleanup() {
    rm -f "$FINDINGS_FILE"
}

cleanup_all() {
    rm -rf "$ARTIFACTS_DIR"
}
trap cleanup_all EXIT

# Helper: write a reviewer findings file and compute its hash.
# Findings that need to overlap with changed files should include
# the sentinel file in their "file" fields.
write_findings() {
    local json="$1"
    mkdir -p "$ARTIFACTS_DIR"
    echo "$json" > "$FINDINGS_FILE"
    shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}'
}

run_test() {
    local name="$1"
    local expected_exit="$2"  # 0 for success, 1 for failure
    local expected_pattern="$3"  # grep pattern to match in output (stdout+stderr)
    shift 3
    # Remaining args are passed to record-review.sh

    TOTAL=$((TOTAL + 1))
    local output
    local actual_exit=0

    output=$("$SCRIPT_UNDER_TEST" "$@" 2>&1) || actual_exit=$?

    local pattern_match=0
    if [[ -n "$expected_pattern" ]]; then
        _tmp="$output"; [[ "$_tmp" =~ $expected_pattern ]] && pattern_match=1
    else
        pattern_match=1  # No pattern to match
    fi

    if [[ "$actual_exit" -eq "$expected_exit" && "$pattern_match" -eq 1 ]]; then
        echo -e "  ${GREEN}PASS${NC}: $name"
        PASS=$((PASS + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $name"
        echo "    Expected exit=$expected_exit, got exit=$actual_exit"
        if [[ -n "$expected_pattern" && "$pattern_match" -eq 0 ]]; then
            echo "    Expected pattern '$expected_pattern' not found in output:"
            echo "    $output"
        fi
        FAIL=$((FAIL + 1))
    fi
}

echo "=== record-review.sh cross-validation tests ==="
echo ""

# --- Test 1: Missing findings file ---
echo "Test group: Missing findings file"
cleanup
run_test "Rejects when reviewer-findings.json is missing" 1 "reviewer-findings.json not found" \
    --reviewer-hash "abc123"

# --- Test 2: Missing --reviewer-hash ---
echo "Test group: Missing --reviewer-hash"
write_findings '{"findings":[],"summary":"All checks passed no issues found"}' > /dev/null
run_test "Rejects when --reviewer-hash is omitted" 1 "reviewer-hash is required"

# --- Test 3: Hash mismatch ---
echo "Test group: Hash mismatch"
write_findings '{"findings":[],"summary":"All checks passed no issues found"}' > /dev/null
run_test "Rejects when hash doesn't match" 1 "hash mismatch" \
    --reviewer-hash "0000000000000000000000000000000000000000000000000000000000000000"

# --- Test 4+: Schema v2 tests (2-key schema: findings + summary only) ---
# RED zone boundary: the tests below assert behavior that requires the 2-key schema
# implementation which is not yet in record-review.sh. These tests are intentionally
# failing until record-review.sh is updated in story 6c75-cc5d.
echo "=== test_schema_v2_red_zone_boundary ==="
# Sentinel: serves as RED zone start marker for the pre-commit test gate
# All tests at/after this echo are RED (expected failures until implementation lands).

echo "Test group: Happy path"
HASH=$(write_findings '{"findings":[],"summary":"All checks passed no issues found"}')
run_test "Accepts valid 2-key findings with matching hash (passed)" 0 "passed" \
    --reviewer-hash "$HASH"

# --- Test 5: Critical finding produces failed status ---
echo "Test group: Critical/important findings"
HASH=$(write_findings "{\"findings\":[{\"severity\":\"critical\",\"category\":\"correctness\",\"description\":\"SQL injection\",\"file\":\"$SENTINEL_BASENAME\"}],\"summary\":\"Critical security issue found\"}")
run_test "Records as failed when critical finding present" 0 "failed" \
    --reviewer-hash "$HASH"

# --- Test 6: Important finding produces failed status ---
HASH=$(write_findings "{\"findings\":[{\"severity\":\"important\",\"category\":\"correctness\",\"description\":\"Missing error handling\",\"file\":\"$SENTINEL_BASENAME\"}],\"summary\":\"Important issue found in code\"}")
run_test "Records as failed when important finding present" 0 "failed" \
    --reviewer-hash "$HASH"

# --- Test 7: No cross-validation — critical finding with no score key is accepted ---
echo "Test group: No score cross-validation (2-key schema)"
# test_no_score_crossval_required
# Given: 2-key findings.json with critical finding (no scores key)
# When: record-review.sh runs
# Then: exits 0 (no cross-validation error from missing scores)
HASH=$(write_findings "{\"findings\":[{\"severity\":\"critical\",\"category\":\"correctness\",\"description\":\"Bug\",\"file\":\"$SENTINEL_BASENAME\"}],\"summary\":\"Has critical but no scores key\"}")
run_test "test_no_score_crossval_required: accepts critical finding without scores key (no cross-validation)" 0 "" \
    --reviewer-hash "$HASH"

# --- Test 8: Minor finding with no score produces passed status ---
# No scores to constrain — minor finding alone → passed
HASH=$(write_findings "{\"findings\":[{\"severity\":\"minor\",\"category\":\"correctness\",\"description\":\"Nit\",\"file\":\"$SENTINEL_BASENAME\"}],\"summary\":\"Has minor finding only\"}")
run_test "Allows minor finding with 2-key schema (passed)" 0 "passed" \
    --reviewer-hash "$HASH"

# --- Test 9: Invalid category ---
echo "Test group: Invalid categories"
HASH=$(write_findings "{\"findings\":[{\"severity\":\"critical\",\"category\":\"performance\",\"description\":\"Slow\",\"file\":\"$SENTINEL_BASENAME\"}],\"summary\":\"Performance issue in review\"}")
run_test "Rejects finding with invalid category" 1 "invalid category" \
    --reviewer-hash "$HASH"

# --- Test 10: Invalid severity ---
echo "Test group: Invalid severity"
HASH=$(write_findings "{\"findings\":[{\"severity\":\"high\",\"category\":\"correctness\",\"description\":\"Issue\",\"file\":\"$SENTINEL_BASENAME\"}],\"summary\":\"Invalid severity in finding\"}")
run_test "Rejects finding with invalid severity" 1 "invalid severity" \
    --reviewer-hash "$HASH"

# --- Test 11: Empty findings (legitimate) ---
echo "Test group: Empty findings"
HASH=$(write_findings '{"findings":[],"summary":"Clean review no issues found"}')
run_test "Accepts 2-key findings with empty findings array (legitimate)" 0 "passed" \
    --reviewer-hash "$HASH"

# --- Test 12: Missing summary in findings file ---
echo "Test group: Missing summary"
HASH=$(write_findings '{"findings":[]}')
run_test "Rejects findings file with missing summary" 1 "missing or too short summary" \
    --reviewer-hash "$HASH"

# --- Test 13: Short summary in findings file ---
HASH=$(write_findings '{"findings":[],"summary":"short"}')
run_test "Rejects findings file with too-short summary" 1 "missing or too short summary" \
    --reviewer-hash "$HASH"

# --- Cleanup ---
cleanup

echo ""
printf "PASSED: %d  FAILED: %d  TOTAL: %d\n" "$PASS" "$FAIL" "$TOTAL"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
