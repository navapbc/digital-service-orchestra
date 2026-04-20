#!/usr/bin/env bash
# tests/skills/test-preconditions-commit-validator.sh
# Structural boundary tests (Rule 5) for COMMIT-WORKFLOW.md validator wiring.
# Non-executable LLM instruction file — tests verify structural presence of
# validator sections, not behavioral execution.
#
# RED: tests fail before 2d5c-1a8a adds validator hooks to COMMIT-WORKFLOW.md.
# GREEN: tests pass after validator sections are inserted.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/plugins/dso/docs/workflows/COMMIT-WORKFLOW.md"

source "$SCRIPT_DIR/../lib/assert.sh"

# ── Test 1: COMMIT-WORKFLOW.md contains _dso_pv_entry_check invocation ────────
test_commit_validator_entry_section_present() {
    local found=0
    if grep -q "_dso_pv_entry_check" "$WORKFLOW_FILE" 2>/dev/null; then
        found=1
    fi
    assert_eq \
        "commit_validator_entry_section_present: _dso_pv_entry_check found in COMMIT-WORKFLOW.md" \
        "1" \
        "$found"
}

# ── Test 2: COMMIT-WORKFLOW.md contains _dso_pv_exit_write invocation ─────────
test_commit_validator_exit_section_present() {
    local found=0
    if grep -q "_dso_pv_exit_write" "$WORKFLOW_FILE" 2>/dev/null; then
        found=1
    fi
    assert_eq \
        "commit_validator_exit_section_present: _dso_pv_exit_write found in COMMIT-WORKFLOW.md" \
        "1" \
        "$found"
}

# ── Test 3: entry section references "sprint" as upstream stage name ──────────
test_commit_validator_upstream_stage_is_sprint() {
    local found=0
    # Look for _dso_pv_entry_check with "sprint" as upstream stage argument
    if grep -q '_dso_pv_entry_check.*sprint\|_dso_pv_entry_check.*"sprint"' "$WORKFLOW_FILE" 2>/dev/null; then
        found=1
    fi
    assert_eq \
        "commit_validator_upstream_stage_is_sprint: sprint referenced as upstream stage" \
        "1" \
        "$found"
}

# ── Test 4: no interactive prompt pattern in validator sections ───────────────
test_commit_validator_zero_interaction() {
    # The validator sections must NOT contain interactive prompts
    local interactive_found=0
    if grep -q 'read -p\|/dev/tty\|AskUserQuestion' "$WORKFLOW_FILE" 2>/dev/null; then
        # If any interactive pattern exists, check it's not within a validator block
        # Structural check: _dso_pv_entry_check must not be immediately near read -p
        if grep -A3 '_dso_pv_entry_check' "$WORKFLOW_FILE" 2>/dev/null | grep -q 'read -p\|/dev/tty'; then
            interactive_found=1
        fi
        if grep -A3 '_dso_pv_exit_write' "$WORKFLOW_FILE" 2>/dev/null | grep -q 'read -p\|/dev/tty'; then
            interactive_found=1
        fi
    fi
    assert_eq \
        "commit_validator_zero_interaction: no interactive prompts in validator sections" \
        "0" \
        "$interactive_found"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
echo "=== test-preconditions-commit-validator.sh ==="
test_commit_validator_entry_section_present
test_commit_validator_exit_section_present
test_commit_validator_upstream_stage_is_sprint
test_commit_validator_zero_interaction

print_summary
