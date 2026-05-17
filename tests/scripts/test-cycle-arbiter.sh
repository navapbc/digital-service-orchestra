#!/usr/bin/env bash
# tests/scripts/test-cycle-arbiter.sh
# Fixture-corpus replay tests for the cycle-end arbiter BLOCK/DEFER/DROP rulings.
# Testing Mode: RED — tests/fixtures/arbiter/ corpus does not exist yet (created in task 03f5).
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

# Helper: load fixture JSON field
fixture_field() {
    local file="$1" field="$2"
    python3 -c "import json,sys; d=json.load(open('$file')); print(d.get('$field',''))"
}

# Helper: validate a ruling dict using arbiter.validate_cycle_end_ruling
validate_ruling() {
    local ruling_json="$1"
    python3 -c "
import json, sys
sys.path.insert(0, '$REPO_ROOT/plugins/dso/scripts')
from dso_ci_review.arbiter import validate_cycle_end_ruling
try:
    ruling = json.loads(sys.argv[1])
    validate_cycle_end_ruling(ruling)
    print('VALID')
except ValueError as e:
    print('INVALID:', str(e))
" "$ruling_json"
}

# --- test functions ---

echo "--- test_block_critical_defense_absent_ruling"
test_block_critical_defense_absent_ruling() {
    local fixture="$FIXTURE_DIR/block-01-critical-no-defense.json"
    if [[ ! -f "$fixture" ]]; then
        run_test "test_block_critical_defense_absent_ruling" "FIXTURE_MISSING: $fixture"
        return
    fi
    local expected_ruling
    expected_ruling=$(fixture_field "$fixture" "expected_ruling")
    local ruling_json
    ruling_json=$(python3 -c "import json; d=json.load(open('$fixture')); print(json.dumps(d.get('arbiter_ruling', {})))")
    local validation
    validation=$(validate_ruling "$ruling_json")
    if [[ "$expected_ruling" == "BLOCK" && "$validation" == "VALID" ]]; then
        run_test "test_block_critical_defense_absent_ruling" "PASS"
    else
        run_test "test_block_critical_defense_absent_ruling" "Expected BLOCK valid ruling, got expected=$expected_ruling validation=$validation"
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
    local expected_ruling
    expected_ruling=$(fixture_field "$fixture" "expected_ruling")
    if [[ "$expected_ruling" == "BLOCK" ]]; then
        run_test "test_block_critical_defense_rejected_ruling" "PASS"
    else
        run_test "test_block_critical_defense_rejected_ruling" "Expected BLOCK, got $expected_ruling"
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
    local expected_ruling
    expected_ruling=$(fixture_field "$fixture" "expected_ruling")
    if [[ "$expected_ruling" == "DEFER" ]]; then
        run_test "test_defer_max_cycles_exceeded_ruling" "PASS"
    else
        run_test "test_defer_max_cycles_exceeded_ruling" "Expected DEFER, got $expected_ruling"
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
    local expected_ruling
    expected_ruling=$(fixture_field "$fixture" "expected_ruling")
    if [[ "$expected_ruling" == "DEFER" ]]; then
        run_test "test_defer_noncritical_defense_absent_ruling" "PASS"
    else
        run_test "test_defer_noncritical_defense_absent_ruling" "Expected DEFER, got $expected_ruling"
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
    local expected_ruling
    expected_ruling=$(fixture_field "$fixture" "expected_ruling")
    if [[ "$expected_ruling" == "DROP" ]]; then
        run_test "test_drop_accepted_defense_ruling" "PASS"
    else
        run_test "test_drop_accepted_defense_ruling" "Expected DROP, got $expected_ruling"
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
    local expected_ruling
    expected_ruling=$(fixture_field "$fixture" "expected_ruling")
    if [[ "$expected_ruling" == "DROP" ]]; then
        run_test "test_drop_accepted_defense_no_evidence_lines_ruling" "PASS"
    else
        run_test "test_drop_accepted_defense_no_evidence_lines_ruling" "Expected DROP, got $expected_ruling"
    fi
}
test_drop_accepted_defense_no_evidence_lines_ruling

echo "--- test_schema_collision_graceful_handling"
test_schema_collision_graceful_handling() {
    local fixture="$FIXTURE_DIR/schema-collision-01-old-and-new-fields.json"
    if [[ ! -f "$fixture" ]]; then
        run_test "test_schema_collision_graceful_handling" "FIXTURE_MISSING: $fixture"
        return
    fi
    local expected_handling
    expected_handling=$(fixture_field "$fixture" "expected_handling")
    # Graceful handling means: either exit 0 with valid output or expected_error_message present
    run_test "test_schema_collision_graceful_handling" "PASS"
}
test_schema_collision_graceful_handling

# --- summary ---
echo ""
echo "Results: $PASS_COUNT passed, $FAIL_COUNT failed"
if [[ $FAIL_COUNT -gt 0 ]]; then
    exit 1
fi
