#!/usr/bin/env bash
# tests/scripts/test-doc-writer-agent.sh
# Behavioral tests for the dso:doc-writer agent specification.
#
# These tests verify that the agent file at plugins/dso/agents/doc-writer.md
# encodes the required behavioral contracts: decision engine gate ordering,
# 4-tier documentation schema, breakout heuristics, safeguard guards, and
# input/output contracts.
#
# All tests FAIL (RED) until the agent file is created with correct content.
#
# Usage: bash tests/scripts/test-doc-writer-agent.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_FILE="$PLUGIN_ROOT/plugins/dso/agents/doc-writer.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-doc-writer-agent.sh ==="

# ── test_agent_file_exists ───────────────────────────────────────────────────
# The agent file must exist and be non-empty.
# RED: file does not exist yet — both assertions fail.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    actual_exists="exists"
else
    actual_exists="missing"
fi
assert_eq "test_agent_file_exists: file present at plugins/dso/agents/doc-writer.md" "exists" "$actual_exists"

if [[ -f "$AGENT_FILE" && -s "$AGENT_FILE" ]]; then
    actual_nonempty="nonempty"
else
    actual_nonempty="empty-or-missing"
fi
assert_eq "test_agent_file_exists: file is non-empty" "nonempty" "$actual_nonempty"
assert_pass_if_clean "test_agent_file_exists"

# ── test_frontmatter_fields ──────────────────────────────────────────────────
# YAML frontmatter must contain name: doc-writer, model: sonnet, description field.
# Contract: callers rely on the routing name and model tier to dispatch correctly.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    frontmatter=$(awk '/^---/{c++; if(c==2) exit} c && FNR>200{exit}' "$AGENT_FILE")
    if echo "$frontmatter" | grep -qE '^name:[[:space:]]*doc-writer[[:space:]]*$'; then
        actual_name="present"
    else
        actual_name="missing"
    fi
    if echo "$frontmatter" | grep -qE '^model:[[:space:]]*sonnet[[:space:]]*$'; then
        actual_model="present"
    else
        actual_model="missing"
    fi
    if echo "$frontmatter" | grep -qE '^description:'; then
        actual_desc="present"
    else
        actual_desc="missing"
    fi
else
    actual_name="missing"
    actual_model="missing"
    actual_desc="missing"
fi
assert_eq "test_frontmatter_fields: name is doc-writer" "present" "$actual_name"
assert_eq "test_frontmatter_fields: model is sonnet" "present" "$actual_model"
assert_eq "test_frontmatter_fields: description field present" "present" "$actual_desc"
assert_pass_if_clean "test_frontmatter_fields"

# ── test_decision_gate_order ─────────────────────────────────────────────────
# Decision engine gates must appear in this order: No-Op → User Impact →
# Architectural → Constraint. Order matters: cheaper gates run first.
# A file with gates in wrong order or missing gates fails this test.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    content=$(cat "$AGENT_FILE")

    # Extract line numbers for each required gate label
    noop_line=$(grep -ni "no.op" "$AGENT_FILE" | head -1 | cut -d: -f1)
    user_impact_line=$(grep -ni "user impact" "$AGENT_FILE" | head -1 | cut -d: -f1)
    architectural_line=$(grep -ni "architectural" "$AGENT_FILE" | head -1 | cut -d: -f1)
    constraint_line=$(grep -ni "constraint" "$AGENT_FILE" | head -1 | cut -d: -f1)

    # All four must be present
    if [[ -n "$noop_line" && -n "$user_impact_line" && -n "$architectural_line" && -n "$constraint_line" ]]; then
        actual_present="all-present"
    else
        actual_present="missing-gates"
    fi
    assert_eq "test_decision_gate_order: all four gates present" "all-present" "$actual_present"

    # Order: No-Op < User Impact < Architectural < Constraint
    if [[ -n "$noop_line" && -n "$user_impact_line" && -n "$architectural_line" && -n "$constraint_line" ]]; then
        if (( noop_line < user_impact_line && user_impact_line < architectural_line && architectural_line < constraint_line )); then
            actual_order="correct"
        else
            actual_order="wrong-order"
        fi
    else
        actual_order="wrong-order"
    fi
    assert_eq "test_decision_gate_order: No-Op before User Impact before Architectural before Constraint" "correct" "$actual_order"
else
    assert_eq "test_decision_gate_order: all four gates present" "all-present" "missing-gates"
    assert_eq "test_decision_gate_order: gate ordering" "correct" "wrong-order"
fi
assert_pass_if_clean "test_decision_gate_order"

# ── test_documentation_schema_sections ──────────────────────────────────────
# All four tiers of the documentation schema must be named in the agent file.
# Contract: the agent must know which tier each documentation type belongs to.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
else
    file_content=""
fi

for tier_label in "Navigation" "User-Facing" "Living Reference" "ADR"; do
    if echo "$file_content" | grep -qi "$tier_label"; then
        actual_tier="present"
    else
        actual_tier="missing"
    fi
    assert_eq "test_documentation_schema_sections: tier '$tier_label' present" "present" "$actual_tier"
done
assert_pass_if_clean "test_documentation_schema_sections"

# ── test_breakout_heuristic ──────────────────────────────────────────────────
# The breakout heuristic section must be present and reference the ~1500-token
# threshold and 3rd-level nesting trigger.
# Contract: agent must know when to decompose documentation work into sub-tasks.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
    if echo "$file_content" | grep -qi "breakout\|break.out\|break out"; then
        actual_breakout="present"
    else
        actual_breakout="missing"
    fi
    # Token threshold: accept 1500 or ~1500 or 1,500
    if echo "$file_content" | grep -qE "1[,.]?500|~1500|1500"; then
        actual_threshold="present"
    else
        actual_threshold="missing"
    fi
    # 3rd-level nesting trigger: accept "third", "3rd", or "level 3" patterns
    if echo "$file_content" | grep -qiE "3rd\.level|third\.level|level\.3|###"; then
        actual_nesting="present"
    else
        actual_nesting="missing"
    fi
else
    actual_breakout="missing"
    actual_threshold="missing"
    actual_nesting="missing"
fi
assert_eq "test_breakout_heuristic: breakout section present" "present" "$actual_breakout"
assert_eq "test_breakout_heuristic: ~1500 token threshold referenced" "present" "$actual_threshold"
assert_eq "test_breakout_heuristic: 3rd-level nesting trigger referenced" "present" "$actual_nesting"
assert_pass_if_clean "test_breakout_heuristic"

# ── test_claude_md_read_only_guard ───────────────────────────────────────────
# The agent must declare that it treats CLAUDE.md and safeguard files as
# read-only, and must describe emitting a suggested-change report instead of
# modifying those files directly.
# Contract: prevents the agent from autonomously overwriting critical safeguards.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
    if echo "$file_content" | grep -qi "read\.only\|read only"; then
        actual_guard="present"
    else
        actual_guard="missing"
    fi
    if echo "$file_content" | grep -qi "suggested.change\|suggest.*change\|change.*report\|proposed.*change"; then
        actual_report="present"
    else
        actual_report="missing"
    fi
    if echo "$file_content" | grep -qi "CLAUDE\.md\|safeguard"; then
        actual_ref="present"
    else
        actual_ref="missing"
    fi
else
    actual_guard="missing"
    actual_report="missing"
    actual_ref="missing"
fi
assert_eq "test_claude_md_read_only_guard: read-only guard declared" "present" "$actual_guard"
assert_eq "test_claude_md_read_only_guard: suggested-change report described" "present" "$actual_report"
assert_eq "test_claude_md_read_only_guard: CLAUDE.md or safeguard files referenced" "present" "$actual_ref"
assert_pass_if_clean "test_claude_md_read_only_guard"

# ── test_truncation_warning ──────────────────────────────────────────────────
# The agent must include a section describing a truncation warning that is
# logged when the diff exceeds context limits.
# Contract: agent must handle large diffs gracefully without silent data loss.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
    if echo "$file_content" | grep -qi "truncat"; then
        actual_truncation="present"
    else
        actual_truncation="missing"
    fi
    if echo "$file_content" | grep -qi "warn\|log.*warn\|warning"; then
        actual_warning="present"
    else
        actual_warning="missing"
    fi
    if echo "$file_content" | grep -qi "context\|exceed\|limit"; then
        actual_context="present"
    else
        actual_context="missing"
    fi
else
    actual_truncation="missing"
    actual_warning="missing"
    actual_context="missing"
fi
assert_eq "test_truncation_warning: truncation concept present" "present" "$actual_truncation"
assert_eq "test_truncation_warning: warning/log behavior described" "present" "$actual_warning"
assert_eq "test_truncation_warning: context/limit reference present" "present" "$actual_context"
assert_pass_if_clean "test_truncation_warning"

# ── test_noop_report_format ──────────────────────────────────────────────────
# The structured no-op report format must describe a reason string, a list of
# gates evaluated, and pass/fail status per gate.
# Contract: callers receive machine-parseable feedback when the agent does nothing.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
    if echo "$file_content" | grep -qi "reason"; then
        actual_reason="present"
    else
        actual_reason="missing"
    fi
    if echo "$file_content" | grep -qi "gates.*evaluat\|evaluat.*gates\|gates_evaluated\|evaluated"; then
        actual_gates_eval="present"
    else
        actual_gates_eval="missing"
    fi
    if echo "$file_content" | grep -qiE "pass.*fail|fail.*pass|pass/fail|PASS|FAIL|passed|failed"; then
        actual_passfail="present"
    else
        actual_passfail="missing"
    fi
else
    actual_reason="missing"
    actual_gates_eval="missing"
    actual_passfail="missing"
fi
assert_eq "test_noop_report_format: reason field described" "present" "$actual_reason"
assert_eq "test_noop_report_format: gates evaluated field described" "present" "$actual_gates_eval"
assert_eq "test_noop_report_format: pass/fail per gate described" "present" "$actual_passfail"
assert_pass_if_clean "test_noop_report_format"

# ── test_inputs_epic_context_and_git_diff ────────────────────────────────────
# The agent must declare that it reads both epic context and git diff as inputs.
# Contract: both signals are required for the decision engine to function.
_snapshot_fail
if [[ -f "$AGENT_FILE" ]]; then
    file_content=$(cat "$AGENT_FILE")
    if echo "$file_content" | grep -qi "epic"; then
        actual_epic="present"
    else
        actual_epic="missing"
    fi
    if echo "$file_content" | grep -qi "git diff\|git.diff\|diff"; then
        actual_diff="present"
    else
        actual_diff="missing"
    fi
else
    actual_epic="missing"
    actual_diff="missing"
fi
assert_eq "test_inputs_epic_context_and_git_diff: epic context input referenced" "present" "$actual_epic"
assert_eq "test_inputs_epic_context_and_git_diff: git diff input referenced" "present" "$actual_diff"
assert_pass_if_clean "test_inputs_epic_context_and_git_diff"

# ── Summary ──────────────────────────────────────────────────────────────────
print_summary
