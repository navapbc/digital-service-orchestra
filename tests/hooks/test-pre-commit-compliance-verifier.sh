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
# enabled=true, lint.result present (any content) → exits 0
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_3=$(mktemp -d "${TMPDIR:-/tmp}/test-cv-present-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_3"' EXIT
echo "pass" > "$ARTIFACTS_DIR_3/lint.result"

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
# enabled=true, valid lint.result in WORKFLOW_PLUGIN_ARTIFACTS_DIR → exits 0
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_5=$(mktemp -d "${TMPDIR:-/tmp}/test-cv-chain-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_5"' EXIT
echo "success" > "$ARTIFACTS_DIR_5/lint.result"

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_5")
assert_eq "test_host_hook_chain" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_ci_artifacts_dir
# WORKFLOW_PLUGIN_ARTIFACTS_DIR set to temp path with lint.result → exits 0
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_6=$(mktemp -d "${TMPDIR:-/tmp}/test-cv-ci-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_6"' EXIT
echo "ci-pass" > "$ARTIFACTS_DIR_6/lint.result"

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
print_summary
