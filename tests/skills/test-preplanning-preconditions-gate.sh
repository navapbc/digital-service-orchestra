#!/usr/bin/env bash
# tests/skills/test-preplanning-preconditions-gate.sh
# Structural boundary tests for /dso:preplanning preconditions gate sections in SKILL.md
# (per behavioral-testing-standard.md Rule 5 — test the structural boundary, not the content).
#
# These tests verify that SKILL.md contains the required section headings and
# references that define the preconditions gate contract.
#
# Usage: bash tests/skills/test-preplanning-preconditions-gate.sh

# NOTE: -e is intentionally omitted — tests may grep for strings not yet present.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/preplanning/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-preplanning-preconditions-gate.sh ==="

# ── Test 1: SKILL.md has a Preconditions Entry Gate section ──────────────────
echo "Test 1: preplanning SKILL.md contains 'Preconditions Entry Gate' section"
test_preplanning_skill_has_preconditions_entry_gate() {
    if [ ! -f "$SKILL_FILE" ]; then
        assert_eq "preplanning SKILL.md exists" "exists" "missing"
        return
    fi

    if grep -q "Preconditions Entry Gate" "$SKILL_FILE" 2>/dev/null; then
        assert_eq "SKILL.md contains 'Preconditions Entry Gate'" "1" "1"
    else
        assert_eq "SKILL.md contains 'Preconditions Entry Gate'" "1" "0"
    fi
}
test_preplanning_skill_has_preconditions_entry_gate

# ── Test 2: SKILL.md references preconditions-validator.sh ───────────────────
echo "Test 2: preplanning SKILL.md references 'preconditions-validator.sh'"
test_preplanning_skill_references_preconditions_validator() {
    if [ ! -f "$SKILL_FILE" ]; then
        assert_eq "preplanning SKILL.md exists for validator-ref test" "exists" "missing"
        return
    fi

    if grep -q "preconditions-validator.sh" "$SKILL_FILE" 2>/dev/null; then
        assert_eq "SKILL.md references preconditions-validator.sh" "1" "1"
    else
        assert_eq "SKILL.md references preconditions-validator.sh" "1" "0"
    fi
}
test_preplanning_skill_references_preconditions_validator

# ── Test 3: SKILL.md has a Preconditions Exit Emit section ───────────────────
echo "Test 3: preplanning SKILL.md contains 'Preconditions Exit Emit' section"
test_preplanning_skill_has_preconditions_exit_emit() {
    if [ ! -f "$SKILL_FILE" ]; then
        assert_eq "preplanning SKILL.md exists for exit-emit test" "exists" "missing"
        return
    fi

    if grep -q "Preconditions Exit Emit" "$SKILL_FILE" 2>/dev/null; then
        assert_eq "SKILL.md contains 'Preconditions Exit Emit'" "1" "1"
    else
        assert_eq "SKILL.md contains 'Preconditions Exit Emit'" "1" "0"
    fi
}
test_preplanning_skill_has_preconditions_exit_emit

print_summary
