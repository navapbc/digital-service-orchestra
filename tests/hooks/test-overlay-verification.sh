#!/usr/bin/env bash
# tests/hooks/test-overlay-verification.sh
# RED tests for overlay-specific artifact verification in pre-commit-compliance-verifier.sh
#
# Task ccf9-1f1a-1b64-46cc: overlay verification in pre-commit-compliance-verifier.sh
#
# The verifier currently only checks 5 required base step artifacts:
#   (test format lint classifier-dispatch reviewer-record)
# It does NOT yet check overlay-specific findings files.
#
# Tests 2, 4, 5 (overlay-flagged → missing findings → exits 1) are RED until
# the GREEN task adds overlay verification to the verifier.
# Test 1 (no overlays → exits 0) and Test 3 (security overlay + present findings → exits 0)
# may already pass.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/plugins/dso/hooks/pre-commit-compliance-verifier.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

# ---------------------------------------------------------------------------
# Helper: write all 5 required base step artifacts into a directory
# ---------------------------------------------------------------------------
write_base_artifacts() {
    local dir="$1"
    printf '{"step":"test","exit_code":0,"stdout":"","stderr":"","timestamp":"2026-01-01T00:00:00Z"}\n' \
        > "$dir/test.result"
    printf '{"step":"format","exit_code":0,"stdout":"","stderr":"","timestamp":"2026-01-01T00:00:00Z"}\n' \
        > "$dir/format.result"
    printf '{"step":"lint","exit_code":0,"stdout":"","stderr":"","timestamp":"2026-01-01T00:00:00Z"}\n' \
        > "$dir/lint.result"
    printf '{"step":"reviewer-record","exit_code":0,"stdout":"","stderr":"","timestamp":"2026-01-01T00:00:00Z"}\n' \
        > "$dir/reviewer-record.result"
}

# Helper: run hook, return exit code
run_hook() {
    local exit_code=0
    env "$@" bash "$HOOK" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# ---------------------------------------------------------------------------
# test_no_overlays_no_check
# classifier-dispatch.result has "overlays": [] — no overlay-specific artifacts
# required. All 5 base artifacts present. Verifier should exit 0.
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_1=$(mktemp -d "${TMPDIR:-/tmp}/test-overlay-none-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_1"' EXIT

write_base_artifacts "$ARTIFACTS_DIR_1"
# classifier-dispatch result with empty overlays array
printf '{"step":"classifier-dispatch","exit_code":0,"stdout":"{\"overlays\":[]}","stderr":"","timestamp":"2026-01-01T00:00:00Z"}\n' \
    > "$ARTIFACTS_DIR_1/classifier-dispatch.result"

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_1")
assert_eq "test_no_overlays_no_check" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_security_overlay_flagged_missing
# classifier-dispatch.result has "overlays": ["security"].
# security-redteam-findings.json is ABSENT from ARTIFACTS_DIR.
# Verifier should exit 1 (blocked).
# Currently RED: verifier does not check overlay findings yet → exits 0.
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_2=$(mktemp -d "${TMPDIR:-/tmp}/test-overlay-sec-miss-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_2"' EXIT

write_base_artifacts "$ARTIFACTS_DIR_2"
printf '{"step":"classifier-dispatch","exit_code":0,"stdout":"{\"overlays\":[\"security\"]}","stderr":"","timestamp":"2026-01-01T00:00:00Z"}\n' \
    > "$ARTIFACTS_DIR_2/classifier-dispatch.result"
# Intentionally omit security-redteam-findings.json

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_2")
assert_eq "test_security_overlay_flagged_missing" "1" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_security_overlay_flagged_present
# classifier-dispatch.result has "overlays": ["security"].
# security-redteam-findings.json IS present in ARTIFACTS_DIR.
# Verifier should exit 0.
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_3=$(mktemp -d "${TMPDIR:-/tmp}/test-overlay-sec-pres-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_3"' EXIT

write_base_artifacts "$ARTIFACTS_DIR_3"
printf '{"step":"classifier-dispatch","exit_code":0,"stdout":"{\"overlays\":[\"security\"]}","stderr":"","timestamp":"2026-01-01T00:00:00Z"}\n' \
    > "$ARTIFACTS_DIR_3/classifier-dispatch.result"
printf '{"overlay":"security","findings":[],"timestamp":"2026-01-01T00:00:00Z"}\n' \
    > "$ARTIFACTS_DIR_3/security-redteam-findings.json"

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_3")
assert_eq "test_security_overlay_flagged_present" "0" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_registry_driven
# classifier-dispatch.result has "overlays": ["performance"].
# Registry maps "performance" → "performance-findings.json".
# performance-findings.json is ABSENT → verifier should exit 1.
# Currently RED: verifier does not check overlay findings yet → exits 0.
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_4=$(mktemp -d "${TMPDIR:-/tmp}/test-overlay-perf-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_4"' EXIT

write_base_artifacts "$ARTIFACTS_DIR_4"
printf '{"step":"classifier-dispatch","exit_code":0,"stdout":"{\"overlays\":[\"performance\"]}","stderr":"","timestamp":"2026-01-01T00:00:00Z"}\n' \
    > "$ARTIFACTS_DIR_4/classifier-dispatch.result"
# Intentionally omit performance-findings.json

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_4")
assert_eq "test_registry_driven" "1" "$EXIT_CODE"

# ---------------------------------------------------------------------------
# test_bug_94e8_9f91_regression
# Regression test for bug 94e8-9f91: overlay-flagged commits were not blocked.
# Simulate: classifier-dispatch.result flags overlays: ["security"].
# No security-redteam-findings.json present.
# Confirm verifier exits 1 and blocks commit.
# Currently RED: verifier does not check overlay findings yet → exits 0.
# ---------------------------------------------------------------------------
ARTIFACTS_DIR_5=$(mktemp -d "${TMPDIR:-/tmp}/test-overlay-regression-XXXXXX")
trap 'rm -rf "$ARTIFACTS_DIR_5"' EXIT

write_base_artifacts "$ARTIFACTS_DIR_5"
printf '{"step":"classifier-dispatch","exit_code":0,"stdout":"{\"overlays\":[\"security\"]}","stderr":"","timestamp":"2026-01-01T00:00:00Z"}\n' \
    > "$ARTIFACTS_DIR_5/classifier-dispatch.result"
# security-redteam-findings.json intentionally absent to reproduce the bug

EXIT_CODE=$(run_hook \
    "DSO_COMPLIANCE_VERIFIER_ENABLED=true" \
    "WORKFLOW_PLUGIN_ARTIFACTS_DIR=$ARTIFACTS_DIR_5")
assert_eq "test_bug_94e8_9f91_regression" "1" "$EXIT_CODE"

# ---------------------------------------------------------------------------
print_summary
