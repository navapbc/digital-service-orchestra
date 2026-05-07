#!/usr/bin/env bash
# Tests that CLAUDE.md contains the required CI llm-review architecture entries.
# Behavioral boundary: tests the structural presence of documented keywords —
# not the content of the documentation itself.
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
# Content trimmed from CLAUDE.md (PR #66) was relocated to CI-INTEGRATION.md.
TARGET_DOC="$REPO_ROOT/plugins/dso/docs/CI-INTEGRATION.md"

pass=0
fail=0

_assert_contains() {
    local description="$1"
    local pattern="$2"
    if grep -qF "$pattern" "$TARGET_DOC"; then
        echo "PASS: $description"
        ((pass++)) || true
    else
        echo "FAIL: $description — pattern not found: $pattern"
        ((fail++)) || true
    fi
}

_assert_contains_icase_regex() {
    local description="$1"
    local pattern="$2"
    if grep -qiE "$pattern" "$TARGET_DOC"; then
        echo "PASS: $description"
        ((pass++)) || true
    else
        echo "FAIL: $description — pattern not found (case-insensitive regex): $pattern"
        ((fail++)) || true
    fi
}

# CI llm-review orchestrator entry
_assert_contains "ci-llm-review-runner.sh referenced" "ci-llm-review-runner.sh"
_assert_contains "llm-api-call.sh dispatch referenced" "llm-api-call.sh"
_assert_contains "source-of-truth marker file referenced" ".dso-source-of-truth"
_assert_contains "parallel overlay dispatch documented" "fan-out"
# Tolerate markdown emphasis between "not" and "consult" (e.g., "Does **not** consult").
_assert_contains_icase_regex "check-usage.sh exclusion documented" "not(\\*\\*)? consult"

# CI version resolution chain entry
_assert_contains "CI version resolution entry present" "CI version resolution"
_assert_contains "3-tier fallback documented" "3-tier"
_assert_contains "dso channel fallback documented" "falls back to"
_assert_contains "dso-dev channel fallback documented" "dso-dev"

echo ""
echo "Results: $pass passed, $fail failed"
if [[ $fail -gt 0 ]]; then
    exit 1
fi
