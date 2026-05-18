#!/usr/bin/env bash
# tests/scripts/test-cycle-arbiter.sh
# Fixture-corpus replay tests for the cycle-end arbiter BLOCK/DEFER/DROP rulings.
# Each test loads a fixture and invokes compute_ruling_from_fixture() to exercise
# real arbiter logic (CoVe fallback + validation), not pre-authored answers.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

FIXTURE_DIR="$REPO_ROOT/tests/fixtures/arbiter"

PASS_COUNT=0
FAIL_COUNT=0

run_test() {
    local test_name="$1"
    local result="$2"
    if [[ "$result" == "PASS" ]]; then
        echo "PASS: $test_name"
        ((PASS_COUNT++))
    else
        echo "FAIL: $test_name — $result"
        ((FAIL_COUNT++))
    fi
}

# Helper: invoke compute_ruling_from_fixture and return the ruling value.
# Pass REPO_ROOT and fixture_file as argv (NOT heredoc string interpolation)
# so paths containing spaces or special characters don't break Python parsing
# (PR #204 review finding f-XXX).
compute_ruling() {
    local fixture_file="$1"
    REPO_ROOT="$REPO_ROOT" FIXTURE_FILE="$fixture_file" python3 - <<'PYEOF' 2>/dev/null
import json
import os
import sys
sys.path.insert(0, os.path.join(os.environ["REPO_ROOT"], "plugins/dso/scripts"))
from dso_ci_review.arbiter import compute_ruling_from_fixture
with open(os.environ["FIXTURE_FILE"]) as f:
    fixture = json.load(f)
result = compute_ruling_from_fixture(fixture)
print(result["ruling"])
PYEOF
}

# --- test functions ---

echo "--- test_block_critical_defense_absent_ruling"
test_block_critical_defense_absent_ruling() {
    local fixture="$FIXTURE_DIR/block-01-critical-no-defense.json"
    if [[ ! -f "$fixture" ]]; then
        run_test "test_block_critical_defense_absent_ruling" "FIXTURE_MISSING: $fixture"
        return
    fi
    local computed_ruling
    computed_ruling=$(compute_ruling "$fixture")
    if [[ "$computed_ruling" == "BLOCK" ]]; then
        run_test "test_block_critical_defense_absent_ruling" "PASS"
    else
        run_test "test_block_critical_defense_absent_ruling" "Expected BLOCK, got computed=$computed_ruling"
    fi
}
test_block_critical_defense_absent_ruling

echo "--- test_block_critical_defense_rejected_ruling"
test_block_critical_defense_rejected_ruling() {
    local fixture="$FIXTURE_DIR/block-02-critical-defense-rejected.json"
    if [[ ! -f "$fixture" ]]; then
        run_test "test_block_critical_defense_rejected_ruling" "FIXTURE_MISSING: $fixture"
        return
    fi
    local computed_ruling
    computed_ruling=$(compute_ruling "$fixture")
    if [[ "$computed_ruling" == "BLOCK" ]]; then
        run_test "test_block_critical_defense_rejected_ruling" "PASS"
    else
        run_test "test_block_critical_defense_rejected_ruling" "Expected BLOCK, got computed=$computed_ruling"
    fi
}
test_block_critical_defense_rejected_ruling

echo "--- test_defer_max_cycles_exceeded_ruling"
test_defer_max_cycles_exceeded_ruling() {
    local fixture="$FIXTURE_DIR/defer-01-max-cycles-exceeded.json"
    if [[ ! -f "$fixture" ]]; then
        run_test "test_defer_max_cycles_exceeded_ruling" "FIXTURE_MISSING: $fixture"
        return
    fi
    local computed_ruling
    computed_ruling=$(compute_ruling "$fixture")
    if [[ "$computed_ruling" == "DEFER" ]]; then
        run_test "test_defer_max_cycles_exceeded_ruling" "PASS"
    else
        run_test "test_defer_max_cycles_exceeded_ruling" "Expected DEFER, got computed=$computed_ruling"
    fi
}
test_defer_max_cycles_exceeded_ruling

echo "--- test_defer_noncritical_defense_absent_ruling"
test_defer_noncritical_defense_absent_ruling() {
    local fixture="$FIXTURE_DIR/defer-02-noncritical-no-defense.json"
    if [[ ! -f "$fixture" ]]; then
        run_test "test_defer_noncritical_defense_absent_ruling" "FIXTURE_MISSING: $fixture"
        return
    fi
    local computed_ruling
    computed_ruling=$(compute_ruling "$fixture")
    if [[ "$computed_ruling" == "DEFER" ]]; then
        run_test "test_defer_noncritical_defense_absent_ruling" "PASS"
    else
        run_test "test_defer_noncritical_defense_absent_ruling" "Expected DEFER, got computed=$computed_ruling"
    fi
}
test_defer_noncritical_defense_absent_ruling

echo "--- test_drop_accepted_defense_ruling"
test_drop_accepted_defense_ruling() {
    local fixture="$FIXTURE_DIR/drop-01-accepted-defense.json"
    if [[ ! -f "$fixture" ]]; then
        run_test "test_drop_accepted_defense_ruling" "FIXTURE_MISSING: $fixture"
        return
    fi
    local computed_ruling
    computed_ruling=$(compute_ruling "$fixture")
    if [[ "$computed_ruling" == "DROP" ]]; then
        run_test "test_drop_accepted_defense_ruling" "PASS"
    else
        run_test "test_drop_accepted_defense_ruling" "Expected DROP, got computed=$computed_ruling"
    fi
}
test_drop_accepted_defense_ruling

echo "--- test_drop_accepted_defense_no_evidence_lines_ruling"
test_drop_accepted_defense_no_evidence_lines_ruling() {
    local fixture="$FIXTURE_DIR/drop-02-no-new-evidence.json"
    if [[ ! -f "$fixture" ]]; then
        run_test "test_drop_accepted_defense_no_evidence_lines_ruling" "FIXTURE_MISSING: $fixture"
        return
    fi
    local computed_ruling
    computed_ruling=$(compute_ruling "$fixture")
    if [[ "$computed_ruling" == "DROP" ]]; then
        run_test "test_drop_accepted_defense_no_evidence_lines_ruling" "PASS"
    else
        run_test "test_drop_accepted_defense_no_evidence_lines_ruling" "Expected DROP, got computed=$computed_ruling"
    fi
}
test_drop_accepted_defense_no_evidence_lines_ruling

echo "--- test_block_impact_class_none_reclassified_to_defer"
test_block_impact_class_none_reclassified_to_defer() {
    local fixture="$FIXTURE_DIR/block-03-impact-class-none-reclassified.json"
    if [[ ! -f "$fixture" ]]; then
        run_test "test_block_impact_class_none_reclassified_to_defer" "FIXTURE_MISSING: $fixture"
        return
    fi
    # arbiter_ruling.ruling=BLOCK but impact_class='none' (outside 8-cat floor).
    # _enforce_impact_class_floor reclassifies BLOCK → DEFER.
    local computed_ruling
    computed_ruling=$(compute_ruling "$fixture")
    if [[ "$computed_ruling" == "DEFER" ]]; then
        run_test "test_block_impact_class_none_reclassified_to_defer" "PASS"
    else
        run_test "test_block_impact_class_none_reclassified_to_defer" "Expected DEFER (impact_class floor reclassification), got computed=$computed_ruling"
    fi
}
test_block_impact_class_none_reclassified_to_defer

echo "--- test_schema_collision_graceful_handling"
test_schema_collision_graceful_handling() {
    local fixture="$FIXTURE_DIR/schema-collision-01-old-and-new-fields.json"
    if [[ ! -f "$fixture" ]]; then
        run_test "test_schema_collision_graceful_handling" "FIXTURE_MISSING: $fixture"
        return
    fi
    # New schema (arbiter_ruling.ruling=BLOCK, cycle=1, max_cycles=4) takes precedence.
    # CoVe fallback does NOT reclassify (cycle 1 <= max_cycles 4).
    # old_schema_ruling_for_test field is ignored — assert BLOCK.
    local computed_ruling
    computed_ruling=$(compute_ruling "$fixture")
    if [[ "$computed_ruling" == "BLOCK" ]]; then
        run_test "test_schema_collision_graceful_handling" "PASS"
    else
        run_test "test_schema_collision_graceful_handling" "Expected BLOCK (new schema takes precedence), got computed=$computed_ruling"
    fi
}
test_schema_collision_graceful_handling

# --- summary ---
echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
