#!/usr/bin/env bash
# tests/workflows/test-review-tier-enforcement-e2e.sh
# E2E tests for review tier enforcement in record-review.sh:
#   Test 1 (SC6): Tier downgrade rejection — standard classified, light reviewed → blocked
#   Test 2 (SC7): Fail-open — no telemetry → allowed with warning + tier_verified=false
#
# Exercises the full pipeline: write-reviewer-findings.sh → record-review.sh
# in an isolated temp git repo with controlled artifacts.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"

RECORD_REVIEW="$REPO_ROOT/plugins/dso/hooks/record-review.sh"
WRITE_FINDINGS="$REPO_ROOT/plugins/dso/scripts/write-reviewer-findings.sh"

echo "=== test-review-tier-enforcement-e2e.sh ==="
echo ""

# Minimal valid findings JSON
VALID_FINDINGS_JSON='{
  "scores": {
    "hygiene": 5,
    "design": 5,
    "maintainability": 5,
    "correctness": 5,
    "verification": 5
  },
  "findings": [],
  "summary": "All code looks good, no issues found in review."
}'

# Save original dir for cleanup
ORIG_DIR="$(pwd)"

# --- Test 1: Tier downgrade rejection (SC6) ---
# Classifier selected standard, but reviewer used light → must be rejected
test_tier_downgrade_rejection() {
    _snapshot_fail

    # Create isolated temp git repo
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'cd "$ORIG_DIR"; rm -rf "$tmpdir"; unset RECORD_REVIEW_CHANGED_FILES WORKFLOW_PLUGIN_ARTIFACTS_DIR' RETURN
    cd "$tmpdir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "initial"
    echo "changed" > file.txt
    git add file.txt

    # Set up artifacts dir
    local artifacts_dir="$tmpdir/.artifacts"
    mkdir -p "$artifacts_dir"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"

    # Write classifier telemetry with selected_tier=standard
    echo '{"selected_tier":"standard","timestamp":"2026-01-01T00:00:00Z"}' \
        > "$artifacts_dir/classifier-telemetry.jsonl"

    # Use write-reviewer-findings.sh with --review-tier light to create findings
    local reviewer_hash
    reviewer_hash=$(echo "$VALID_FINDINGS_JSON" | \
        CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso" \
        bash "$WRITE_FINDINGS" --review-tier light 2>/dev/null)

    if [[ -z "$reviewer_hash" ]]; then
        (( ++FAIL ))
        printf "FAIL: write-reviewer-findings.sh did not produce a hash\n" >&2
        assert_pass_if_clean "test_tier_downgrade_rejection"
        return
    fi

    # Inject changed files for overlap check
    export RECORD_REVIEW_CHANGED_FILES="file.txt"

    # Invoke record-review.sh — should fail (non-zero exit) due to tier mismatch
    local stderr_file="$tmpdir/_stderr.txt"
    local exit_code=0
    bash "$RECORD_REVIEW" --reviewer-hash "$reviewer_hash" 2>"$stderr_file" 1>/dev/null || exit_code=$?
    local stderr_output
    stderr_output=$(cat "$stderr_file" 2>/dev/null || echo "")

    assert_ne "record-review.sh exits non-zero on tier downgrade" "0" "$exit_code"
    assert_contains "stderr mentions tier mismatch" "TIER IMMUTABILITY VIOLATION" "$stderr_output"

    assert_pass_if_clean "test_tier_downgrade_rejection"
}

# --- Test 2: Fail-open when classifier telemetry is missing (SC7) ---
# No classifier-telemetry.jsonl → review should proceed with warning + tier_verified=false
test_fail_open_no_telemetry() {
    _snapshot_fail

    # Create isolated temp git repo
    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'cd "$ORIG_DIR"; rm -rf "$tmpdir"; unset RECORD_REVIEW_CHANGED_FILES WORKFLOW_PLUGIN_ARTIFACTS_DIR' RETURN
    cd "$tmpdir"
    git init -q
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial" > file.txt
    git add file.txt
    git commit -q -m "initial"
    echo "changed" > file.txt
    git add file.txt

    # Set up artifacts dir (no classifier telemetry)
    local artifacts_dir="$tmpdir/.artifacts"
    mkdir -p "$artifacts_dir"
    export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$artifacts_dir"

    # Use write-reviewer-findings.sh with --review-tier standard
    local reviewer_hash
    reviewer_hash=$(echo "$VALID_FINDINGS_JSON" | \
        CLAUDE_PLUGIN_ROOT="$REPO_ROOT/plugins/dso" \
        bash "$WRITE_FINDINGS" --review-tier standard 2>/dev/null)

    if [[ -z "$reviewer_hash" ]]; then
        (( ++FAIL ))
        printf "FAIL: write-reviewer-findings.sh did not produce a hash\n" >&2
        assert_pass_if_clean "test_fail_open_no_telemetry"
        return
    fi

    export RECORD_REVIEW_CHANGED_FILES="file.txt"

    # Invoke record-review.sh — should succeed (exit 0) with warning on stderr
    local stderr_file="$tmpdir/_stderr.txt"
    local exit_code=0
    bash "$RECORD_REVIEW" --reviewer-hash "$reviewer_hash" 2>"$stderr_file" 1>/dev/null || exit_code=$?
    local stderr_output
    stderr_output=$(cat "$stderr_file" 2>/dev/null || echo "")

    assert_eq "record-review.sh exits 0 on fail-open (no telemetry)" "0" "$exit_code"
    assert_contains "stderr warns about missing telemetry" "cannot verify tier" "$stderr_output"

    # Verify review-status contains tier_verified=false
    local review_status_file="$artifacts_dir/review-status"
    local tier_verified_line=""
    if [[ -f "$review_status_file" ]]; then
        tier_verified_line=$(grep 'tier_verified=false' "$review_status_file" 2>/dev/null || echo "")
    fi
    assert_ne "review-status contains tier_verified=false" "" "$tier_verified_line"

    assert_pass_if_clean "test_fail_open_no_telemetry"
}

echo "--- test_tier_downgrade_rejection ---"
test_tier_downgrade_rejection
echo ""

echo "--- test_fail_open_no_telemetry ---"
test_fail_open_no_telemetry
echo ""

print_summary
