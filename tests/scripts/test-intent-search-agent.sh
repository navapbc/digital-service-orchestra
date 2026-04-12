#!/usr/bin/env bash
# tests/scripts/test-intent-search-agent.sh
# TDD tests for dso:intent-search agent definition (story b9b9-18e3).
#
# Tests:
#  1. test_step_7b_exists                  — 'Step 7b' section exists in intent-search.md
#  2. test_traversal_checkpoint_protocol  — 'TRAVERSAL_CHECKPOINT' signal documented
#  3. test_intent_conflict_signal_fields  — behavioral_claim, conflicting_callers,
#                                           dependency_classification all present
#  4. test_dependency_classification_enum — behavioral_dependency and incidental_usage documented
#  5. test_traversal_level_cap            — 3-level traversal cap documented
#  6. test_budget_cap_advisory            — 'advisory' used for historical-search budget
#  7. test_gate_signal_schema_updated     — gate-signal-schema.md Consumers section has
#                                           b9b9-18e3 or INTENT_CONFLICT
#
# Usage: bash tests/scripts/test-intent-search-agent.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_MD="$PLUGIN_ROOT/plugins/dso/agents/intent-search.md"
SCHEMA_MD="$PLUGIN_ROOT/plugins/dso/docs/contracts/gate-signal-schema.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-intent-search-agent.sh ==="

# ── test_step_7b_exists ──────────────────────────────────────────────────────
# 1. Step 7b section must exist in intent-search.md
test_step_7b_exists() {
    _snapshot_fail
    local _content
    _content=$(cat "$AGENT_MD")

    local _has_step_7b=0
    if [[ "$_content" == *"Step 7b"* ]]; then
        _has_step_7b=1
    fi
    assert_eq "test_step_7b_exists: Step 7b section must exist in intent-search.md" "1" "$_has_step_7b"

    assert_pass_if_clean "test_step_7b_exists"
}

# ── test_traversal_checkpoint_protocol ──────────────────────────────────────
# 2. TRAVERSAL_CHECKPOINT signal must be documented
test_traversal_checkpoint_protocol() {
    _snapshot_fail
    local _content
    _content=$(cat "$AGENT_MD")

    local _has_checkpoint=0
    if [[ "$_content" == *"TRAVERSAL_CHECKPOINT"* ]]; then
        _has_checkpoint=1
    fi
    assert_eq "test_traversal_checkpoint_protocol: TRAVERSAL_CHECKPOINT must be documented in intent-search.md" "1" "$_has_checkpoint"

    assert_pass_if_clean "test_traversal_checkpoint_protocol"
}

# ── test_intent_conflict_signal_fields ──────────────────────────────────────
# 3. All 3 INTENT_CONFLICT extension fields must be present
test_intent_conflict_signal_fields() {
    _snapshot_fail
    local _content
    _content=$(cat "$AGENT_MD")

    local _has_behavioral_claim=0
    if [[ "$_content" == *"behavioral_claim"* ]]; then
        _has_behavioral_claim=1
    fi
    assert_eq "test_intent_conflict_signal_fields: behavioral_claim must be documented" "1" "$_has_behavioral_claim"

    local _has_conflicting_callers=0
    if [[ "$_content" == *"conflicting_callers"* ]]; then
        _has_conflicting_callers=1
    fi
    assert_eq "test_intent_conflict_signal_fields: conflicting_callers must be documented" "1" "$_has_conflicting_callers"

    local _has_dependency_classification=0
    if [[ "$_content" == *"dependency_classification"* ]]; then
        _has_dependency_classification=1
    fi
    assert_eq "test_intent_conflict_signal_fields: dependency_classification must be documented" "1" "$_has_dependency_classification"

    assert_pass_if_clean "test_intent_conflict_signal_fields"
}

# ── test_dependency_classification_enum ─────────────────────────────────────
# 4. Both enum values for dependency_classification must be present
test_dependency_classification_enum() {
    _snapshot_fail
    local _content
    _content=$(cat "$AGENT_MD")

    local _has_behavioral_dependency=0
    if [[ "$_content" == *"behavioral_dependency"* ]]; then
        _has_behavioral_dependency=1
    fi
    assert_eq "test_dependency_classification_enum: behavioral_dependency must be documented" "1" "$_has_behavioral_dependency"

    local _has_incidental_usage=0
    if [[ "$_content" == *"incidental_usage"* ]]; then
        _has_incidental_usage=1
    fi
    assert_eq "test_dependency_classification_enum: incidental_usage must be documented" "1" "$_has_incidental_usage"

    assert_pass_if_clean "test_dependency_classification_enum"
}

# ── test_traversal_level_cap ─────────────────────────────────────────────────
# 5. 3-level traversal cap must be documented near 'level' context
test_traversal_level_cap() {
    _snapshot_fail
    local _content
    _content=$(cat "$AGENT_MD")

    # The 3-level cap: look for '3' appearing near 'level' or 'traversal'
    local _has_cap=0
    if [[ "$_content" == *"3 traversal level"* ]] || \
       [[ "$_content" == *"traversal levels maximum"* ]] || \
       [[ "$_content" == *"3-level"* ]] || \
       [[ "$_content" == *"Cap at 3"* ]] || \
       [[ "$_content" == *"cap at 3"* ]] || \
       [[ "$_content" == *"3 levels"* ]]; then
        _has_cap=1
    fi
    assert_eq "test_traversal_level_cap: 3-level traversal cap must be documented" "1" "$_has_cap"

    assert_pass_if_clean "test_traversal_level_cap"
}

# ── test_budget_cap_advisory ─────────────────────────────────────────────────
# 6. 'advisory' must appear in intent-search.md (budget is advisory for historical search)
test_budget_cap_advisory() {
    _snapshot_fail
    local _content
    _content=$(cat "$AGENT_MD")

    local _has_advisory=0
    if [[ "$_content" == *"advisory"* ]]; then
        _has_advisory=1
    fi
    assert_eq "test_budget_cap_advisory: 'advisory' must be present in intent-search.md" "1" "$_has_advisory"

    assert_pass_if_clean "test_budget_cap_advisory"
}

# ── test_gate_signal_schema_updated ─────────────────────────────────────────
# 7. gate-signal-schema.md Consumers section must have b9b9-18e3 or INTENT_CONFLICT
test_gate_signal_schema_updated() {
    _snapshot_fail
    local _schema_content
    _schema_content=$(cat "$SCHEMA_MD")

    local _has_row=0
    if [[ "$_schema_content" == *"b9b9-18e3"* ]] || [[ "$_schema_content" == *"INTENT_CONFLICT"* ]]; then
        _has_row=1
    fi
    assert_eq "test_gate_signal_schema_updated: gate-signal-schema.md Consumers must reference b9b9-18e3 or INTENT_CONFLICT" "1" "$_has_row"

    assert_pass_if_clean "test_gate_signal_schema_updated"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_step_7b_exists
test_traversal_checkpoint_protocol
test_intent_conflict_signal_fields
test_dependency_classification_enum
test_traversal_level_cap
test_budget_cap_advisory
test_gate_signal_schema_updated

print_summary
