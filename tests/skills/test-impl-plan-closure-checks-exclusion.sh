#!/usr/bin/env bash
# tests/skills/test-impl-plan-closure-checks-exclusion.sh
# Structural boundary test: implementation-plan SKILL.md DD partition step must
# exclude items under "## Closure Checks" from the task Story DD Coverage sections.
#
# Per behavioral-testing-standard.md Rule 5: instruction-file tests assert only
# on binding tokens. The Closure Checks exclusion guard is a binding constraint
# for any agent reading the SKILL.md to generate tasks — it must be present and
# unambiguous to prevent Closure Checks items from being assigned to tasks.
#
# Story: 4791-3bdd-3446-4206 — implementation-plan DD partitioning step excludes
# Closure Checks items
#
# Usage:
#   bash tests/skills/test-impl-plan-closure-checks-exclusion.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/implementation-plan/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-impl-plan-closure-checks-exclusion.sh ==="
echo ""

# ===========================================================================
# test_closure_checks_exclusion_guard_present
#
# Binding constraint: the DD partition step must include an explicit guard
# excluding "## Closure Checks" items from Story DD Coverage sections.
# Without this guard, agents may erroneously assign Closure Checks items to
# task DD Coverage — causing the completion-verifier to double-count them.
# ===========================================================================
test_closure_checks_exclusion_guard_present() {
  local _found_guard=0
  grep -q "Closure Checks.*excluded from the DD partition" "$SKILL_FILE" 2>/dev/null && _found_guard=1

  assert_eq \
    "test_closure_checks_exclusion_guard_present: SKILL.md DD partition step must exclude Closure Checks items" \
    "1" "$_found_guard"
}

# ===========================================================================
# test_closure_checks_dd_sections_only
#
# Binding constraint: the guard must explicitly state that only Done Definitions
# and Success Criteria sections are assigned to tasks — not Closure Checks.
# ===========================================================================
test_closure_checks_dd_sections_only() {
  local _found_sections=0
  grep -q "Done Definitions.*Success Criteria" "$SKILL_FILE" 2>/dev/null && _found_sections=1

  assert_eq \
    "test_closure_checks_dd_sections_only: SKILL.md must specify that only Done Definitions / Success Criteria sections feed the DD partition" \
    "1" "$_found_sections"
}

# ===========================================================================
# test_closure_checks_verifier_rationale_present
#
# The guard must include the rationale explaining why Closure Checks are
# excluded: they are verified by the completion-verifier agent at closure,
# not by implementation tasks.
# ===========================================================================
test_closure_checks_verifier_rationale_present() {
  local _found_rationale=0
  grep -q "completion-verifier" "$SKILL_FILE" 2>/dev/null && _found_rationale=1

  assert_eq \
    "test_closure_checks_verifier_rationale_present: SKILL.md must include rationale that Closure Checks are verified by completion-verifier agent" \
    "1" "$_found_rationale"
}

test_closure_checks_exclusion_guard_present
test_closure_checks_dd_sections_only
test_closure_checks_verifier_rationale_present

print_summary
