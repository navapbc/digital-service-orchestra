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
echo '{"findings":[],"summary":"All checks passed. No issues found."}' > "$FINDINGS_FILE"
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
echo '{"findings":[],"summary":"All checks passed. No issues found."}' > "$FINDINGS_FILE"
EXIT_CODE=$(run_hook_exit --reviewer-hash "0000000000000000000000000000000000000000000000000000000000000000")
assert_ne "test_record_review_exits_nonzero_on_hash_mismatch" "0" "$EXIT_CODE"

# test_record_review_accepts_two_key_schema
# Findings file with 2-key schema (findings + summary, no scores) → exit 0
cleanup
mkdir -p "$ARTIFACTS_DIR"
echo '{"findings":[],"summary":"All checks passed. No issues found."}' > "$FINDINGS_FILE"
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
EXIT_CODE=$(run_hook_exit --reviewer-hash "$HASH")
assert_eq "test_record_review_accepts_two_key_schema" "0" "$EXIT_CODE"

# test_record_review_exits_nonzero_on_missing_summary
# Findings file without summary → exit 1
cleanup
mkdir -p "$ARTIFACTS_DIR"
echo '{"findings":[]}' > "$FINDINGS_FILE"
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
EXIT_CODE=$(run_hook_exit --reviewer-hash "$HASH")
assert_ne "test_record_review_exits_nonzero_on_missing_summary" "0" "$EXIT_CODE"

# test_record_review_drains_stdin_silently
# Piped stdin should be drained without error (backward compat)
cleanup
mkdir -p "$ARTIFACTS_DIR"
echo '{"findings":[],"summary":"All checks passed. No issues found."}' > "$FINDINGS_FILE"
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
    cd "$RRSTATE_TMP" || exit
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
echo '{"findings":[],"summary":"All checks passed. No issues found."}' > "$FINDINGS_FILE"
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
# shellcheck disable=SC2016  # single-quoted sed pattern is intentional: $( is a literal string, not expansion
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
{"findings":[],"summary":"All checks passed. No issues found.","review_tier":"${tier}"}
EOFJ
    else
        cat > "$FINDINGS_FILE" <<EOFJ
{"findings":[],"summary":"All checks passed. No issues found."}
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
# test_tier_telemetry_filtered_by_diff_hash
# Regression: when classifier-telemetry.jsonl contains a stale record from a
# prior /dso:review run on a different diff (older diff_hash, higher tier) AND
# a current record matching the present diff_hash (lower tier), record-review.sh
# MUST select the current diff_hash's record — not bare `tail -1`. Without this
# filter, the stale tail record would falsely trigger TIER IMMUTABILITY VIOLATION.
# ---------------------------------------------------------------------------
HASH=$(_write_findings "standard")
CURRENT_DIFF_HASH=$(bash "$DSO_PLUGIN_DIR/hooks/compute-diff-hash.sh" 2>/dev/null)
cat > "$ARTIFACTS_DIR/classifier-telemetry.jsonl" <<EOFT
{"diff_hash":"deadbeef00000000000000000000000000000000000000000000000000000000","selected_tier":"standard","blast_radius":2,"critical_path":0,"anti_shortcut":0,"staleness":1,"cross_cutting":1,"diff_lines":1,"change_volume":0,"computed_total":5,"diff_size_lines":87,"size_action":"none","is_merge_commit":false}
{"diff_hash":"${CURRENT_DIFF_HASH}","selected_tier":"standard","blast_radius":2,"critical_path":0,"anti_shortcut":0,"staleness":1,"cross_cutting":1,"diff_lines":1,"change_volume":0,"computed_total":5,"diff_size_lines":87,"size_action":"none","is_merge_commit":false}
{"diff_hash":"cafebabe00000000000000000000000000000000000000000000000000000000","selected_tier":"deep","blast_radius":2,"critical_path":0,"anti_shortcut":0,"staleness":1,"cross_cutting":1,"diff_lines":1,"change_volume":0,"computed_total":5,"diff_size_lines":87,"size_action":"none","is_merge_commit":false}
EOFT
EXIT_CODE=0
bash "$HOOK" --reviewer-hash "$HASH" 2>/dev/null || EXIT_CODE=$?
assert_eq "test_tier_telemetry_filtered_by_diff_hash: exits 0 when current record matches review_tier" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_tier_telemetry_legacy_records_fall_back_to_tail
# Backward compat: when no record carries diff_hash (legacy telemetry from
# before review-complexity-classifier.sh embedded the field), the implementation
# falls back to last-record selection.
# ---------------------------------------------------------------------------
HASH=$(_write_findings "standard")
_write_telemetry "standard"  # writes a single legacy record without diff_hash
EXIT_CODE=0
bash "$HOOK" --reviewer-hash "$HASH" 2>/dev/null || EXIT_CODE=$?
assert_eq "test_tier_telemetry_legacy_records_fall_back_to_tail: exits 0 on legacy record" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# Tier verification via findings.selected_tier (bug 21d7-b84a)
#
# record-review.sh should prefer selected_tier embedded in reviewer-findings.json
# over classifier-telemetry.jsonl. This closes the artifacts-dir split under
# worktree dispatch where telemetry lands in a different dir than findings.
# ---------------------------------------------------------------------------

# Helper: write findings with both review_tier AND selected_tier fields.
_write_findings_with_selected() {
    local review_tier="$1" selected_tier="$2"
    cleanup
    mkdir -p "$ARTIFACTS_DIR"
    cat > "$FINDINGS_FILE" <<EOFJ
{"findings":[],"summary":"All checks passed. No issues found.","review_tier":"${review_tier}","selected_tier":"${selected_tier}"}
EOFJ
    shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}'
}

# test_tier_verified_from_findings_no_telemetry
# findings.selected_tier=standard, review_tier=standard, NO telemetry file →
# exit 0, NO tier_verified=false line (tier was verified via findings).
HASH=$(_write_findings_with_selected "standard" "standard")
rm -f "$ARTIFACTS_DIR/classifier-telemetry.jsonl"
EXIT_CODE=0
STDERR_OUT=$(bash "$HOOK" --reviewer-hash "$HASH" 2>&1 >/dev/null) || EXIT_CODE=$?
assert_eq "test_tier_verified_from_findings_no_telemetry: exits 0" "0" "$EXIT_CODE"
REVIEW_STATUS_FILE="$ARTIFACTS_DIR/review-status"
if [[ -f "$REVIEW_STATUS_FILE" ]] && grep -q 'tier_verified=false' "$REVIEW_STATUS_FILE"; then
    TIER_VERIFIED_PRESENT="yes"
else
    TIER_VERIFIED_PRESENT="no"
fi
assert_eq "test_tier_verified_from_findings_no_telemetry: tier_verified=false absent" "no" "$TIER_VERIFIED_PRESENT"

# test_tier_downgrade_rejected_via_findings
# findings.review_tier=light, findings.selected_tier=standard, NO telemetry →
# exit non-zero (downgrade detected via findings path).
HASH=$(_write_findings_with_selected "light" "standard")
rm -f "$ARTIFACTS_DIR/classifier-telemetry.jsonl"
EXIT_CODE=0
STDERR_OUT=$(bash "$HOOK" --reviewer-hash "$HASH" 2>&1 >/dev/null) || EXIT_CODE=$?
assert_ne "test_tier_downgrade_rejected_via_findings: exits non-zero" "0" "$EXIT_CODE"
assert_contains "test_tier_downgrade_rejected_via_findings: stderr mentions downgrade" "downgrade" "$STDERR_OUT"

# test_tier_findings_preferred_over_telemetry
# findings.selected_tier=deep (requires deep review), review_tier=standard,
# telemetry says selected_tier=standard. Findings wins → reject downgrade.
HASH=$(_write_findings_with_selected "standard" "deep")
_write_telemetry "standard"
EXIT_CODE=0
STDERR_OUT=$(bash "$HOOK" --reviewer-hash "$HASH" 2>&1 >/dev/null) || EXIT_CODE=$?
assert_ne "test_tier_findings_preferred_over_telemetry: exits non-zero" "0" "$EXIT_CODE"
assert_contains "test_tier_findings_preferred_over_telemetry: stderr names findings source" "findings" "$STDERR_OUT"

# test_tier_max_rank_prevents_agent_self_downgrade
# Attack vector: a compromised or prompt-injected reviewer could self-declare
# findings.selected_tier=light to escape a classifier-issued deep tier. With
# max(rank) precedence, telemetry's higher tier wins and the downgrade is rejected.
# findings.review_tier=light, findings.selected_tier=light, telemetry.selected_tier=deep →
# exit non-zero (max uses deep from telemetry, rejecting the light review).
HASH=$(_write_findings_with_selected "light" "light")
_write_telemetry "deep"
EXIT_CODE=0
STDERR_OUT=$(bash "$HOOK" --reviewer-hash "$HASH" 2>&1 >/dev/null) || EXIT_CODE=$?
assert_ne "test_tier_max_rank_prevents_agent_self_downgrade: exits non-zero" "0" "$EXIT_CODE"
assert_contains "test_tier_max_rank_prevents_agent_self_downgrade: stderr names telemetry(max) source" "telemetry(max)" "$STDERR_OUT"

# ---------------------------------------------------------------------------
# test_fragile_severity_accepted_no_validation_error
#
# Given: reviewer-findings.json with a finding of severity "fragile" (2-key schema).
# When:  record-review.sh is invoked with the correct reviewer-hash.
# Then:  The script exits 0 (fragile is a valid severity — no validation error).
#        STATUS=failed is written to review-status because fragile is a blocking severity.
#
# RED: Currently exits non-zero because "fragile" is not in valid_severities
#      {'critical', 'important', 'minor'} — the severity validation rejects it.
# ---------------------------------------------------------------------------
cleanup
mkdir -p "$ARTIFACTS_DIR"
cat > "$FINDINGS_FILE" <<'EOFJ'
{"findings":[{"severity":"fragile","category":"hygiene","file":"src/foo.py","description":"Fragile coupling between modules makes this brittle under change."}],"summary":"Minor issues found but overall acceptable for fragile dependencies."}
EOFJ
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
EXIT_CODE=0
# isolation-ok: inject changed files to bypass real git diff (overlap check uses RECORD_REVIEW_CHANGED_FILES when set)
STDERR_OUT=$(RECORD_REVIEW_CHANGED_FILES="src/foo.py" bash "$HOOK" --reviewer-hash "$HASH" 2>&1 >/dev/null) || EXIT_CODE=$?
assert_eq "test_fragile_severity_accepted_no_validation_error: exits 0 (fragile accepted)" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_fragile_severity_produces_failed_status
#
# Given: reviewer-findings.json with a finding of severity "fragile" (2-key schema).
# When:  record-review.sh runs successfully (after fragile severity is accepted).
# Then:  review-status file contains "failed" on its first line because
#        fragile is a blocking severity (any critical/important/fragile = failed).
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
{"findings":[{"severity":"fragile","category":"hygiene","file":"src/foo.py","description":"Fragile coupling between modules makes this brittle under change."}],"summary":"Minor issues found but overall acceptable for fragile dependencies."}
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

# ---------------------------------------------------------------------------
# test_overlap_check_uses_all_staged_files_during_merge (ff09-69a2)
#
# Given: a merge-in-progress repo where the staged files include a file that
#        was added only on the INCOMING branch (not the worktree branch).
#        A reviewer-findings.json references that incoming-branch file.
# When:  record-review.sh is invoked.
# Then:  The script exits 0 (finding accepted).
#
# RED: Currently the CHANGED_FILES variable is built from ms_get_worktree_only_files
#      which excludes incoming-branch files.  The overlap check compares
#      FILES_FROM_FINDINGS against worktree-only CHANGED_FILES, so the incoming
#      file is not found and the check reports "findings do not overlap" → exit 1.
# GREEN: After fix, OVERLAP_CHECK_FILES includes all staged files (git diff --cached),
#        so the incoming file IS found → exit 0.
# ---------------------------------------------------------------------------
_MERGE_TEST_TMPDIRS=()
_cleanup_merge_test_tmpdirs() {
    for d in "${_MERGE_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
# Extend existing EXIT trap (combine with cleanup_rrstate set at line 109)
trap 'cleanup_rrstate; _cleanup_merge_test_tmpdirs' EXIT

_merge_test_tmpdir=$(mktemp -d)
_MERGE_TEST_TMPDIRS+=("$_merge_test_tmpdir")

# Build a minimal two-branch merge repo (same pattern as test-merge-state.sh)
git init --bare -b main "$_merge_test_tmpdir/origin.git" --quiet 2>/dev/null || git init --bare "$_merge_test_tmpdir/origin.git" --quiet
git clone "$_merge_test_tmpdir/origin.git" "$_merge_test_tmpdir/repo" --quiet 2>/dev/null
(
    cd "$_merge_test_tmpdir/repo" || exit
    git config user.email "test@test.com"
    git config user.name "Test"

    # Initial commit on main
    echo "initial" > base.txt
    git add base.txt
    git commit -m "initial" --quiet

    # Worktree branch: add a worktree file
    git checkout -b feature --quiet
    echo "worktree change" > worktree-side.py
    git add worktree-side.py
    git commit -m "feature: add worktree-side.py" --quiet

    # Back to main: add incoming.txt
    git checkout main --quiet
    echo "incoming change" > incoming-only.py
    git add incoming-only.py
    git commit -m "main: add incoming-only.py" --quiet
    git push origin main --quiet 2>/dev/null

    # Back to feature, start merge (no-commit so MERGE_HEAD persists + incoming staged)
    git checkout feature --quiet
    git merge main --no-commit --no-edit 2>/dev/null || true
) 2>/dev/null

# Set up test artifacts in temp dir; findings reference incoming-only.py
_merge_artifacts=$(mktemp -d)
_MERGE_TEST_TMPDIRS+=("$_merge_artifacts")

cat > "$_merge_artifacts/reviewer-findings.json" <<'EOFJ'
{"findings":[{"severity":"minor","category":"hygiene","file":"incoming-only.py","description":"Minor style issue on incoming branch file."}],"summary":"Review performed on the incoming branch file only. No issues found."}
EOFJ
_MERGE_HASH=$(shasum -a 256 "$_merge_artifacts/reviewer-findings.json" | awk '{print $1}')

MERGE_EXIT_CODE=0
(
    cd "$_merge_test_tmpdir/repo"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_merge_artifacts" bash "$HOOK" --reviewer-hash "$_MERGE_HASH" 2>/dev/null
) || MERGE_EXIT_CODE=$?

assert_eq "test_overlap_check_uses_all_staged_files_during_merge: exits 0 (incoming-branch file accepted)" "0" "$MERGE_EXIT_CODE"

# ---------------------------------------------------------------------------
# test_per_finding_strip_removes_out_of_diff_findings (c751-600d)
#
# Given: RECORD_REVIEW_CHANGED_FILES contains only "src/real-file.py".
#        reviewer-findings.json has 2 findings:
#          1. in-diff: severity=minor, category=hygiene, file=src/real-file.py
#          2. out-of-diff: severity=critical, category=correctness,
#             file=src/hallucinated-file.py (NOT in CHANGED_FILES)
#        Scores: hygiene=4, correctness=1 (critical cross-validation requires <=2),
#                all others=5.
# When:  record-review.sh is invoked.
# Then:  The out-of-diff critical finding is stripped before recording.
#        With no remaining critical findings and correctness score reset to 5,
#        the recorded status is "passed" (min_score=4 >= 4, has_critical=no).
#
# RED: Currently the set-level overlap check passes because src/real-file.py
#      overlaps. ALL findings pass through, including the hallucinated critical
#      one. has_critical=yes → STATUS=failed → review-status first line is "failed".
# GREEN: After per-finding strip, the critical finding is removed, correctness
#        score is reset (no remaining critical in that dimension), min_score=4,
#        STATUS=passed → review-status first line is "passed".
# ---------------------------------------------------------------------------
cleanup
mkdir -p "$ARTIFACTS_DIR"
cat > "$FINDINGS_FILE" <<'EOFJ'
{
  "findings": [
    {"severity":"minor","category":"hygiene","file":"src/real-file.py","description":"Minor style issue in the real changed file."},
    {"severity":"critical","category":"correctness","file":"src/hallucinated-file.py","description":"Hallucinated critical issue in a file not in the diff."}
  ],
  "summary":"One real minor finding plus one hallucinated critical in a non-diff file."
}
EOFJ
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
# isolation-ok: inject only the real file so hallucinated-file.py is clearly out-of-diff
RECORD_REVIEW_CHANGED_FILES="src/real-file.py" bash "$HOOK" --reviewer-hash "$HASH" 2>/dev/null || true

STRIP_STATUS_FILE="$ARTIFACTS_DIR/review-status"
if [[ -f "$STRIP_STATUS_FILE" ]]; then
    STRIP_FIRST_LINE=$(head -1 "$STRIP_STATUS_FILE")
else
    STRIP_FIRST_LINE="not_written"
fi
assert_eq "test_per_finding_strip_removes_out_of_diff_findings: status is 'passed' after stripping hallucinated critical" "passed" "$STRIP_FIRST_LINE"

# ---------------------------------------------------------------------------
# test_fallback_artifacts_dir_found (a74e-1671)
#
# Given: reviewer-findings.json was written to .claude/artifacts/ (the relative
#        fallback path used by sub-agents when WORKFLOW_PLUGIN_ARTIFACTS_DIR is
#        not set and they resolve a different REPO_ROOT), but the primary
#        WORKFLOW_PLUGIN_ARTIFACTS_DIR is a different /tmp/ path.
# When:  record-review.sh is invoked without --findings-file (primary path is empty).
# Then:  The script finds reviewer-findings.json in the fallback location
#        ($REPO_ROOT/.claude/artifacts/), reads it, and exits 0.
#
# RED: Currently exits 1 with "reviewer-findings.json not found" because
#      record-review.sh only checks ARTIFACTS_DIR and does not fall back to
#      $REPO_ROOT/.claude/artifacts/.
# GREEN: After fix, record-review.sh checks the fallback path and succeeds.
# ---------------------------------------------------------------------------
_FALLBACK_ARTIFACTS_TMPDIR=$(mktemp -d)
trap 'rm -rf "$_FALLBACK_ARTIFACTS_TMPDIR"' EXIT

# Set up a fresh /tmp/ artifacts dir with no reviewer-findings.json
_FALLBACK_PRIMARY_DIR=$(mktemp -d "${TMPDIR:-/tmp}/test-rr-primary-XXXXXX")
trap 'rm -rf "$_FALLBACK_PRIMARY_DIR"' EXIT

# Set up a fake repo root with a .claude/artifacts/ fallback dir
_FALLBACK_REPO_DIR=$(mktemp -d)
trap 'rm -rf "$_FALLBACK_REPO_DIR"' EXIT
git -C "$_FALLBACK_REPO_DIR" init --quiet 2>/dev/null || true
mkdir -p "$_FALLBACK_REPO_DIR/.claude/artifacts"

# Write a valid reviewer-findings.json to the FALLBACK location only
_FALLBACK_FINDINGS="$_FALLBACK_REPO_DIR/.claude/artifacts/reviewer-findings.json"
cat > "$_FALLBACK_FINDINGS" <<'EOFJ'
{"findings":[],"summary":"Fallback path test: all checks passed."}
EOFJ
_FALLBACK_HASH=$(shasum -a 256 "$_FALLBACK_FINDINGS" | awk '{print $1}')

# Invoke record-review.sh with WORKFLOW_PLUGIN_ARTIFACTS_DIR pointing to the
# primary dir (which has no reviewer-findings.json). REPO_ROOT is the fake repo
# with .claude/artifacts/reviewer-findings.json. The script should find the
# fallback and succeed.
_FALLBACK_EXIT=0
(
    cd "$_FALLBACK_REPO_DIR"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_FALLBACK_PRIMARY_DIR" \
    RECORD_REVIEW_CHANGED_FILES="src/foo.py" \
    bash "$HOOK" --reviewer-hash "$_FALLBACK_HASH" 2>/dev/null
) || _FALLBACK_EXIT=$?
assert_eq "test_fallback_artifacts_dir_found: exits 0 when reviewer-findings.json in .claude/artifacts/" "0" "$_FALLBACK_EXIT"

# ---------------------------------------------------------------------------
# Test: overlay gate — record-review.sh must verify that every overlay flag
#       set true in classifier-telemetry.jsonl has a corresponding
#       reviewer-findings-<dim>.json file. Missing overlay = gate failure.
#
# Failure mode this guards against: orchestrator skips Step 4b (Overlay Dispatch)
# in REVIEW-WORKFLOW.md. Tier reviewer findings record successfully, but the
# overlay reviewer (e.g., test-quality) was never dispatched — so coverage of
# the corresponding dimension is silently absent. The gate must catch this.
#
# Use a controlled tmp git repo so we control the working-tree diff hash.
#
# RED: Current record-review.sh does not read overlay flags from
#      classifier-telemetry.jsonl and does not enforce per-overlay findings files.
# GREEN: After enhancement, record-review.sh exits non-zero when classifier
#        flagged an overlay true but no matching reviewer-findings-<dim>.json exists.
# ---------------------------------------------------------------------------
_OVERLAY_REPO=$(mktemp -d "${TMPDIR:-/tmp}/test-rr-overlay-repo-XXXXXX")
_OVERLAY_TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-rr-overlay-art-XXXXXX")
trap 'rm -rf "$_OVERLAY_REPO" "$_OVERLAY_TMP"' EXIT

# Set up a clean repo with a known unstaged change (so `git diff` is non-empty
# and reproducible). record-review.sh will compute diff hash from this state.
git -C "$_OVERLAY_REPO" init --quiet 2>/dev/null
git -C "$_OVERLAY_REPO" config user.email "test@test.com"
git -C "$_OVERLAY_REPO" config user.name "Test"
echo "initial" > "$_OVERLAY_REPO/file.txt"
git -C "$_OVERLAY_REPO" add file.txt
git -C "$_OVERLAY_REPO" commit -m "initial" --quiet >/dev/null 2>&1
echo "modified" >> "$_OVERLAY_REPO/file.txt"
git -C "$_OVERLAY_REPO" add file.txt
# Compute diff hash using the same method as compute-diff-hash.sh:
# `git diff --cached HEAD` (staged-only) then sha256. Updated from `git diff HEAD`
# when compute-diff-hash.sh was changed to use --cached for auto-stash invariance (00a5-548f).
_OVERLAY_DIFF_HASH=$(cd "$_OVERLAY_REPO" && git diff --cached HEAD | shasum -a 256 | awk '{print $1}')

# Set up reviewer-findings.json (tier reviewer's output — passes baseline gates)
cat > "$_OVERLAY_TMP/reviewer-findings.json" <<'EOFJ'
{"findings":[],"summary":"All checks passed. Tier reviewer ran but overlays were skipped.","review_tier":"standard","selected_tier":"standard"}
EOFJ
_OVERLAY_HASH=$(shasum -a 256 "$_OVERLAY_TMP/reviewer-findings.json" | awk '{print $1}')

# Write classifier telemetry that flags test_quality_overlay: true for this diff hash
cat > "$_OVERLAY_TMP/classifier-telemetry.jsonl" <<EOFJ
{"diff_hash":"$_OVERLAY_DIFF_HASH","selected_tier":"standard","test_quality_overlay":true,"security_overlay":false,"performance_overlay":false}
EOFJ

# NO reviewer-findings-test-quality.json exists — overlay was skipped.
echo "--- test_overlay_gate_blocks_missing_test_quality_findings ---"
_OVERLAY_EXIT=0
(
    cd "$_OVERLAY_REPO"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_OVERLAY_TMP" \
    RECORD_REVIEW_CHANGED_FILES="file.txt" \
    bash "$HOOK" --reviewer-hash "$_OVERLAY_HASH" 2>/dev/null
) || _OVERLAY_EXIT=$?

# RED: currently passes (record-review.sh does not check overlays).
# GREEN: must fail (overlay flagged but no findings file recorded).
assert_ne "test_overlay_gate_blocks_missing_test_quality_findings: exits non-zero when classifier flagged overlay but no findings file exists" "0" "$_OVERLAY_EXIT"

# Companion test: when overlay findings file IS present, gate passes.
echo "--- test_overlay_gate_passes_when_findings_present ---"
cat > "$_OVERLAY_TMP/reviewer-findings-test-quality.json" <<'EOFJ'
{"findings":[],"summary":"Test quality overlay: clean.","review_tier":"deep"}
EOFJ
_OVERLAY_PASS_EXIT=0
(
    cd "$_OVERLAY_REPO"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_OVERLAY_TMP" \
    RECORD_REVIEW_CHANGED_FILES="file.txt" \
    bash "$HOOK" --reviewer-hash "$_OVERLAY_HASH" 2>/dev/null
) || _OVERLAY_PASS_EXIT=$?
assert_eq "test_overlay_gate_passes_when_findings_present: exits 0 when overlay findings file exists alongside canonical" "0" "$_OVERLAY_PASS_EXIT"

# ---------------------------------------------------------------------------
# Test: overlay gate must filter telemetry by current diff_hash, not just tail -1.
#
# Stale telemetry from a prior review of a different diff sits at the tail of
# the append-only classifier-telemetry.jsonl. A correct gate skips records
# whose diff_hash != current diff and reads the current record instead.
#
# RED: tail -1 alone consumes the stale record; a stale "test_quality_overlay:true"
#      followed by a current "test_quality_overlay:false" causes false-positive
#      OVERLAY_MISSING for an overlay the current run did not flag.
# GREEN: gate filters telemetry to records matching current diff_hash before
#        extracting flags.
# ---------------------------------------------------------------------------
echo "--- test_overlay_gate_filters_telemetry_by_diff_hash ---"
_DIFFHASH_REPO=$(mktemp -d "${TMPDIR:-/tmp}/test-rr-diffhash-repo-XXXXXX")
_DIFFHASH_TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-rr-diffhash-art-XXXXXX")
trap 'rm -rf "$_OVERLAY_REPO" "$_OVERLAY_TMP" "$_DIFFHASH_REPO" "$_DIFFHASH_TMP"' EXIT

git -C "$_DIFFHASH_REPO" init --quiet 2>/dev/null
git -C "$_DIFFHASH_REPO" config user.email "test@test.com"
git -C "$_DIFFHASH_REPO" config user.name "Test"
echo "initial" > "$_DIFFHASH_REPO/file.txt"
git -C "$_DIFFHASH_REPO" add file.txt
git -C "$_DIFFHASH_REPO" commit -m "initial" --quiet >/dev/null 2>&1
echo "modified-diffhash" >> "$_DIFFHASH_REPO/file.txt"
git -C "$_DIFFHASH_REPO" add file.txt
_CURRENT_HASH=$(cd "$_DIFFHASH_REPO" && git diff --cached HEAD | shasum -a 256 | awk '{print $1}')
_STALE_HASH="0000000000000000000000000000000000000000000000000000000000000000"

cat > "$_DIFFHASH_TMP/reviewer-findings.json" <<'EOFJ'
{"findings":[],"summary":"All checks passed.","review_tier":"standard","selected_tier":"standard"}
EOFJ
_DH_HASH=$(shasum -a 256 "$_DIFFHASH_TMP/reviewer-findings.json" | awk '{print $1}')

# Stale record (different diff hash) flags overlay; current record does NOT.
# Order: current FIRST, stale LAST — so tail -1 (without filter) reads the stale
# record and triggers a false-positive OVERLAY_MISSING. With diff_hash filter,
# gate ignores the stale record and reads the current one (no overlay flagged).
cat > "$_DIFFHASH_TMP/classifier-telemetry.jsonl" <<EOFJ
{"diff_hash":"$_CURRENT_HASH","selected_tier":"standard","test_quality_overlay":false,"security_overlay":false,"performance_overlay":false}
{"diff_hash":"$_STALE_HASH","selected_tier":"standard","test_quality_overlay":true,"security_overlay":false,"performance_overlay":false}
EOFJ

_DH_EXIT=0
(
    cd "$_DIFFHASH_REPO"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_DIFFHASH_TMP" \
    RECORD_REVIEW_CHANGED_FILES="file.txt" \
    bash "$HOOK" --reviewer-hash "$_DH_HASH" 2>/dev/null
) || _DH_EXIT=$?
assert_eq "test_overlay_gate_filters_telemetry_by_diff_hash: exits 0 when current record flags no overlay (stale record at tail must be ignored)" "0" "$_DH_EXIT"

# ---------------------------------------------------------------------------
# Test: overlay gate covers security_overlay flag.
# RED: implementation iterates all three flags but only test_quality is tested.
# GREEN: same enforcement path triggers OVERLAY_MISSING for security_overlay.
# ---------------------------------------------------------------------------
echo "--- test_overlay_gate_security_flag_blocks_missing_findings ---"
_SEC_REPO=$(mktemp -d "${TMPDIR:-/tmp}/test-rr-sec-repo-XXXXXX")
_SEC_TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-rr-sec-art-XXXXXX")
trap 'rm -rf "$_OVERLAY_REPO" "$_OVERLAY_TMP" "$_DIFFHASH_REPO" "$_DIFFHASH_TMP" "$_SEC_REPO" "$_SEC_TMP"' EXIT

git -C "$_SEC_REPO" init --quiet 2>/dev/null
git -C "$_SEC_REPO" config user.email "test@test.com"
git -C "$_SEC_REPO" config user.name "Test"
echo "initial" > "$_SEC_REPO/file.txt"
git -C "$_SEC_REPO" add file.txt
git -C "$_SEC_REPO" commit -m "initial" --quiet >/dev/null 2>&1
echo "modified-security" >> "$_SEC_REPO/file.txt"
git -C "$_SEC_REPO" add file.txt
_SEC_DIFF_HASH=$(cd "$_SEC_REPO" && git diff --cached HEAD | shasum -a 256 | awk '{print $1}')

cat > "$_SEC_TMP/reviewer-findings.json" <<'EOFJ'
{"findings":[],"summary":"All checks passed.","review_tier":"standard","selected_tier":"standard"}
EOFJ
_SEC_HASH=$(shasum -a 256 "$_SEC_TMP/reviewer-findings.json" | awk '{print $1}')

cat > "$_SEC_TMP/classifier-telemetry.jsonl" <<EOFJ
{"diff_hash":"$_SEC_DIFF_HASH","selected_tier":"standard","test_quality_overlay":false,"security_overlay":true,"performance_overlay":false}
EOFJ

_SEC_EXIT=0
(
    cd "$_SEC_REPO"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_SEC_TMP" \
    RECORD_REVIEW_CHANGED_FILES="file.txt" \
    bash "$HOOK" --reviewer-hash "$_SEC_HASH" 2>/dev/null
) || _SEC_EXIT=$?
assert_ne "test_overlay_gate_security_flag_blocks_missing_findings: exits non-zero when security_overlay flagged but reviewer-findings-security.json missing" "0" "$_SEC_EXIT"

# ---------------------------------------------------------------------------
# Test: overlay gate covers performance_overlay flag.
# ---------------------------------------------------------------------------
echo "--- test_overlay_gate_performance_flag_blocks_missing_findings ---"
cat > "$_SEC_TMP/classifier-telemetry.jsonl" <<EOFJ
{"diff_hash":"$_SEC_DIFF_HASH","selected_tier":"standard","test_quality_overlay":false,"security_overlay":false,"performance_overlay":true}
EOFJ

_PERF_EXIT=0
(
    cd "$_SEC_REPO"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_SEC_TMP" \
    RECORD_REVIEW_CHANGED_FILES="file.txt" \
    bash "$HOOK" --reviewer-hash "$_SEC_HASH" 2>/dev/null
) || _PERF_EXIT=$?
assert_ne "test_overlay_gate_performance_flag_blocks_missing_findings: exits non-zero when performance_overlay flagged but reviewer-findings-performance.json missing" "0" "$_PERF_EXIT"

# ---------------------------------------------------------------------------
# Test: classifier-telemetry.jsonl records MUST include diff_hash field.
#
# The cycle-3 overlay gate filters telemetry by diff_hash to avoid consuming
# stale records. If the classifier write block omits diff_hash, every record
# fails the filter and the gate silently disables itself — the exact failure
# mode we're guarding against. This is a contract test on the classifier's
# telemetry output schema.
#
# RED: review-complexity-classifier.sh telemetry write block does not currently
#      emit a diff_hash field. The gate's filter compares against a missing
#      field and the matched dict stays None.
# GREEN: classifier emits diff_hash in every telemetry record (passed via
#        --diff-hash flag from the caller).
# ---------------------------------------------------------------------------
echo "--- test_classifier_telemetry_includes_diff_hash ---"
_CLASSIFIER_REPO=$(mktemp -d "${TMPDIR:-/tmp}/test-classifier-diffhash-XXXXXX")
trap 'rm -rf "$_OVERLAY_REPO" "$_OVERLAY_TMP" "$_DIFFHASH_REPO" "$_DIFFHASH_TMP" "$_SEC_REPO" "$_SEC_TMP" "$_CLASSIFIER_REPO"' EXIT

git -C "$_CLASSIFIER_REPO" init --quiet 2>/dev/null
git -C "$_CLASSIFIER_REPO" config user.email "test@test.com"
git -C "$_CLASSIFIER_REPO" config user.name "Test"
mkdir -p "$_CLASSIFIER_REPO/src"
echo "x = 1" > "$_CLASSIFIER_REPO/src/foo.py"
git -C "$_CLASSIFIER_REPO" add src/foo.py
git -C "$_CLASSIFIER_REPO" commit -m "initial" --quiet >/dev/null 2>&1
echo "x = 2" > "$_CLASSIFIER_REPO/src/foo.py"
_C_DIFF=$(cd "$_CLASSIFIER_REPO" && git diff HEAD)
_C_HASH=$(echo -n "$_C_DIFF" | shasum -a 256 | awk '{print $1}')

# Classifier output and telemetry write — pass diff hash via --diff-hash flag
_CLASSIFIER="$DSO_PLUGIN_DIR/scripts/review-complexity-classifier.sh"
_C_TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-classifier-art-XXXXXX")
(
    cd "$_CLASSIFIER_REPO"
    REPO_ROOT="$_CLASSIFIER_REPO" ARTIFACTS_DIR="$_C_TMP" \
    bash "$_CLASSIFIER" --diff-hash "$_C_HASH" <<< "$_C_DIFF" >/dev/null 2>&1
) || true

# The telemetry record MUST include the diff_hash field for the overlay gate to filter correctly.
_TELEMETRY="$_C_TMP/classifier-telemetry.jsonl"
_HAS_DIFF_HASH="missing"
if [[ -f "$_TELEMETRY" ]]; then
    if grep -q "\"diff_hash\":\"$_C_HASH\"" "$_TELEMETRY"; then
        _HAS_DIFF_HASH="found"
    fi
fi
assert_eq "test_classifier_telemetry_includes_diff_hash: classifier-telemetry.jsonl record contains diff_hash matching the input diff" "found" "$_HAS_DIFF_HASH"
rm -rf "$_C_TMP"

# ---------------------------------------------------------------------------
# Test: fail-closed branch when read-overlay-flags.sh is missing.
#
# When telemetry exists but the helper script is not executable, record-review.sh
# must exit non-zero with OVERLAY_GATE_UNAVAILABLE rather than silently passing.
# Regression to fail-open here would defeat the gate's purpose.
# ---------------------------------------------------------------------------
echo "--- test_overlay_gate_fails_closed_when_helper_missing ---"
_FC_REPO=$(mktemp -d "${TMPDIR:-/tmp}/test-rr-failclosed-XXXXXX")
_FC_TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-rr-failclosed-art-XXXXXX")
_FC_FAKE_PLUGIN=$(mktemp -d "${TMPDIR:-/tmp}/test-rr-fakeplugin-XXXXXX")
trap 'rm -rf "$_OVERLAY_REPO" "$_OVERLAY_TMP" "$_DIFFHASH_REPO" "$_DIFFHASH_TMP" "$_SEC_REPO" "$_SEC_TMP" "$_CLASSIFIER_REPO" "$_FC_REPO" "$_FC_TMP" "$_FC_FAKE_PLUGIN"' EXIT

# Set up minimal git repo with a diff
git -C "$_FC_REPO" init --quiet 2>/dev/null
git -C "$_FC_REPO" config user.email "test@test.com"
git -C "$_FC_REPO" config user.name "Test"
echo "initial" > "$_FC_REPO/file.txt"
git -C "$_FC_REPO" add file.txt
git -C "$_FC_REPO" commit -m "initial" --quiet >/dev/null 2>&1
echo "modified-failclosed" >> "$_FC_REPO/file.txt"
git -C "$_FC_REPO" add file.txt
_FC_DIFF_HASH=$(cd "$_FC_REPO" && git diff --cached HEAD | shasum -a 256 | awk '{print $1}')

# Set up reviewer-findings.json
cat > "$_FC_TMP/reviewer-findings.json" <<'EOFJ'
{"findings":[],"summary":"All checks passed in the fail-closed branch test scenario.","review_tier":"standard","selected_tier":"standard"}
EOFJ
_FC_HASH=$(shasum -a 256 "$_FC_TMP/reviewer-findings.json" | awk '{print $1}')

# Telemetry exists (with current diff_hash) — fail-closed branch should fire when helper is missing.
cat > "$_FC_TMP/classifier-telemetry.jsonl" <<EOFJ
{"diff_hash":"$_FC_DIFF_HASH","selected_tier":"standard","test_quality_overlay":false,"security_overlay":false,"performance_overlay":false}
EOFJ

# Construct a fake plugin layout where read-overlay-flags.sh does NOT exist.
# Mirror the entire hooks/ tree (record-review.sh + compute-diff-hash.sh + lib/)
# so dependencies resolve. Create scripts/ but DO NOT copy read-overlay-flags.sh.
mkdir -p "$_FC_FAKE_PLUGIN/hooks" "$_FC_FAKE_PLUGIN/scripts"
cp -R "$DSO_PLUGIN_DIR/hooks/." "$_FC_FAKE_PLUGIN/hooks/"
# Note: $_FC_FAKE_PLUGIN/scripts/read-overlay-flags.sh is intentionally absent.

_FC_EXIT=0
_FC_STDERR=$(
    cd "$_FC_REPO"
    WORKFLOW_PLUGIN_ARTIFACTS_DIR="$_FC_TMP" \
    RECORD_REVIEW_CHANGED_FILES="file.txt" \
    bash "$_FC_FAKE_PLUGIN/hooks/record-review.sh" --reviewer-hash "$_FC_HASH" 2>&1 1>/dev/null
) || _FC_EXIT=$?

assert_ne "test_overlay_gate_fails_closed_when_helper_missing: exits non-zero when telemetry exists but read-overlay-flags.sh helper is missing" "0" "$_FC_EXIT"
# Stderr should mention OVERLAY_GATE_UNAVAILABLE (the named contract signal)
_FC_HAS_SIGNAL=missing
echo "$_FC_STDERR" | grep -q "OVERLAY_GATE_UNAVAILABLE" && _FC_HAS_SIGNAL=found
assert_eq "test_overlay_gate_fails_closed_when_helper_missing: stderr emits OVERLAY_GATE_UNAVAILABLE signal" "found" "$_FC_HAS_SIGNAL"

# test_severity_critical_produces_failed_status
# Given: 2-key findings.json with a critical severity finding
# When: record-review.sh runs
# Then: review-status line 1 = "failed"
echo "=== test_severity_critical_produces_failed_status ==="
cleanup
mkdir -p "$ARTIFACTS_DIR"
cat > "$FINDINGS_FILE" <<'EOF'
{"findings":[{"severity":"critical","category":"correctness","file":"src/foo.sh","description":"Critical defect found in authentication logic"}],"summary":"Critical issue found."}
EOF
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
# isolation-ok: inject changed files matching the finding's file to prevent per-finding strip
RECORD_REVIEW_CHANGED_FILES="src/foo.sh" bash "$HOOK" --reviewer-hash "$HASH" 2>/dev/null || true
REVIEW_STATUS_FILE="$ARTIFACTS_DIR/review-status"
ACTUAL_STATUS=$(head -1 "$REVIEW_STATUS_FILE" 2>/dev/null || echo "missing")
assert_eq "test_severity_critical_produces_failed_status: STATUS=failed" "failed" "$ACTUAL_STATUS"

# test_severity_important_produces_failed_status
echo "=== test_severity_important_produces_failed_status ==="
cleanup
mkdir -p "$ARTIFACTS_DIR"
cat > "$FINDINGS_FILE" <<'EOF'
{"findings":[{"severity":"important","category":"hygiene","file":"src/bar.sh","description":"Important style violation"}],"summary":"Important issue found."}
EOF
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
# isolation-ok: inject changed files matching the finding's file to prevent per-finding strip
RECORD_REVIEW_CHANGED_FILES="src/bar.sh" bash "$HOOK" --reviewer-hash "$HASH" 2>/dev/null || true
REVIEW_STATUS_FILE="$ARTIFACTS_DIR/review-status"
ACTUAL_STATUS=$(head -1 "$REVIEW_STATUS_FILE" 2>/dev/null || echo "missing")
assert_eq "test_severity_important_produces_failed_status: STATUS=failed" "failed" "$ACTUAL_STATUS"

# test_severity_fragile_produces_failed_status
echo "=== test_severity_fragile_produces_failed_status ==="
cleanup
mkdir -p "$ARTIFACTS_DIR"
cat > "$FINDINGS_FILE" <<'EOF'
{"findings":[{"severity":"fragile","category":"design","file":"src/baz.sh","description":"Fragile coupling detected"}],"summary":"Fragile issue found."}
EOF
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
# isolation-ok: inject changed files matching the finding's file to prevent per-finding strip
RECORD_REVIEW_CHANGED_FILES="src/baz.sh" bash "$HOOK" --reviewer-hash "$HASH" 2>/dev/null || true
REVIEW_STATUS_FILE="$ARTIFACTS_DIR/review-status"
ACTUAL_STATUS=$(head -1 "$REVIEW_STATUS_FILE" 2>/dev/null || echo "missing")
assert_eq "test_severity_fragile_produces_failed_status: STATUS=failed" "failed" "$ACTUAL_STATUS"

# test_severity_minor_produces_passed_status
echo "=== test_severity_minor_produces_passed_status ==="
cleanup
mkdir -p "$ARTIFACTS_DIR"
cat > "$FINDINGS_FILE" <<'EOF'
{"findings":[{"severity":"minor","category":"hygiene","file":"src/foo.sh","description":"Minor style nit"}],"summary":"Minor issue only."}
EOF
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
# isolation-ok: inject changed files matching the finding's file to prevent per-finding strip
RECORD_REVIEW_CHANGED_FILES="src/foo.sh" bash "$HOOK" --reviewer-hash "$HASH" 2>/dev/null || true
REVIEW_STATUS_FILE="$ARTIFACTS_DIR/review-status"
ACTUAL_STATUS=$(head -1 "$REVIEW_STATUS_FILE" 2>/dev/null || echo "missing")
assert_eq "test_severity_minor_produces_passed_status: STATUS=passed" "passed" "$ACTUAL_STATUS"

# test_empty_findings_produces_passed_status
echo "=== test_empty_findings_produces_passed_status ==="
cleanup
mkdir -p "$ARTIFACTS_DIR"
cat > "$FINDINGS_FILE" <<'EOF'
{"findings":[],"summary":"All checks passed. No issues found."}
EOF
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
bash "$HOOK" --reviewer-hash "$HASH" 2>/dev/null || true
REVIEW_STATUS_FILE="$ARTIFACTS_DIR/review-status"
ACTUAL_STATUS=$(head -1 "$REVIEW_STATUS_FILE" 2>/dev/null || echo "missing")
assert_eq "test_empty_findings_produces_passed_status: STATUS=passed" "passed" "$ACTUAL_STATUS"

# test_minor_with_critical_in_description_produces_passed_status
# Finding has severity=minor but description text contains "critical".
# The gate must NOT block based on description text — only the severity field matters.
echo "=== test_minor_with_critical_in_description_produces_passed_status ==="
cleanup
mkdir -p "$ARTIFACTS_DIR"
cat > "$FINDINGS_FILE" <<'EOF'
{"findings":[{"severity":"minor","category":"hygiene","file":"src/foo.sh","description":"This minor issue has the word critical in it but should not fail"}],"summary":"Minor only."}
EOF
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
bash "$HOOK" --reviewer-hash "$HASH" 2>/dev/null || true
REVIEW_STATUS_FILE="$ARTIFACTS_DIR/review-status"
ACTUAL_STATUS=$(head -1 "$REVIEW_STATUS_FILE" 2>/dev/null || echo "missing")
assert_eq "test_minor_with_critical_in_description_produces_passed_status: STATUS=passed" "passed" "$ACTUAL_STATUS"

# test_review_status_has_no_score_line
# After record-review.sh runs with a valid 2-key findings.json,
# the review-status file must NOT contain a score= line.
echo "=== test_review_status_has_no_score_line ==="
cleanup
mkdir -p "$ARTIFACTS_DIR"
cat > "$FINDINGS_FILE" <<'EOF'
{"findings":[],"summary":"All good."}
EOF
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
bash "$HOOK" --reviewer-hash "$HASH" 2>/dev/null || true
REVIEW_STATUS_FILE="$ARTIFACTS_DIR/review-status"
SCORE_LINE=$(grep '^score=' "$REVIEW_STATUS_FILE" 2>/dev/null || echo "absent")
assert_eq "test_review_status_has_no_score_line: no score= line in review-status" "absent" "$SCORE_LINE"

# ---------------------------------------------------------------------------
# test_overlap_normalizes_dot_slash_prefix
#
# Given: RECORD_REVIEW_CHANGED_FILES contains "foo.sh" (bare path).
#        reviewer-findings.json has a single minor finding with file="./foo.sh"
#        (leading "./" prefix).
# When:  record-review.sh runs.
# Then:  Python _normalize strips './' so the per-finding strip recognizes the
#        finding as in-diff and preserves it in the findings file. The script
#        exits 0 and the finding's file field remains './foo.sh' (the strip is
#        non-mutating — it only filters, never rewrites the file field).
# ---------------------------------------------------------------------------
echo "=== test_overlap_normalizes_dot_slash_prefix ==="
cleanup
mkdir -p "$ARTIFACTS_DIR"
cat > "$FINDINGS_FILE" <<'EOF'
{"findings":[{"severity":"minor","category":"hygiene","file":"./foo.sh","description":"Minor style issue."}],"summary":"One minor finding with ./ prefix path."}
EOF
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
DOT_SLASH_EXIT=0
# isolation-ok: inject bare path; finding uses ./-prefixed equivalent
RECORD_REVIEW_CHANGED_FILES="foo.sh" bash "$HOOK" --reviewer-hash "$HASH" 2>/dev/null || DOT_SLASH_EXIT=$?
assert_eq "test_overlap_normalizes_dot_slash_prefix: ./foo.sh matches foo.sh (exit 0)" "0" "$DOT_SLASH_EXIT"
# Finding must survive the per-finding strip (NOT be filtered out as out-of-diff).
DOT_SLASH_FINDINGS_COUNT=$(python3 -c "
import json
with open('$FINDINGS_FILE') as f:
    print(len(json.load(f).get('findings', [])))
" 2>/dev/null || echo "0")
assert_eq "test_overlap_normalizes_dot_slash_prefix: finding preserved after per-finding strip" "1" "$DOT_SLASH_FINDINGS_COUNT"

# ---------------------------------------------------------------------------
# test_overlap_normalizes_redundant_separators
#
# Given: RECORD_REVIEW_CHANGED_FILES contains "foo/bar.sh".
#        reviewer-findings.json has a single minor finding with
#        file="foo//bar.sh" (redundant separator).
# When:  record-review.sh runs.
# Then:  Python _normalize collapses "foo//bar.sh" to "foo/bar.sh", the
#        per-finding strip recognizes it as in-diff, and the finding is
#        preserved in the findings file (count remains 1).
#
# Without os.path.normpath, the substring match 'foo/bar.sh' vs 'foo//bar.sh'
# fails in both directions, the finding gets stripped, and FILES_FROM_FINDINGS
# becomes empty — so this test catches missing normalization via the survival
# count, not via exit code (which would silently pass with empty findings).
# ---------------------------------------------------------------------------
echo "=== test_overlap_normalizes_redundant_separators ==="
cleanup
mkdir -p "$ARTIFACTS_DIR"
cat > "$FINDINGS_FILE" <<'EOF'
{"findings":[{"severity":"minor","category":"hygiene","file":"foo//bar.sh","description":"Minor style issue."}],"summary":"One minor finding with redundant separator."}
EOF
HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
REDUNDANT_SEP_EXIT=0
# isolation-ok: inject normalized path; finding uses redundant-separator equivalent
RECORD_REVIEW_CHANGED_FILES="foo/bar.sh" bash "$HOOK" --reviewer-hash "$HASH" 2>/dev/null || REDUNDANT_SEP_EXIT=$?
assert_eq "test_overlap_normalizes_redundant_separators: foo//bar.sh matches foo/bar.sh (exit 0)" "0" "$REDUNDANT_SEP_EXIT"
# Finding must survive the per-finding strip — this is the behavioral signal
# that path normalization actually ran.
REDUNDANT_SEP_FINDINGS_COUNT=$(python3 -c "
import json
with open('$FINDINGS_FILE') as f:
    print(len(json.load(f).get('findings', [])))
" 2>/dev/null || echo "0")
assert_eq "test_overlap_normalizes_redundant_separators: finding preserved after per-finding strip" "1" "$REDUNDANT_SEP_FINDINGS_COUNT"

# ---------------------------------------------------------------------------
# test_truncated_reviewer_hash_rejected_with_clear_message (8073-783f)
# ---------------------------------------------------------------------------
# When the reviewer sub-agent's stdout is truncated mid-hash (LLM output
# truncation), --reviewer-hash arrives with fewer than 64 hex chars. The
# hook must reject with a specific error pointing at truncation rather than
# the generic 'tampered with' mismatch error — so retry guidance is clear.
echo "=== test_truncated_reviewer_hash_rejected_with_clear_message ==="
cleanup
mkdir -p "$ARTIFACTS_DIR"
echo '{"findings":[],"summary":"All checks passed. No issues found."}' > "$FINDINGS_FILE"
TRUNCATED_HASH="e7818922350dd7d59e1a068986b72bf0cadea3d86c0e2a3c4a99107"  # 56 chars (real bug 8073 evidence)
TRUNCATED_OUT=$(bash "$HOOK" --reviewer-hash "$TRUNCATED_HASH" 2>&1 || true)
if echo "$TRUNCATED_OUT" | grep -q "not a valid 64-char SHA-256"; then
    (( ++PASS )); echo "test_truncated_reviewer_hash_rejected_with_clear_message ... PASS"
else
    (( ++FAIL )); printf "FAIL: test_truncated_reviewer_hash_rejected_with_clear_message\n  output: %s\n" "$TRUNCATED_OUT" >&2
fi

# ---------------------------------------------------------------------------
# test_sidecar_hash_file_used_when_present (8073-783f)
# ---------------------------------------------------------------------------
# write-reviewer-findings.sh now writes a `.sha256` sidecar alongside
# reviewer-findings.json. record-review.sh must prefer the sidecar over the
# --reviewer-hash flag, immune to LLM stdout truncation.
echo "=== test_sidecar_hash_file_used_when_present ==="
cleanup
mkdir -p "$ARTIFACTS_DIR"
echo '{"findings":[],"summary":"All checks passed. No issues found."}' > "$FINDINGS_FILE"
SIDECAR_HASH=$(shasum -a 256 "$FINDINGS_FILE" | awk '{print $1}')
printf '%s\n' "$SIDECAR_HASH" > "${FINDINGS_FILE}.sha256"
SIDECAR_EXIT=0
bash "$HOOK" --reviewer-hash "WRONG_TRUNCATED_HASH" 2>/dev/null || SIDECAR_EXIT=$?
assert_eq "test_sidecar_hash_file_used_when_present: sidecar overrides flag (exit 0)" "0" "$SIDECAR_EXIT"
rm -f "${FINDINGS_FILE}.sha256"

print_summary
