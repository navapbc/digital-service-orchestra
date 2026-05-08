#!/usr/bin/env bash
# tests/hooks/test-pre-commit-compliance-verifier.sh
# RED tests for plugins/dso/hooks/pre-commit-compliance-verifier.sh
#
# The hook does NOT exist yet — all 8 tests must FAIL until T4 implements it.
#
# The hook contract:
#   DSO_COMPLIANCE_VERIFIER_ENABLED=true|false  — test-isolation override for config
#   WORKFLOW_PLUGIN_ARTIFACTS_DIR               — override for artifacts dir
#   Exits 0 when disabled or artifacts present; 1 when artifacts missing.
#   Exits 0 with warning when ARTIFACTS_DIR doesn't exist (first-run).
#
# REVIEW-DEFENSE (PR #78 finding 8): the compliance verifier performs file-existence
# checks only on .result artifacts (`if [[ -f "$_result" ]]`). It does not parse or
# validate JSON content of .result files — asserting on internal JSON structure would
# be a change-detector test. Plain-text fixture content (`echo "pass" > result.file`)
# is functionally equivalent to JSON for the behavior under test (does the verifier
# exit 0 or 1 based on artifact presence?). Overlay tests in test-overlay-verification.sh
# use proper JSON fixtures because that code path parses JSON to extract overlay names.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/plugins/dso/hooks/pre-commit-compliance-verifier.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

# ---------------------------------------------------------------------------
# Helper: run hook with given env vars, return exit code
# ---------------------------------------------------------------------------
run_hook() {
    local exit_code=0
    env "$@" bash "$HOOK" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# ---------------------------------------------------------------------------
# test_passes_when_disabled
# config has compliance_verifier.enabled=false → hook must exit 0
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_1=$(mktemp -d "${TMPDIR:-/tmp}/test-cv-disabled-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_1"' EXIT

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=false" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_1")
assert_eq "test_passes_when_disabled" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_blocks_missing_artifact
# enabled=true, lint.result absent, lint.timeout absent → exits 1
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_2=$(mktemp -d "${TMPDIR:-/tmp}/test-cv-missing-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_2"' EXIT
# Do NOT write lint.result

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_2")
assert_eq "test_blocks_missing_artifact" "1" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_passes_present_artifact
# enabled=true, all required artifacts present → exits 0
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_3=$(mktemp -d "${TMPDIR:-/tmp}/test-cv-present-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_3"' EXIT
echo "pass" > "$ARTIFACTS_DIR_3/test.result"
echo "pass" > "$ARTIFACTS_DIR_3/format.result"
echo "pass" > "$ARTIFACTS_DIR_3/lint.result"
echo "pass" > "$ARTIFACTS_DIR_3/classifier-dispatch.result"
echo "pass" > "$ARTIFACTS_DIR_3/reviewer-record.result"

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_3")
assert_eq "test_passes_present_artifact" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_first_run_warning
# ARTIFACTS_DIR absent entirely → exits 0 (warn, not block)
# ---------------------------------------------------------------------------
NONEXISTENT_DIR="${TMPDIR:-/tmp}/test-cv-nonexistent-$(date +%s)-$$"
# Ensure it really doesn't exist
rm -rf "$NONEXISTENT_DIR" 2>/dev/null || true

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$NONEXISTENT_DIR")
assert_eq "test_first_run_warning" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_host_hook_chain (simplified)
# enabled=true, all required artifacts in WORKFLOW_PLUGIN_ARTIFACTS_DIR → exits 0
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_5=$(mktemp -d "${TMPDIR:-/tmp}/test-cv-chain-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_5"' EXIT
echo "success" > "$ARTIFACTS_DIR_5/test.result"
echo "success" > "$ARTIFACTS_DIR_5/format.result"
echo "success" > "$ARTIFACTS_DIR_5/lint.result"
echo "success" > "$ARTIFACTS_DIR_5/classifier-dispatch.result"
echo "success" > "$ARTIFACTS_DIR_5/reviewer-record.result"

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_5")
assert_eq "test_host_hook_chain" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_ci_artifacts_dir
# WORKFLOW_PLUGIN_ARTIFACTS_DIR set to temp path with all required artifacts → exits 0
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_6=$(mktemp -d "${TMPDIR:-/tmp}/test-cv-ci-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_6"' EXIT
echo "ci-pass" > "$ARTIFACTS_DIR_6/test.result"
echo "ci-pass" > "$ARTIFACTS_DIR_6/format.result"
echo "ci-pass" > "$ARTIFACTS_DIR_6/lint.result"
echo "ci-pass" > "$ARTIFACTS_DIR_6/classifier-dispatch.result"
echo "ci-pass" > "$ARTIFACTS_DIR_6/reviewer-record.result"

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_6")
assert_eq "test_ci_artifacts_dir" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_git_commit_blocked_missing_artifact  (DD2 traceability variant)
# enabled=true, NO artifact present → exits 1
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_7=$(mktemp -d "${TMPDIR:-/tmp}/test-cv-git-block-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_7"' EXIT
# Do NOT write lint.result

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_7")
assert_eq "test_git_commit_blocked_missing_artifact" "1" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_timeout_artifact_handling
# enabled=true, lint.timeout present + lint.result absent → exits 1
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_8=$(mktemp -d "${TMPDIR:-/tmp}/test-cv-timeout-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_8"' EXIT
echo "timed-out" > "$ARTIFACTS_DIR_8/lint.timeout"
# Do NOT write lint.result

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_8")
assert_eq "test_timeout_artifact_handling" "1" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_verifier_passes_all_artifacts_present  [GREEN now, stays GREEN after T2]
# All 5 required artifacts present → exits 0
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_9=$(mktemp -d "${TMPDIR:-/tmp}/test-cv-all-present-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_9"' EXIT
echo "pass" > "$ARTIFACTS_DIR_9/test.result"
echo "pass" > "$ARTIFACTS_DIR_9/format.result"
echo "pass" > "$ARTIFACTS_DIR_9/lint.result"
echo "pass" > "$ARTIFACTS_DIR_9/classifier-dispatch.result"
echo "pass" > "$ARTIFACTS_DIR_9/reviewer-record.result"

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_9")
assert_eq "test_verifier_passes_all_artifacts_present" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_verifier_blocks_missing_test  [GREEN]
# lint.result present but test.result absent → exits 1
# Current verifier only checks lint.result → exits 0 → RED
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_10=$(mktemp -d "${TMPDIR:-/tmp}/test-cv-no-test-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_10"' EXIT
# Intentionally omit test.result
echo "pass" > "$ARTIFACTS_DIR_10/format.result"
echo "pass" > "$ARTIFACTS_DIR_10/lint.result"
echo "pass" > "$ARTIFACTS_DIR_10/classifier-dispatch.result"
echo "pass" > "$ARTIFACTS_DIR_10/reviewer-record.result"

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_10")
assert_eq "test_verifier_blocks_missing_test" "1" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_verifier_blocks_missing_format  [GREEN]
# lint.result present but format.result absent → exits 1
# Current verifier only checks lint.result → exits 0 → RED
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_11=$(mktemp -d "${TMPDIR:-/tmp}/test-cv-no-format-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_11"' EXIT
echo "pass" > "$ARTIFACTS_DIR_11/test.result"
# Intentionally omit format.result
echo "pass" > "$ARTIFACTS_DIR_11/lint.result"
echo "pass" > "$ARTIFACTS_DIR_11/classifier-dispatch.result"
echo "pass" > "$ARTIFACTS_DIR_11/reviewer-record.result"

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_11")
assert_eq "test_verifier_blocks_missing_format" "1" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_verifier_blocks_missing_reviewer_record  [GREEN]
# lint.result present but reviewer-record.result absent → exits 1
# Current verifier only checks lint.result → exits 0 → RED
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_12=$(mktemp -d "${TMPDIR:-/tmp}/test-cv-no-reviewer-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_12"' EXIT
echo "pass" > "$ARTIFACTS_DIR_12/test.result"
echo "pass" > "$ARTIFACTS_DIR_12/format.result"
echo "pass" > "$ARTIFACTS_DIR_12/lint.result"
echo "pass" > "$ARTIFACTS_DIR_12/classifier-dispatch.result"
# Intentionally omit reviewer-record.result

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_12")
assert_eq "test_verifier_blocks_missing_reviewer_record" "1" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_verifier_blocks_missing_classifier_dispatch  [GREEN]
# lint.result present but classifier-dispatch.result absent → exits 1
# Current verifier only checks lint.result → exits 0 → RED
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_13=$(mktemp -d "${TMPDIR:-/tmp}/test-cv-no-classifier-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_13"' EXIT
echo "pass" > "$ARTIFACTS_DIR_13/test.result"
echo "pass" > "$ARTIFACTS_DIR_13/format.result"
echo "pass" > "$ARTIFACTS_DIR_13/lint.result"
# Intentionally omit classifier-dispatch.result
echo "pass" > "$ARTIFACTS_DIR_13/reviewer-record.result"

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_13")
assert_eq "test_verifier_blocks_missing_classifier_dispatch" "1" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_override_token_bypasses_block  [GREEN]
# override.token present with matching diff_hash → verifier exits 0
# even when all 5 required step artifacts are missing.
# Current verifier ignores override.token → exits 1 → RED
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_14=$(mktemp -d "${TMPDIR:-/tmp}/test-cv-override-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_14"' EXIT

# Write override.token with diff_hash = sha256 of empty staged diff (no staged files in test)
_DIFF_HASH=$(git diff --cached 2>/dev/null | sha256sum | cut -c1-12)
python3 -c "
import json, sys
data = {'diff_hash': sys.argv[1], 'reason': 'test override', 'timestamp': '2026-05-08T00:00:00Z', 'attribution': {'skill_name': None, 'agent_id': None}}
print(json.dumps(data, indent=2))
" "$_DIFF_HASH" > "$ARTIFACTS_DIR_14/override.token"

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_14")
assert_eq "test_override_token_bypasses_block" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_stale_override_token_does_not_bypass  [GREEN]
# override.token with WRONG diff_hash → verifier still blocks
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_15=$(mktemp -d "${TMPDIR:-/tmp}/test-cv-stale-token-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_15"' EXIT

python3 -c "
import json, sys
data = {'diff_hash': 'deadbeef0000', 'reason': 'stale override', 'timestamp': '2026-05-08T00:00:00Z', 'attribution': {'skill_name': None, 'agent_id': None}}
print(json.dumps(data, indent=2))
" > "$ARTIFACTS_DIR_15/override.token"

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_15")
assert_eq "test_stale_override_token_does_not_bypass" "1" "$EXIT_CODE"

# ---------------------------------------------------------------------------
print_summary
