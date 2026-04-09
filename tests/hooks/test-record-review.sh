#!/usr/bin/env bash
# tests/hooks/test-record-review.sh
# Tests for hooks/record-review.sh
#
# record-review.sh reads directly from reviewer-findings.json (written by
# the code-reviewer sub-agent). It requires --reviewer-hash and validates
# the findings file's integrity and schema. No stdin JSON is accepted.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$DSO_PLUGIN_DIR/hooks/record-review.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Source deps.sh to use get_artifacts_dir()
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

# Use an isolated temp directory so tests don't clobber production artifacts.
# Export WORKFLOW_PLUGIN_ARTIFACTS_DIR so record-review.sh (via get_artifacts_dir())
# uses this dir instead of the real one. Without this, concurrent test runs
# delete the production reviewer-findings.json — the root cause of the
# "reviewer-findings.json not found" bug that blocked the commit workflow.
ARTIFACTS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-record-review-XXXXXX")
export WORKFLOW_PLUGIN_ARTIFACTS_DIR="$ARTIFACTS_DIR"
FINDINGS_FILE="$ARTIFACTS_DIR/reviewer-findings.json"

cleanup() {
    rm -f "$FINDINGS_FILE"
}
trap 'rm -rf "$ARTIFACTS_DIR"' EXIT

run_hook_exit() {
    local exit_code=0
    bash "$HOOK" "$@" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# test_record_review_exits_nonzero_without_reviewer_hash
# No --reviewer-hash → exit 1
cleanup
mkdir -p "$ARTIFACTS_DIR"
echo '{"scores":{"hygiene":5,"design":5,"maintainability":5,"correctness":5,"verification":5},"findings":[],"summary":"All checks passed. No issues found."}' > "$FINDINGS_FILE"
EXIT_CODE=$(run_hook_exit)
assert_ne "test_record_review_exits_nonzero_without_reviewer_hash" "0" "$EXIT_CODE"

# test_record_review_exits_nonzero_without_findings_file
# No reviewer-findings.json → exit 1
cleanup
EXIT_CODE=$(run_hook_exit --reviewer-hash "abc123")
assert_ne "test_record_review_exits_nonzero_without_findings_file" "0" "$EXIT_CODE"

# test_record_review_exits_nonzero_on_hash_mismatch
# Wrong hash → exit 1
cleanup
mkdir -p "$ARTIFACTS_DIR"
echo '{"scores":{"hygiene":5,"design":5,"maintainability":5,"correctness":5,"verification":5},"findings":[],"summary":"All checks passed. No issues found."}' > "$FINDINGS_FILE"
EXIT_CODE=$(run_hook_exit --reviewer-hash "0000000000000000000000000000000000000000000000000000000000000000")
assert_ne "test_record_review_exits_nonzero_on_hash_mismatch" "0" "$EXIT_CODE"

# test_record_review_exits_nonzero_on_missing_scores
# Findings file without scores → exit 1
cleanup
mkdir -p "$ARTIFACTS_DIR"
echo '{"findings":[],"summary":"Missing scores object entirely"}' > "$FINDINGS_FILE"
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
EXIT_CODE=$(run_hook_exit --reviewer-hash "$HASH")
assert_ne "test_record_review_exits_nonzero_on_missing_scores" "0" "$EXIT_CODE"

# test_record_review_exits_nonzero_on_missing_summary
# Findings file without summary → exit 1
cleanup
mkdir -p "$ARTIFACTS_DIR"
echo '{"scores":{"hygiene":5,"design":5,"maintainability":5,"correctness":5,"verification":5},"findings":[]}' > "$FINDINGS_FILE"
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
EXIT_CODE=$(run_hook_exit --reviewer-hash "$HASH")
assert_ne "test_record_review_exits_nonzero_on_missing_summary" "0" "$EXIT_CODE"

# test_record_review_exits_nonzero_on_score_out_of_range
# Score of 6 → exit 1
cleanup
mkdir -p "$ARTIFACTS_DIR"
echo '{"scores":{"hygiene":6,"design":5,"maintainability":5,"correctness":5,"verification":5},"findings":[],"summary":"Score out of range test review"}' > "$FINDINGS_FILE"
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
EXIT_CODE=$(run_hook_exit --reviewer-hash "$HASH")
assert_ne "test_record_review_exits_nonzero_on_score_out_of_range" "0" "$EXIT_CODE"

# test_record_review_drains_stdin_silently
# Piped stdin should be drained without error (backward compat)
cleanup
mkdir -p "$ARTIFACTS_DIR"
echo '{"scores":{"hygiene":5,"design":5,"maintainability":5,"correctness":5,"verification":5},"findings":[],"summary":"All checks passed. No issues found."}' > "$FINDINGS_FILE"
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
EXIT_CODE=0
echo "some old stdin json" | bash "$HOOK" --reviewer-hash "$HASH" 2>/dev/null || EXIT_CODE=$?
# Should succeed (stdin is drained, not used)
assert_eq "test_record_review_drains_stdin_silently" "0" "$EXIT_CODE"

# ============================================================
# test_record_review_portable_state_path
#
# Verify that record-review.sh writes review-status to /tmp/workflow-plugin-*/
# not /tmp/lockpick-test-artifacts-*/ .
# ============================================================

RRSTATE_TMP=$(mktemp -d)
cleanup_rrstate() { rm -rf "$RRSTATE_TMP" "$ARTIFACTS_DIR"; }
trap cleanup_rrstate EXIT

# Initialize a minimal fake git repo so get_artifacts_dir() can call git rev-parse
git -C "$RRSTATE_TMP" init --quiet 2>/dev/null || true

HOOK_PARENT_DIR="$(cd "$(dirname "$HOOK")" && pwd)"

DETECTED_STATE_DIR=""
DETECTED_STATE_DIR=$(
    cd "$RRSTATE_TMP"
    source "$HOOK_PARENT_DIR/lib/deps.sh" 2>/dev/null || true
    if declare -f get_artifacts_dir > /dev/null 2>&1; then
        REPO_ROOT="$RRSTATE_TMP" get_artifacts_dir 2>/dev/null
    else
        # Function does not yet exist — reproduce old hardcoded path so assertion fails
        WORKTREE_NAME=$(basename "$RRSTATE_TMP")
        echo "/tmp/lockpick-test-artifacts-${WORKTREE_NAME}"
    fi
) 2>/dev/null

OLD_PREFIX_FOUND_RR="no"
if [[ "$DETECTED_STATE_DIR" == *lockpick-test-artifacts* ]]; then
    OLD_PREFIX_FOUND_RR="yes"
fi

assert_eq \
    "test_record_review_portable_state_path: ARTIFACTS_DIR does not use lockpick-test-artifacts" \
    "no" \
    "$OLD_PREFIX_FOUND_RR"

# ---------------------------------------------------------------------------
# test_record_review_equals_style_reviewer_hash
# Bug dso-3v94: --reviewer-hash=VALUE (equals style) should be accepted,
# not rejected with "unknown argument".
# ---------------------------------------------------------------------------
cleanup
mkdir -p "$ARTIFACTS_DIR"
echo '{"scores":{"hygiene":5,"design":5,"maintainability":5,"correctness":5,"verification":5},"findings":[],"summary":"All checks passed. No issues found."}' > "$FINDINGS_FILE"
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
EXIT_CODE=0
bash "$HOOK" "--reviewer-hash=${HASH}" 2>/dev/null || EXIT_CODE=$?
assert_eq "test_record_review_equals_style_reviewer_hash: --reviewer-hash=VALUE accepted" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_record_review_changed_files_excludes_untracked
# Bug dso-lm92: CHANGED_FILES overlap check must not include untracked files.
# The review diff (compute-diff-hash.sh) excludes untracked files, so the
# overlap check in record-review.sh must match that scope. Including untracked
# files can cause false-positive overlap matches against files not in the
# reviewed diff.
# ---------------------------------------------------------------------------
# Check the CHANGED_FILES computation block (not the diagnostic dump which
# legitimately uses ls-files --others for mismatch forensics).
# The CHANGED_FILES block is between "CHANGED_FILES=$(" and the closing ")".
_tmp=$(sed -n '/CHANGED_FILES=$(/,/^[[:space:]]*)/p' "$HOOK"); if grep -q 'ls-files.*--others' <<< "$_tmp"; then
    actual="includes_untracked"
else
    actual="excludes_untracked"
fi
assert_eq "test_record_review_changed_files_excludes_untracked" "excludes_untracked" "$actual"

# ===========================================================================
# Tier enforcement tests
#
# record-review.sh must read classifier-telemetry.jsonl (last line) to get
# selected_tier and compare it against review_tier in reviewer-findings.json.
# Rules:
#   - Downgrade (review_tier < selected_tier) → reject (exit non-zero)
#   - Match → accept
#   - Upgrade (review_tier > selected_tier) → accept
#   - Missing telemetry file → accept with warning, tier_verified=false
#   - Missing review_tier in findings → accept with warning, tier_verified=false
# ===========================================================================

# Helper: write a valid findings file with optional review_tier and return its hash.
# Usage: _write_findings [review_tier]
_write_findings() {
    local tier="${1:-}"
    cleanup
    mkdir -p "$ARTIFACTS_DIR"
    if [[ -n "$tier" ]]; then
        cat > "$FINDINGS_FILE" <<EOFJ
{"scores":{"hygiene":5,"design":5,"maintainability":5,"correctness":5,"verification":5},"findings":[],"summary":"All checks passed. No issues found.","review_tier":"${tier}"}
EOFJ
    else
        cat > "$FINDINGS_FILE" <<EOFJ
{"scores":{"hygiene":5,"design":5,"maintainability":5,"correctness":5,"verification":5},"findings":[],"summary":"All checks passed. No issues found."}
EOFJ
    fi
    shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}'
}

# Helper: write a classifier-telemetry.jsonl with a given selected_tier.
_write_telemetry() {
    local tier="$1"
    cat > "$ARTIFACTS_DIR/classifier-telemetry.jsonl" <<EOFT
{"blast_radius":2,"critical_path":0,"anti_shortcut":0,"staleness":1,"cross_cutting":1,"diff_lines":1,"change_volume":0,"computed_total":5,"selected_tier":"${tier}","files":["foo.py"],"diff_size_lines":87,"size_action":"none","is_merge_commit":false}
EOFT
}

# ---------------------------------------------------------------------------
# test_tier_downgrade_rejected
# review_tier=light when telemetry says selected_tier=standard → exit non-zero
# ---------------------------------------------------------------------------
HASH=$(_write_findings "light")
_write_telemetry "standard"
EXIT_CODE=0
STDERR_OUT=$(bash "$HOOK" --reviewer-hash "$HASH" 2>&1 >/dev/null) || EXIT_CODE=$?
assert_ne "test_tier_downgrade_rejected: exits non-zero" "0" "$EXIT_CODE"
assert_contains "test_tier_downgrade_rejected: stderr mentions downgrade" "downgrade" "$STDERR_OUT"

# ---------------------------------------------------------------------------
# test_tier_match_accepted
# review_tier=standard when telemetry says selected_tier=standard → exit 0
# ---------------------------------------------------------------------------
HASH=$(_write_findings "standard")
_write_telemetry "standard"
EXIT_CODE=0
bash "$HOOK" --reviewer-hash "$HASH" 2>/dev/null || EXIT_CODE=$?
assert_eq "test_tier_match_accepted: exits 0" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_tier_upgrade_accepted
# review_tier=deep when telemetry says selected_tier=standard → exit 0
# ---------------------------------------------------------------------------
HASH=$(_write_findings "deep")
_write_telemetry "standard"
EXIT_CODE=0
bash "$HOOK" --reviewer-hash "$HASH" 2>/dev/null || EXIT_CODE=$?
assert_eq "test_tier_upgrade_accepted: exits 0" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_tier_missing_telemetry_fail_open
# No classifier-telemetry.jsonl → exit 0, warning on stderr, tier_verified=false
# ---------------------------------------------------------------------------
HASH=$(_write_findings "standard")
rm -f "$ARTIFACTS_DIR/classifier-telemetry.jsonl"
EXIT_CODE=0
STDERR_OUT=$(bash "$HOOK" --reviewer-hash "$HASH" 2>&1 >/dev/null) || EXIT_CODE=$?
assert_eq "test_tier_missing_telemetry_fail_open: exits 0" "0" "$EXIT_CODE"
assert_contains "test_tier_missing_telemetry_fail_open: stderr warns" "WARN" "$STDERR_OUT"
# Check tier_verified=false in review-status
REVIEW_STATUS_FILE="$ARTIFACTS_DIR/review-status"
if [[ -f "$REVIEW_STATUS_FILE" ]] && grep -q 'tier_verified=false' "$REVIEW_STATUS_FILE"; then
    TIER_VERIFIED_PRESENT="yes"
else
    TIER_VERIFIED_PRESENT="no"
fi
assert_eq "test_tier_missing_telemetry_fail_open: tier_verified=false in review-status" "yes" "$TIER_VERIFIED_PRESENT"

# ---------------------------------------------------------------------------
# test_tier_missing_review_tier_fail_open
# Missing review_tier in findings → exit 0, warning on stderr, tier_verified=false
# ---------------------------------------------------------------------------
HASH=$(_write_findings "")  # no review_tier field
_write_telemetry "standard"
EXIT_CODE=0
STDERR_OUT=$(bash "$HOOK" --reviewer-hash "$HASH" 2>&1 >/dev/null) || EXIT_CODE=$?
assert_eq "test_tier_missing_review_tier_fail_open: exits 0" "0" "$EXIT_CODE"
assert_contains "test_tier_missing_review_tier_fail_open: stderr warns" "WARN" "$STDERR_OUT"
REVIEW_STATUS_FILE="$ARTIFACTS_DIR/review-status"
if [[ -f "$REVIEW_STATUS_FILE" ]] && grep -q 'tier_verified=false' "$REVIEW_STATUS_FILE"; then
    TIER_VERIFIED_PRESENT="yes"
else
    TIER_VERIFIED_PRESENT="no"
fi
assert_eq "test_tier_missing_review_tier_fail_open: tier_verified=false in review-status" "yes" "$TIER_VERIFIED_PRESENT"

# ---------------------------------------------------------------------------
# test_fragile_severity_accepted_no_validation_error
#
# Given: reviewer-findings.json with a finding of severity "fragile" and
#        scores where min=3 (below pass threshold of 4).
# When:  record-review.sh is invoked with the correct reviewer-hash.
# Then:  The script exits 0 (fragile is a valid severity — no validation error).
#        STATUS=failed is written to review-status because min_score=3 < 4.
#
# RED: Currently exits non-zero because "fragile" is not in valid_severities
#      {'critical', 'important', 'minor'} — the severity validation rejects it.
# ---------------------------------------------------------------------------
cleanup
mkdir -p "$ARTIFACTS_DIR"
cat > "$FINDINGS_FILE" <<'EOFJ'
{"scores":{"hygiene":3,"design":3,"maintainability":3,"correctness":3,"verification":3},"findings":[{"severity":"fragile","category":"hygiene","file":"src/foo.py","description":"Fragile coupling between modules makes this brittle under change."}],"summary":"Minor issues found but overall acceptable for fragile dependencies."}
EOFJ
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
EXIT_CODE=0
# isolation-ok: inject changed files to bypass real git diff (overlap check uses RECORD_REVIEW_CHANGED_FILES when set)
STDERR_OUT=$(RECORD_REVIEW_CHANGED_FILES="src/foo.py" bash "$HOOK" --reviewer-hash "$HASH" 2>&1 >/dev/null) || EXIT_CODE=$?
assert_eq "test_fragile_severity_accepted_no_validation_error: exits 0 (fragile accepted)" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_fragile_severity_produces_failed_status
#
# Given: reviewer-findings.json with a finding of severity "fragile" and
#        min_score=3 (below pass threshold of 4).
# When:  record-review.sh runs successfully (after fragile severity is accepted).
# Then:  review-status file contains "failed" on its first line because
#        min_score=3 is below the pass threshold of 4.
#
# RED: Currently the script exits non-zero at severity validation (fragile
#      not in valid_severities), so review-status is never written from this
#      invocation. The assertion checks the first line is "failed" — if the
#      script errors out, no status file is written by this run.
# ---------------------------------------------------------------------------
cleanup
rm -f "$ARTIFACTS_DIR/review-status"
mkdir -p "$ARTIFACTS_DIR"
cat > "$FINDINGS_FILE" <<'EOFJ'
{"scores":{"hygiene":3,"design":3,"maintainability":3,"correctness":3,"verification":3},"findings":[{"severity":"fragile","category":"hygiene","file":"src/foo.py","description":"Fragile coupling between modules makes this brittle under change."}],"summary":"Minor issues found but overall acceptable for fragile dependencies."}
EOFJ
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
# isolation-ok: inject changed files to bypass real git diff (overlap check uses RECORD_REVIEW_CHANGED_FILES when set)
RECORD_REVIEW_CHANGED_FILES="src/foo.py" bash "$HOOK" --reviewer-hash "$HASH" 2>/dev/null || true
REVIEW_STATUS_FILE="$ARTIFACTS_DIR/review-status"
if [[ -f "$REVIEW_STATUS_FILE" ]]; then
    FIRST_LINE=$(head -1 "$REVIEW_STATUS_FILE")
else
    FIRST_LINE="not_written"
fi
assert_eq "test_fragile_severity_produces_failed_status: review-status first line is 'failed'" "failed" "$FIRST_LINE"

print_summary
