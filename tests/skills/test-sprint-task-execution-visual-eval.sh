#!/usr/bin/env bash
# Tests for Sprint Integration A documented in task-execution.md
set -euo pipefail

SKILL_FILE="plugins/dso/skills/sprint/prompts/task-execution.md"

# Assert the file exists and contains required documentation
test -f "$SKILL_FILE" || { echo "FAIL: $SKILL_FILE not found"; exit 1; }

pass_count=0
fail_count=0

assert_contains() {
    local needle="$1"
    local message="$2"
    if grep -q "$needle" "$SKILL_FILE"; then
        echo "PASS: $message"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $message (missing: $needle)"
        fail_count=$((fail_count + 1))
    fi
}

# test_sustained_intent_match_drift_fails_closure
assert_contains "intent_match < threshold" "test_sustained_intent_match_drift_fails_closure: intent_match block documented"
assert_contains "iteration_cap" "iteration_cap documented"
assert_contains "FAILED" "task FAIL behavior documented"

# test_quality_dim_shortfall_visual_debt_annotated
assert_contains "visual_debt" "test_quality_dim_shortfall_visual_debt_annotated: visual_debt annotation documented"
assert_contains "whitespace_balance" "quality-dim shortfall documented"

# test_mixed_uncertain_findings_auto_defer
assert_contains "INTERACTIVITY_DEFERRED" "test_mixed_uncertain_findings_auto_defer: mixed/uncertain handling documented"
assert_contains "review.max_cycles" "iteration_cap independence from review.max_cycles documented"
assert_contains "route_map_stale" "route_map_stale prominent surfacing documented"
assert_contains "attribution_class" "attribution routing by attribution_class documented"

echo ""
echo "PASSED: $pass_count  FAILED: $fail_count"
test "$fail_count" -eq 0
