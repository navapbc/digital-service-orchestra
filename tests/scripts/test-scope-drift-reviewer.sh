#!/usr/bin/env bash
# tests/scripts/test-scope-drift-reviewer.sh
# TDD tests for dso:scope-drift-reviewer agent definition.
#
# Tests:
#  1. test_parsed_scope_checkpoint    — PARSED_SCOPE block exists AND contains constraint
#  2. test_gate_signal_format         — all 5 GATE_SIGNAL fields documented + drift_classification optional
#  3. test_drift_classification_values — in_scope, ambiguous, out_of_scope documented
#  4. test_scope_insufficient_halt    — scope_insufficient guard with STOP/halt instruction
#  5. test_heuristic_table_structure  — behavioral vs non-behavioral table with ≥3 examples each
#  6. test_consumers_table_updated    — gate-signal-schema.md consumers table has scope_drift row
#
# Usage: bash tests/scripts/test-scope-drift-reviewer.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_MD="$PLUGIN_ROOT/plugins/dso/agents/scope-drift-reviewer.md"
SCHEMA_MD="$PLUGIN_ROOT/plugins/dso/docs/contracts/gate-signal-schema.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-scope-drift-reviewer.sh ==="

# ── test_parsed_scope_checkpoint ─────────────────────────────────────────────
# 1. PARSED_SCOPE block must exist AND contain constraint about ordering
test_parsed_scope_checkpoint() {
    _snapshot_fail
    local _content
    _content=$(cat "$AGENT_MD")

    # Check PARSED_SCOPE block exists
    local _has_block=0
    if [[ "$_content" == *"PARSED_SCOPE"* ]]; then
        _has_block=1
    fi
    assert_eq "test_parsed_scope_checkpoint: PARSED_SCOPE block must exist" "1" "$_has_block"

    # Check constraint text
    local _has_constraint=0
    if [[ "$_content" == *"Do NOT read root_cause_report before PARSED_SCOPE block is complete"* ]]; then
        _has_constraint=1
    fi
    assert_eq "test_parsed_scope_checkpoint: must contain ordering constraint" "1" "$_has_constraint"

    assert_pass_if_clean "test_parsed_scope_checkpoint"
}

# ── test_gate_signal_format ───────────────────────────────────────────────────
# 2. All 5 GATE_SIGNAL fields documented AND drift_classification marked optional
test_gate_signal_format() {
    _snapshot_fail
    local _content
    _content=$(cat "$AGENT_MD")

    for field in gate_id triggered signal_type evidence confidence; do
        local _found=0
        if [[ "$_content" == *"$field"* ]]; then
            _found=1
        fi
        assert_eq "test_gate_signal_format: field '$field' must be documented" "1" "$_found"
    done

    # drift_classification must be documented as optional extension
    local _has_optional=0
    if [[ "$_content" == *"drift_classification"* ]] && \
       ( [[ "$_content" == *"optional"* ]] || [[ "$_content" == *"OPTIONAL"* ]] || [[ "$_content" == *"Optional"* ]] ); then
        _has_optional=1
    fi
    assert_eq "test_gate_signal_format: drift_classification must be documented as optional" "1" "$_has_optional"

    assert_pass_if_clean "test_gate_signal_format"
}

# ── test_drift_classification_values ─────────────────────────────────────────
# 3. Three-way classification values must be present
test_drift_classification_values() {
    _snapshot_fail
    local _content
    _content=$(cat "$AGENT_MD")

    for value in in_scope ambiguous out_of_scope; do
        local _found=0
        if [[ "$_content" == *"$value"* ]]; then
            _found=1
        fi
        assert_eq "test_drift_classification_values: classification value '$value' must be documented" "1" "$_found"
    done

    assert_pass_if_clean "test_drift_classification_values"
}

# ── test_scope_insufficient_halt ─────────────────────────────────────────────
# 4. scope_insufficient guard must be present with STOP or halt instruction
test_scope_insufficient_halt() {
    _snapshot_fail
    local _content
    _content=$(cat "$AGENT_MD")

    local _has_guard=0
    if [[ "$_content" == *"scope_insufficient"* ]]; then
        _has_guard=1
    fi
    assert_eq "test_scope_insufficient_halt: scope_insufficient guard must exist" "1" "$_has_guard"

    local _has_halt=0
    if [[ "$_content" == *"STOP"* ]] || [[ "$_content" == *"halt"* ]]; then
        _has_halt=1
    fi
    assert_eq "test_scope_insufficient_halt: must contain STOP or halt instruction" "1" "$_has_halt"

    assert_pass_if_clean "test_scope_insufficient_halt"
}

# ── test_heuristic_table_structure ───────────────────────────────────────────
# 5. Behavioral vs non-behavioral heuristic table with at least 3 examples each
test_heuristic_table_structure() {
    _snapshot_fail
    local _content
    _content=$(cat "$AGENT_MD")

    # Check both column headers exist
    local _has_behavioral=0
    if [[ "$_content" == *"Behavioral"* ]]; then
        _has_behavioral=1
    fi
    assert_eq "test_heuristic_table_structure: Behavioral column header must exist" "1" "$_has_behavioral"

    local _has_non_behavioral=0
    if [[ "$_content" == *"Non-Behavioral"* ]]; then
        _has_non_behavioral=1
    fi
    assert_eq "test_heuristic_table_structure: Non-Behavioral column header must exist" "1" "$_has_non_behavioral"

    # Check behavioral examples
    local _has_observable=0
    if [[ "$_content" == *"observable output"* ]] || [[ "$_content" == *"observable"* ]]; then
        _has_observable=1
    fi
    assert_eq "test_heuristic_table_structure: observable output example must be present" "1" "$_has_observable"

    local _has_state_transition=0
    if [[ "$_content" == *"state transition"* ]]; then
        _has_state_transition=1
    fi
    assert_eq "test_heuristic_table_structure: state transition example must be present" "1" "$_has_state_transition"

    local _has_api_contract=0
    if [[ "$_content" == *"API contract"* ]]; then
        _has_api_contract=1
    fi
    assert_eq "test_heuristic_table_structure: API contract example must be present" "1" "$_has_api_contract"

    # Check non-behavioral examples
    local _has_variable_rename=0
    if [[ "$_content" == *"variable rename"* ]]; then
        _has_variable_rename=1
    fi
    assert_eq "test_heuristic_table_structure: variable rename example must be present" "1" "$_has_variable_rename"

    local _has_comment_edit=0
    if [[ "$_content" == *"comment edit"* ]]; then
        _has_comment_edit=1
    fi
    assert_eq "test_heuristic_table_structure: comment edit example must be present" "1" "$_has_comment_edit"

    local _has_test_helper=0
    if [[ "$_content" == *"test-helper refactor"* ]] || [[ "$_content" == *"test helper"* ]]; then
        _has_test_helper=1
    fi
    assert_eq "test_heuristic_table_structure: test-helper refactor example must be present" "1" "$_has_test_helper"

    assert_pass_if_clean "test_heuristic_table_structure"
}

# ── test_consumers_table_updated ─────────────────────────────────────────────
# 6. gate-signal-schema.md Consumers table must have scope_drift row
# NOTE: This test will be RED until Task C updates gate-signal-schema.md
test_consumers_table_updated() {
    _snapshot_fail
    local _schema_content
    _schema_content=$(cat "$SCHEMA_MD")

    local _has_scope_drift=0
    if [[ "$_schema_content" == *"scope_drift"* ]]; then
        _has_scope_drift=1
    fi
    assert_eq "test_consumers_table_updated: gate-signal-schema.md must contain scope_drift row" "1" "$_has_scope_drift"

    assert_pass_if_clean "test_consumers_table_updated"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_parsed_scope_checkpoint
test_gate_signal_format
test_drift_classification_values
test_scope_insufficient_halt
test_heuristic_table_structure
test_consumers_table_updated

print_summary
