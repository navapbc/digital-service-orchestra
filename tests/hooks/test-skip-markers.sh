#!/usr/bin/env bash
# tests/hooks/test-skip-markers.sh
# RED tests for .skipped marker acceptance in pre-commit-compliance-verifier.sh
#
# Task 6bfc-4128-252c-44fa: skip marker acceptance
#
# The verifier currently only checks for .result files; it does NOT yet accept
# .skipped markers as a valid alternative. Tests 1, 3, 4, 5 are RED — they will
# fail until the GREEN task adds .skipped marker support. Test 2 is already GREEN
# (missing step with no marker still blocks).

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
# test_skipped_marker_accepted  [RED — verifier ignores .skipped today]
# reviewer-record.skipped present (no .result), all other 4 .result files
# present → verifier should exit 0 (skip marker accepted).
# Currently exits 1 because verifier only checks .result → RED.
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_A=$(mktemp -d "${TMPDIR:-/tmp}/test-skip-marker-a-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_A"' EXIT

echo "pass" > "$ARTIFACTS_DIR_A/test.result"
echo "pass" > "$ARTIFACTS_DIR_A/format.result"
echo "pass" > "$ARTIFACTS_DIR_A/lint.result"
echo "pass" > "$ARTIFACTS_DIR_A/classifier-dispatch.result"
echo "skipped" > "$ARTIFACTS_DIR_A/reviewer-record.skipped"
# reviewer-record.result intentionally absent

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_A")
assert_eq "test_skipped_marker_accepted" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_missing_not_skipped  [GREEN already — missing step with no marker blocks]
# 4 of 5 required .result files present; reviewer-record has neither .result
# nor .skipped → verifier must exit 1 (block the commit).
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_B=$(mktemp -d "${TMPDIR:-/tmp}/test-skip-marker-b-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_B"' EXIT

echo "pass" > "$ARTIFACTS_DIR_B/test.result"
echo "pass" > "$ARTIFACTS_DIR_B/format.result"
echo "pass" > "$ARTIFACTS_DIR_B/lint.result"
echo "pass" > "$ARTIFACTS_DIR_B/classifier-dispatch.result"
# reviewer-record.result absent, reviewer-record.skipped absent

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_B")
assert_eq "test_missing_not_skipped" "1" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_ci_enforcement_generates_skips  [RED — verifier ignores .skipped today]
# enforcement.strategy=ci path: review steps may be skipped automatically.
# reviewer-record.skipped present (no .result), classifier-dispatch.skipped
# present (no .result), other 3 .result files present → verifier should exit 0.
# Currently exits 1 → RED.
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_C=$(mktemp -d "${TMPDIR:-/tmp}/test-skip-marker-c-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_C"' EXIT

echo "pass" > "$ARTIFACTS_DIR_C/test.result"
echo "pass" > "$ARTIFACTS_DIR_C/format.result"
echo "pass" > "$ARTIFACTS_DIR_C/lint.result"
echo "skipped" > "$ARTIFACTS_DIR_C/classifier-dispatch.skipped"
echo "skipped" > "$ARTIFACTS_DIR_C/reviewer-record.skipped"
# classifier-dispatch.result and reviewer-record.result intentionally absent

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_C")
assert_eq "test_ci_enforcement_generates_skips" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_skip_review_env_generates_skips  [RED — verifier ignores .skipped today]
# Simulates SKIP_REVIEW=true path: reviewer-record.skipped written instead of
# .result; all other 4 required .result files present → verifier should exit 0.
# Currently exits 1 → RED.
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_D=$(mktemp -d "${TMPDIR:-/tmp}/test-skip-marker-d-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_D"' EXIT

echo "pass" > "$ARTIFACTS_DIR_D/test.result"
echo "pass" > "$ARTIFACTS_DIR_D/format.result"
echo "pass" > "$ARTIFACTS_DIR_D/lint.result"
echo "pass" > "$ARTIFACTS_DIR_D/classifier-dispatch.result"
echo "skipped" > "$ARTIFACTS_DIR_D/reviewer-record.skipped"
# reviewer-record.result intentionally absent

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_D")
assert_eq "test_skip_review_env_generates_skips" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_combined_skip_conditions  [RED — verifier ignores .skipped today]
# Both CI enforcement strategy AND SKIP_REVIEW path active: both
# reviewer-record and classifier-dispatch have only .skipped markers (no
# .result). Other 3 steps have .result. Verifier should exit 0.
# Currently exits 1 → RED.
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_E=$(mktemp -d "${TMPDIR:-/tmp}/test-skip-marker-e-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_E"' EXIT

echo "pass" > "$ARTIFACTS_DIR_E/test.result"
echo "pass" > "$ARTIFACTS_DIR_E/format.result"
echo "pass" > "$ARTIFACTS_DIR_E/lint.result"
echo "skipped" > "$ARTIFACTS_DIR_E/classifier-dispatch.skipped"
echo "skipped" > "$ARTIFACTS_DIR_E/reviewer-record.skipped"
# classifier-dispatch.result and reviewer-record.result intentionally absent

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_E")
assert_eq "test_combined_skip_conditions" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
print_summary
