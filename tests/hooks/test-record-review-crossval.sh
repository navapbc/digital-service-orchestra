#!/usr/bin/env bash
# tests/hooks/test-record-review-crossval.sh
# Integration tests for record-review.sh.
#
# Tests the validation logic that reads scores, summary, and findings directly
# from reviewer-findings.json (no stdin JSON is accepted).
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
        echo "$output" | grep -q "$expected_pattern" && pattern_match=1
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
write_findings '{"scores":{"code_hygiene":5,"object_oriented_design":"N/A","readability":"N/A","functionality":5,"testing_coverage":"N/A"},"findings":[],"summary":"All checks passed no issues found"}' > /dev/null
run_test "Rejects when --reviewer-hash is omitted" 1 "reviewer-hash is required"

# --- Test 3: Hash mismatch ---
echo "Test group: Hash mismatch"
write_findings '{"scores":{"code_hygiene":5,"object_oriented_design":"N/A","readability":"N/A","functionality":5,"testing_coverage":"N/A"},"findings":[],"summary":"All checks passed no issues found"}' > /dev/null
run_test "Rejects when hash doesn't match" 1 "hash mismatch" \
    --reviewer-hash "0000000000000000000000000000000000000000000000000000000000000000"

# --- Test 4: Happy path (all passing) ---
echo "Test group: Happy path"
HASH=$(write_findings '{"scores":{"code_hygiene":5,"object_oriented_design":"N/A","readability":"N/A","functionality":5,"testing_coverage":"N/A"},"findings":[],"summary":"All checks passed no issues found"}')
run_test "Accepts valid findings with matching hash (passed)" 0 "passed" \
    --reviewer-hash "$HASH"

# --- Test 5: Critical finding correctly fails ---
echo "Test group: Critical/important findings"
HASH=$(write_findings "{\"scores\":{\"code_hygiene\":\"N/A\",\"object_oriented_design\":\"N/A\",\"readability\":\"N/A\",\"functionality\":2,\"testing_coverage\":\"N/A\"},\"findings\":[{\"severity\":\"critical\",\"category\":\"functionality\",\"description\":\"SQL injection\",\"file\":\"$SENTINEL_BASENAME\"}],\"summary\":\"Critical security issue found\"}")
run_test "Records as failed when reviewer score < 4 (critical finding)" 0 "failed" \
    --reviewer-hash "$HASH"

# --- Test 6: Important finding correctly fails ---
HASH=$(write_findings "{\"scores\":{\"code_hygiene\":\"N/A\",\"object_oriented_design\":\"N/A\",\"readability\":\"N/A\",\"functionality\":3,\"testing_coverage\":\"N/A\"},\"findings\":[{\"severity\":\"important\",\"category\":\"functionality\",\"description\":\"Missing error handling\",\"file\":\"$SENTINEL_BASENAME\"}],\"summary\":\"Important issue found in code\"}")
run_test "Records as failed when reviewer score = 3 (important finding)" 0 "failed" \
    --reviewer-hash "$HASH"

# --- Test 7: Critical finding with inconsistent score ---
echo "Test group: Score/finding inconsistency"
HASH=$(write_findings "{\"scores\":{\"code_hygiene\":\"N/A\",\"object_oriented_design\":\"N/A\",\"readability\":\"N/A\",\"functionality\":5,\"testing_coverage\":\"N/A\"},\"findings\":[{\"severity\":\"critical\",\"category\":\"functionality\",\"description\":\"Bug\",\"file\":\"$SENTINEL_BASENAME\"}],\"summary\":\"Has critical but score is 5\"}")
run_test "Rejects critical finding with score > 2" 1 "critical issue" \
    --reviewer-hash "$HASH"

# --- Test 8: Important finding with score = 4 (allowed — important does not constrain score) ---
# record-review.sh only cross-validates critical findings against scores (score must be 1-2).
# Important findings are recorded and may coexist with scores up to 5 (reviewer uses judgment).
HASH=$(write_findings "{\"scores\":{\"code_hygiene\":\"N/A\",\"object_oriented_design\":\"N/A\",\"readability\":\"N/A\",\"functionality\":4,\"testing_coverage\":\"N/A\"},\"findings\":[{\"severity\":\"important\",\"category\":\"functionality\",\"description\":\"Issue\",\"file\":\"$SENTINEL_BASENAME\"}],\"summary\":\"Has important but score is 4\"}")
run_test "Allows important finding with score = 4 (important does not constrain score)" 0 "passed" \
    --reviewer-hash "$HASH"

# --- Test 9: Invalid category ---
echo "Test group: Invalid categories"
HASH=$(write_findings "{\"scores\":{\"code_hygiene\":5,\"object_oriented_design\":\"N/A\",\"readability\":\"N/A\",\"functionality\":5,\"testing_coverage\":\"N/A\"},\"findings\":[{\"severity\":\"critical\",\"category\":\"performance\",\"description\":\"Slow\",\"file\":\"$SENTINEL_BASENAME\"}],\"summary\":\"Performance issue in review\"}")
run_test "Rejects finding with invalid category" 1 "invalid category" \
    --reviewer-hash "$HASH"

# --- Test 10: Invalid severity ---
echo "Test group: Invalid severity"
HASH=$(write_findings "{\"scores\":{\"code_hygiene\":5,\"object_oriented_design\":\"N/A\",\"readability\":\"N/A\",\"functionality\":5,\"testing_coverage\":\"N/A\"},\"findings\":[{\"severity\":\"high\",\"category\":\"functionality\",\"description\":\"Issue\",\"file\":\"$SENTINEL_BASENAME\"}],\"summary\":\"Invalid severity in finding\"}")
run_test "Rejects finding with invalid severity" 1 "invalid severity" \
    --reviewer-hash "$HASH"

# --- Test 11: Low score with no findings (potential fabrication) ---
echo "Test group: Low score no findings"
HASH=$(write_findings '{"scores":{"code_hygiene":"N/A","object_oriented_design":"N/A","readability":"N/A","functionality":5,"testing_coverage":"N/A"},"findings":[],"summary":"Clean review no issues found"}')
run_test "Accepts low-dimension score with no findings (legitimate)" 0 "passed" \
    --reviewer-hash "$HASH"

# --- Test 12: Missing score dimension in reviewer file ---
echo "Test group: Missing dimensions"
HASH=$(write_findings '{"scores":{"code_hygiene":5,"functionality":5},"findings":[],"summary":"Missing dimensions in scores"}')
run_test "Rejects reviewer file missing score dimensions" 1 "missing score dimension" \
    --reviewer-hash "$HASH"

# --- Test 13: Invalid score value in reviewer file ---
echo "Test group: Invalid score values"
HASH=$(write_findings '{"scores":{"code_hygiene":6,"object_oriented_design":"N/A","readability":"N/A","functionality":5,"testing_coverage":"N/A"},"findings":[],"summary":"Score out of range review"}')
run_test "Rejects reviewer score out of range (6)" 1 "must be 1-5" \
    --reviewer-hash "$HASH"

# --- Test 14: Missing summary in findings file ---
echo "Test group: Missing summary"
HASH=$(write_findings '{"scores":{"code_hygiene":5,"object_oriented_design":5,"readability":5,"functionality":5,"testing_coverage":5},"findings":[]}')
run_test "Rejects findings file with missing summary" 1 "missing or too short summary" \
    --reviewer-hash "$HASH"

# --- Test 15: Short summary in findings file ---
HASH=$(write_findings '{"scores":{"code_hygiene":5,"object_oriented_design":5,"readability":5,"functionality":5,"testing_coverage":5},"findings":[],"summary":"short"}')
run_test "Rejects findings file with too-short summary" 1 "missing or too short summary" \
    --reviewer-hash "$HASH"

# --- Cleanup ---
cleanup

echo ""
printf "PASSED: %d  FAILED: %d  TOTAL: %d\n" "$PASS" "$FAIL" "$TOTAL"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
