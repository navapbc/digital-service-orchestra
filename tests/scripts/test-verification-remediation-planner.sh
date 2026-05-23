#!/usr/bin/env bash
# tests/scripts/test-verification-remediation-planner.sh
# Behavioral contract tests for the dso:verification-remediation-planner agent.
#
# Tests verify that the agent file encodes required behavioral contracts:
# - Frontmatter with opus model requirement
# - 4-branch ordered decision tree (all 4 rule names present)
# - Complete output schema (all required fields)
# - Tiebreaker rules documented
# - upstream escalation enum values present
# - Fixtures are valid JSON
#
# All tests FAIL (RED) until the agent file and fixtures are created.
#
# Usage: bash tests/scripts/test-verification-remediation-planner.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# testing-mode: GREEN

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

AGENT_FILE="$REPO_ROOT/plugins/dso/agents/verification-remediation-planner.md"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures/verification-remediation-planner"

echo "=== test-verification-remediation-planner.sh ==="

# ── test_agent_file_exists ────────────────────────────────────────────────────
# The agent file must exist and be non-empty.
test_agent_file_exists() {
    _snapshot_fail
    if [[ -f "$AGENT_FILE" ]]; then
        assert_eq "test_agent_file_exists: file present" "exists" "exists"
    else
        assert_eq "test_agent_file_exists: file present" "exists" "missing"
    fi
    if [[ -f "$AGENT_FILE" && -s "$AGENT_FILE" ]]; then
        assert_eq "test_agent_file_exists: file is non-empty" "nonempty" "nonempty"
    else
        assert_eq "test_agent_file_exists: file is non-empty" "nonempty" "empty-or-missing"
    fi
    assert_pass_if_clean "test_agent_file_exists"
}

# ── test_model_is_opus ────────────────────────────────────────────────────────
# The agent frontmatter must declare model: opus.
# Contract: opus is mandatory for multi-document failure classification.
test_model_is_opus() {
    _snapshot_fail
    if [[ -f "$AGENT_FILE" ]]; then
        frontmatter=$(awk '/^---/{c++; if(c==2) exit} c{print}' "$AGENT_FILE")
        if grep -qE '^model:[[:space:]]*opus[[:space:]]*$' <<< "$frontmatter"; then
            actual_model="opus"
        else
            actual_model="missing"
        fi
    else
        actual_model="missing"
    fi
    assert_eq "test_model_is_opus: frontmatter model is opus" "opus" "$actual_model"
    assert_pass_if_clean "test_model_is_opus"
}

# ── test_decision_tree_has_4_rules ────────────────────────────────────────────
# All 4 decision-tree rule names must appear in the agent file.
# Contract: the agent must implement exactly 4 branches in order.
test_decision_tree_has_4_rules() {
    _snapshot_fail
    local file_content=""
    if [[ -f "$AGENT_FILE" ]]; then
        file_content=$(cat "$AGENT_FILE")
    fi

    RULES=(
        "replan_story"
        "new_tasks_in_story"
        "new_story_in_epic"
        "replan_epic"
    )

    for rule in "${RULES[@]}"; do
        if grep -q "$rule" "$AGENT_FILE" 2>/dev/null; then
            assert_eq "test_decision_tree_has_4_rules: rule '$rule' present" "present" "present"
        else
            assert_eq "test_decision_tree_has_4_rules: rule '$rule' present" "present" "missing"
        fi
    done
    assert_pass_if_clean "test_decision_tree_has_4_rules"
}

# ── test_output_schema_complete ───────────────────────────────────────────────
# All required output schema fields must appear in the agent file.
# Contract: downstream orchestrators parse these fields by name.
test_output_schema_complete() {
    _snapshot_fail
    SCHEMA_FIELDS=(
        "scope"
        "target_id"
        "decomposer_context"
        "escalation_upstream"
        "confidence"
    )

    for field in "${SCHEMA_FIELDS[@]}"; do
        if grep -q "\"$field\"" "$AGENT_FILE" 2>/dev/null; then
            assert_eq "test_output_schema_complete: field '$field' present" "present" "present"
        else
            assert_eq "test_output_schema_complete: field '$field' present" "present" "missing"
        fi
    done
    assert_pass_if_clean "test_output_schema_complete"
}

# ── test_tiebreaker_documented ────────────────────────────────────────────────
# The agent must document tiebreaker rules for the Rule 2/Rule 3 overlap case.
# Contract: without documented tiebreakers, agents emit inconsistent results
# when multiple rules match.
test_tiebreaker_documented() {
    _snapshot_fail
    if grep -qi "tiebreaker" "$AGENT_FILE" 2>/dev/null; then
        assert_eq "test_tiebreaker_documented: tiebreaker section present" "present" "present"
    else
        assert_eq "test_tiebreaker_documented: tiebreaker section present" "present" "missing"
    fi
    # Rule 2 beats Rule 3 must be documented
    if grep -q "new_tasks_in_story" "$AGENT_FILE" 2>/dev/null && grep -qi "beats\|wins\|short-circuit\|NON_LOW" "$AGENT_FILE" 2>/dev/null; then
        assert_eq "test_tiebreaker_documented: Rule 2 wins over Rule 3 documented" "present" "present"
    else
        assert_eq "test_tiebreaker_documented: Rule 2 wins over Rule 3 documented" "present" "missing"
    fi
    assert_pass_if_clean "test_tiebreaker_documented"
}

# ── test_fixtures_are_valid_json ──────────────────────────────────────────────
# All 5 fixture files must be valid JSON (python3 json.load).
# Contract: invalid fixture JSON silently breaks downstream fixture consumers.
test_fixtures_are_valid_json() {
    _snapshot_fail
    FIXTURES=(
        "fixture-replan-story.json"
        "fixture-new-tasks.json"
        "fixture-new-story.json"
        "fixture-replan-epic.json"
        "fixture-tiebreaker-overlap.json"
    )

    for fixture in "${FIXTURES[@]}"; do
        fixture_path="$FIXTURES_DIR/$fixture"
        if [[ ! -f "$fixture_path" ]]; then
            assert_eq "test_fixtures_are_valid_json: $fixture exists" "exists" "missing"
            continue
        fi
        if python3 -c "import json, sys; json.load(open('$fixture_path'))" 2>/dev/null; then
            assert_eq "test_fixtures_are_valid_json: $fixture is valid JSON" "valid" "valid"
        else
            assert_eq "test_fixtures_are_valid_json: $fixture is valid JSON" "valid" "invalid"
        fi
    done
    assert_pass_if_clean "test_fixtures_are_valid_json"
}

# ── test_upstream_enum_matches_protocol ───────────────────────────────────────
# All three escalation_upstream enum values must appear in the agent file.
# Contract: orchestrators switch on escalation_upstream to route remediation;
# missing values cause unhandled branches.
test_upstream_enum_matches_protocol() {
    _snapshot_fail
    UPSTREAM_VALUES=(
        "brainstorm"
        "preplanning"
        "planner_supplied"
    )

    for val in "${UPSTREAM_VALUES[@]}"; do
        if grep -q "$val" "$AGENT_FILE" 2>/dev/null; then
            assert_eq "test_upstream_enum_matches_protocol: '$val' present" "present" "present"
        else
            assert_eq "test_upstream_enum_matches_protocol: '$val' present" "present" "missing"
        fi
    done
    assert_pass_if_clean "test_upstream_enum_matches_protocol"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_agent_file_exists
test_model_is_opus
test_decision_tree_has_4_rules
test_output_schema_complete
test_tiebreaker_documented
test_fixtures_are_valid_json
test_upstream_enum_matches_protocol

print_summary
