#!/usr/bin/env bash
# tests/skills/test-preconditions-epic-closure-validator.sh
# Structural boundary tests (Rule 5) for completion-verifier.md validator wiring.
# Non-executable LLM agent instruction file — tests verify structural presence
# of validator sections and the ordering contract (validator before compaction).
#
# RED: tests fail before 3ff4-1313 adds validator hooks to completion-verifier.md.
# GREEN: tests pass after validator sections are inserted.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
AGENT_FILE="$REPO_ROOT/plugins/dso/agents/completion-verifier.md"

source "$SCRIPT_DIR/../lib/assert.sh"

# ── Test 1: completion-verifier.md contains _dso_pv_entry_check invocation ────
test_epic_closure_validator_entry_section_present() {
    local found=0
    if grep -q "_dso_pv_entry_check" "$AGENT_FILE" 2>/dev/null; then
        found=1
    fi
    assert_eq \
        "epic_closure_validator_entry_section_present: _dso_pv_entry_check found in completion-verifier.md" \
        "1" \
        "$found"
}

# ── Test 2: completion-verifier.md contains _dso_pv_exit_write invocation ─────
test_epic_closure_validator_exit_section_present() {
    local found=0
    if grep -q "_dso_pv_exit_write" "$AGENT_FILE" 2>/dev/null; then
        found=1
    fi
    assert_eq \
        "epic_closure_validator_exit_section_present: _dso_pv_exit_write found in completion-verifier.md" \
        "1" \
        "$found"
}

# ── Test 3: entry section references "commit" as upstream stage name ──────────
test_epic_closure_validator_upstream_stage_is_commit() {
    local found=0
    if grep -q '_dso_pv_entry_check.*commit\|_dso_pv_entry_check.*"commit"' "$AGENT_FILE" 2>/dev/null; then
        found=1
    fi
    assert_eq \
        "epic_closure_validator_upstream_stage_is_commit: commit referenced as upstream stage" \
        "1" \
        "$found"
}

# ── Test 4: validator exit write appears BEFORE any compaction trigger ─────────
test_epic_closure_validator_precedes_compaction() {
    # Find line number of _dso_pv_exit_write
    local v_line=""
    v_line=$(grep -n "_dso_pv_exit_write" "$AGENT_FILE" 2>/dev/null | head -1 | cut -d: -f1)

    # Find line number of compaction trigger (compact/compaction/SNAPSHOT)
    local c_line=""
    c_line=$(grep -n 'compaction\|SNAPSHOT\|compact' "$AGENT_FILE" 2>/dev/null | head -1 | cut -d: -f1)

    if [[ -z "$v_line" ]]; then
        # No validator exit write found — test fails (prerequisite: T2 must be applied)
        assert_eq \
            "epic_closure_validator_precedes_compaction: _dso_pv_exit_write line found" \
            "found" \
            "not_found"
        return
    fi

    if [[ -z "$c_line" ]]; then
        # No compaction trigger found — validator precedes compaction by default (pass)
        assert_eq \
            "epic_closure_validator_precedes_compaction: no compaction trigger (validator wins by default)" \
            "pass" \
            "pass"
        return
    fi

    # Both found: validator line must be less than compaction line
    local ordering_ok=0
    if [[ "$v_line" -lt "$c_line" ]]; then
        ordering_ok=1
    fi
    assert_eq \
        "epic_closure_validator_precedes_compaction: validator (line $v_line) before compaction (line $c_line)" \
        "1" \
        "$ordering_ok"
}

# ── Test 5: no interactive prompt pattern in validator sections ───────────────
test_epic_closure_validator_zero_interaction() {
    local interactive_found=0
    if grep -A3 '_dso_pv_entry_check' "$AGENT_FILE" 2>/dev/null | grep -q 'read -p\|/dev/tty'; then
        interactive_found=1
    fi
    if grep -A3 '_dso_pv_exit_write' "$AGENT_FILE" 2>/dev/null | grep -q 'read -p\|/dev/tty'; then
        interactive_found=1
    fi
    assert_eq \
        "epic_closure_validator_zero_interaction: no interactive prompts in validator sections" \
        "0" \
        "$interactive_found"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
echo "=== test-preconditions-epic-closure-validator.sh ==="
test_epic_closure_validator_entry_section_present
test_epic_closure_validator_exit_section_present
test_epic_closure_validator_upstream_stage_is_commit
test_epic_closure_validator_precedes_compaction
test_epic_closure_validator_zero_interaction

print_summary
