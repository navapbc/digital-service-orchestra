#!/usr/bin/env bash
# tests/skills/test-end-session-rationalized-failures.sh
# Structural validation tests for the rationalized-failures accountability step
# in plugins/dso/skills/end-session/SKILL.md.
#
#
# Tests (structural gates only — content-greps removed in Phase 5 sweep):
#   1. test_step6_references_stored_failures   — final report step references RATIONALIZED_FAILURES_FROM_STEP_5 (cross-step variable contract)
#   2. test_step_ordering_before_learnings     — rationalized-failures step appears before Extract Technical Learnings step
#
# Usage: bash tests/skills/test-end-session-rationalized-failures.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_MD="$DSO_PLUGIN_DIR/skills/end-session/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-end-session-rationalized-failures.sh ==="

# ---------------------------------------------------------------------------
# test_step6_references_stored_failures
# The final report step must reference the stored variable
# RATIONALIZED_FAILURES_FROM_STEP_5, written by the rationalized-failures step.
# ---------------------------------------------------------------------------
_snapshot_fail
step6_content=$(awk '/^### .* Report: Task Summary/,0' "$SKILL_MD" 2>/dev/null || true)
if grep -q "RATIONALIZED_FAILURES_FROM_STEP_5" <<< "$step6_content"; then
    has_var_ref="found"
else
    has_var_ref="missing"
fi
assert_eq "test_step6_references_stored_failures" "found" "$has_var_ref"
assert_pass_if_clean "test_step6_references_stored_failures"

# ---------------------------------------------------------------------------
# test_step_ordering_before_learnings
# The rationalized-failures step must appear BEFORE the Extract Technical Learnings step. Verified by comparing line numbers in SKILL.md.
# ---------------------------------------------------------------------------
_snapshot_fail
rationalized_line=$(grep -n "Rationalized Failures" "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1 || true)
learnings_line=$(grep -nE "^### .* Extract Technical Learnings" "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1 || true)
if [[ -n "$rationalized_line" && -n "$learnings_line" && "$rationalized_line" -lt "$learnings_line" ]]; then
    ordering_ok="yes"
else
    ordering_ok="no"
fi
assert_eq "test_step_ordering_before_learnings" "yes" "$ordering_ok"
assert_pass_if_clean "test_step_ordering_before_learnings"

print_summary
