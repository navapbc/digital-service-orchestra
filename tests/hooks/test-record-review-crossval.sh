#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-record-review-crossval.sh
# Integration tests for the reviewer findings cross-validation in record-review.sh.
#
# Tests the new cross-validation logic that reads scores from reviewer-findings.json
# instead of trusting the orchestrator's JSON.
#
# Usage:
#   ./lockpick-workflow/tests/hooks/test-record-review-crossval.sh
#
# Must be run from within a git repository (uses git rev-parse).

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel 2>/dev/null)
SCRIPT_UNDER_TEST="$REPO_ROOT/lockpick-workflow/hooks/record-review.sh"

# Source deps.sh so we use the same get_artifacts_dir() as the hook does at runtime.
# shellcheck source=../../../lockpick-workflow/hooks/lib/deps.sh
source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"
ARTIFACTS_DIR=$(get_artifacts_dir)
FINDINGS_FILE="$ARTIFACTS_DIR/reviewer-findings.json"

PASS=0
FAIL=0
TOTAL=0

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m' # No Color

# Create a temp untracked file in the repo so files_targeted always overlaps with
# the git diff regardless of the worktree's current state. The file is cleaned up on exit.
# NOTE: Do NOT use a .tmp extension — *.tmp is gitignored and won't appear in
# git ls-files --others, breaking the overlap check in record-review.sh.
SENTINEL_FILE="$REPO_ROOT/.crossval-test-sentinel-$$.marker"
touch "$SENTINEL_FILE"
SENTINEL_BASENAME=$(basename "$SENTINEL_FILE")

cleanup() {
    rm -f "$FINDINGS_FILE"
    # Re-create sentinel after cleanup so it stays present for overlap checks.
    # The EXIT trap (cleanup_all) removes it finally at script exit.
    touch "$SENTINEL_FILE"
}

cleanup_all() {
    rm -f "$FINDINGS_FILE"
    rm -f "$SENTINEL_FILE"
}
trap cleanup_all EXIT

# Helper: write a reviewer findings file and compute its hash
write_findings() {
    local json="$1"
    mkdir -p "$ARTIFACTS_DIR"
    echo "$json" > "$FINDINGS_FILE"
    shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}'
}

# Helper: create a valid orchestrator JSON (scores are N/A, as per relay rules).
# files_targeted points at the sentinel file so the overlap check always passes —
# record-review.sh checks whether changed files overlap with files_targeted, and
# the sentinel is always untracked/changed regardless of worktree state.
orchestrator_json() {
    cat <<EOF
{
  "scores": {
    "code_hygiene": "N/A",
    "object_oriented_design": "N/A",
    "readability": "N/A",
    "functionality": "N/A",
    "testing_coverage": "N/A"
  },
  "feedback": {
    "code_hygiene": "All checks passed",
    "object_oriented_design": null,
    "readability": null,
    "functionality": null,
    "testing_coverage": null,
    "files_targeted": ["$SENTINEL_BASENAME"]
  },
  "summary": "All checks passed. No issues found in the code review."
}
EOF
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

    output=$(orchestrator_json | "$SCRIPT_UNDER_TEST" "$@" 2>&1) || actual_exit=$?

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
write_findings '{"scores":{"code_hygiene":5,"object_oriented_design":"N/A","readability":"N/A","functionality":5,"testing_coverage":"N/A"},"findings":[],"summary":"ok"}' > /dev/null
run_test "Rejects when --reviewer-hash is omitted" 1 "reviewer-hash is required"

# --- Test 3: Hash mismatch ---
echo "Test group: Hash mismatch"
write_findings '{"scores":{"code_hygiene":5,"object_oriented_design":"N/A","readability":"N/A","functionality":5,"testing_coverage":"N/A"},"findings":[],"summary":"ok"}' > /dev/null
run_test "Rejects when hash doesn't match" 1 "hash mismatch" \
    --reviewer-hash "0000000000000000000000000000000000000000000000000000000000000000"

# --- Test 4: Happy path (all passing) ---
echo "Test group: Happy path"
HASH=$(write_findings '{"scores":{"code_hygiene":5,"object_oriented_design":"N/A","readability":"N/A","functionality":5,"testing_coverage":"N/A"},"findings":[],"summary":"ok"}')
run_test "Accepts valid findings with matching hash (passed)" 0 "passed" \
    --reviewer-hash "$HASH"

# --- Test 5: Critical finding correctly fails ---
echo "Test group: Critical/important findings"
HASH=$(write_findings '{"scores":{"code_hygiene":"N/A","object_oriented_design":"N/A","readability":"N/A","functionality":2,"testing_coverage":"N/A"},"findings":[{"severity":"critical","category":"functionality","description":"SQL injection","file":"foo.py"}],"summary":"Critical security issue found"}')
run_test "Records as failed when reviewer score < 4 (critical finding)" 0 "failed" \
    --reviewer-hash "$HASH"

# --- Test 6: Important finding correctly fails ---
HASH=$(write_findings '{"scores":{"code_hygiene":"N/A","object_oriented_design":"N/A","readability":"N/A","functionality":3,"testing_coverage":"N/A"},"findings":[{"severity":"important","category":"functionality","description":"Missing error handling","file":"bar.py"}],"summary":"Important issue found"}')
run_test "Records as failed when reviewer score = 3 (important finding)" 0 "failed" \
    --reviewer-hash "$HASH"

# --- Test 7: Critical finding with inconsistent score ---
echo "Test group: Score/finding inconsistency"
HASH=$(write_findings '{"scores":{"code_hygiene":"N/A","object_oriented_design":"N/A","readability":"N/A","functionality":5,"testing_coverage":"N/A"},"findings":[{"severity":"critical","category":"functionality","description":"Bug","file":"foo.py"}],"summary":"Has critical but score is 5"}')
run_test "Rejects critical finding with score > 2" 1 "critical issue" \
    --reviewer-hash "$HASH"

# --- Test 8: Important finding with score = 4 (allowed — important does not constrain score) ---
# record-review.sh only cross-validates critical findings against scores (score must be 1-2).
# Important findings are recorded and may coexist with scores up to 5 (reviewer uses judgment).
HASH=$(write_findings '{"scores":{"code_hygiene":"N/A","object_oriented_design":"N/A","readability":"N/A","functionality":4,"testing_coverage":"N/A"},"findings":[{"severity":"important","category":"functionality","description":"Issue","file":"foo.py"}],"summary":"Has important but score is 4"}')
run_test "Allows important finding with score = 4 (important does not constrain score)" 0 "passed" \
    --reviewer-hash "$HASH"

# --- Test 9: Invalid category ---
echo "Test group: Invalid categories"
HASH=$(write_findings '{"scores":{"code_hygiene":5,"object_oriented_design":"N/A","readability":"N/A","functionality":5,"testing_coverage":"N/A"},"findings":[{"severity":"critical","category":"performance","description":"Slow","file":"foo.py"}],"summary":"Performance issue"}')
run_test "Rejects finding with invalid category" 1 "invalid category" \
    --reviewer-hash "$HASH"

# --- Test 10: Invalid severity ---
echo "Test group: Invalid severity"
HASH=$(write_findings '{"scores":{"code_hygiene":5,"object_oriented_design":"N/A","readability":"N/A","functionality":5,"testing_coverage":"N/A"},"findings":[{"severity":"high","category":"functionality","description":"Issue","file":"foo.py"}],"summary":"Invalid severity"}')
run_test "Rejects finding with invalid severity" 1 "invalid severity" \
    --reviewer-hash "$HASH"

# --- Test 11: Low score with no findings (potential fabrication) ---
echo "Test group: Low score no findings"
HASH=$(write_findings '{"scores":{"code_hygiene":"N/A","object_oriented_design":"N/A","readability":"N/A","functionality":5,"testing_coverage":"N/A"},"findings":[],"summary":"Clean review, no issues"}')
run_test "Accepts low-dimension score with no findings (legitimate)" 0 "passed" \
    --reviewer-hash "$HASH"

# --- Test 12: Missing score dimension in reviewer file ---
echo "Test group: Missing dimensions"
HASH=$(write_findings '{"scores":{"code_hygiene":5,"functionality":5},"findings":[],"summary":"Missing dimensions"}')
run_test "Rejects reviewer file missing score dimensions" 1 "missing score dimension" \
    --reviewer-hash "$HASH"

# --- Test 13: Invalid score value in reviewer file ---
echo "Test group: Invalid score values"
HASH=$(write_findings '{"scores":{"code_hygiene":6,"object_oriented_design":"N/A","readability":"N/A","functionality":5,"testing_coverage":"N/A"},"findings":[],"summary":"Score out of range"}')
run_test "Rejects reviewer score out of range (6)" 1 "must be 1-5" \
    --reviewer-hash "$HASH"

# --- Cleanup ---
cleanup

echo ""
printf "PASSED: %d  FAILED: %d  TOTAL: %d\n" "$PASS" "$FAIL" "$TOTAL"

if [[ $FAIL -gt 0 ]]; then
    exit 1
fi
