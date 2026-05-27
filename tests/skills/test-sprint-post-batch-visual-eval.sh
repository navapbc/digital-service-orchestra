#!/usr/bin/env bash
# Tests for Sprint Integration B (post-batch visual-evaluator dispatch)
set -euo pipefail

SKILL_FILE="plugins/dso/skills/sprint/SKILL.md"

test -f "$SKILL_FILE" || { echo "FAIL: $SKILL_FILE not found"; exit 1; }

pass_count=0
fail_count=0

assert_contains() {
    local needle="$1"
    local message="$2"
    if grep -qE "$needle" "$SKILL_FILE"; then
        echo "PASS: $message"
        pass_count=$((pass_count + 1))
    else
        echo "FAIL: $message (missing pattern: $needle)"
        fail_count=$((fail_count + 1))
    fi
}

# test_soft_warn_below_threshold
assert_contains "post_batch_token_budget" "post_batch_token_budget config key documented"
assert_contains "50000|50,000" "default 50000 token budget documented"

# test_soft_warn_above_threshold
assert_contains "visual_eval_post_batch_nearing_budget" "soft-warn degradation_type documented"
assert_contains "[Ss]oft.warn" "soft-warn path documented"

# test_hard_stop_above_3x
assert_contains "visual_eval_post_batch_skipped_budget_exceeded" "hard-stop degradation_type documented"
assert_contains "post_batch_token_hard_stop_multiplier" "hard-stop multiplier config key documented"
assert_contains "4-reviewer|4.reviewer" "4-reviewer fallback documented"
assert_contains "Opus 4\.7|opus 4\.7" "Opus 4.7 dispatch model documented"

echo ""
echo "PASSED: $pass_count  FAILED: $fail_count"
test "$fail_count" -eq 0
