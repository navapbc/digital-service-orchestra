#!/usr/bin/env bash
# tests/scripts/test-implementation-plan-task-description.sh
# Structural boundary test: implementation-plan SKILL.md Step 5 "Create Tasks"
# section must not contain a bare task creation command that omits -d.
#
# Regression guard for bug 027a-ad30:
# Positional Bias failure — a bare `ticket create task` example without `-d`
# appeared as the FIRST operative template in "### Create Tasks", causing agents
# to create tasks with empty descriptions and write task bodies as comments.
#
# Per behavioral-testing-standard.md Rule 5, instruction-file tests check the
# STRUCTURAL BOUNDARY — the presence/absence of a specific code pattern — not
# wording or content assertions.
#
# What we test (structural boundary):
#   1. The "### Create Tasks" section does NOT contain a bare ticket create task
#      invocation that omits -d (the anti-pattern that caused 027a-ad30)
#   2. At least one ticket create task invocation in Step 5 includes -d
#      (the correct operative template is present)
#
# Usage:
#   bash tests/scripts/test-implementation-plan-task-description.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$PLUGIN_ROOT/plugins/dso/skills/implementation-plan/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-implementation-plan-task-description.sh ==="
echo ""

# ===========================================================================
# test_no_bare_create_without_description_flag
#
# Given: implementation-plan/SKILL.md Step 5 "### Create Tasks" section
# When: we extract the section and check for ticket create task calls lacking -d
# Then: no bare `ticket create task` invocation (without -d flag) should be
#       present as a code block in the "Create Tasks" section
#
# Structural boundary: the absence of the anti-pattern code block is the contract.
# An agent following the first code block it sees will produce empty descriptions
# if that block lacks -d.
# ===========================================================================
test_no_bare_create_without_description_flag() {
  local _section
  # Extract from "### Create Tasks" to the next ### heading
  _section=$(awk '/^### Create Tasks/{found=1} found && /^### / && !/^### Create Tasks/{exit} found{print}' "$SKILL_FILE")

  # Look for ticket create task invocations within bash code blocks that lack -d
  # We extract lines matching the ticket create task pattern, then check if any
  # lack the -d or --description flag.
  local _bare_creates
  _bare_creates=$(echo "$_section" | grep "ticket create task" | grep -v "\-d " | grep -v "\-\-description " || true)

  local _found_bare=0
  [[ -n "$_bare_creates" ]] && _found_bare=1

  assert_eq \
    "test_no_bare_create_without_description_flag: no bare ticket create task without -d in Create Tasks section" \
    "0" "$_found_bare"
}

# ===========================================================================
# test_integration_test_rule_has_primary_path_constraint
#
# Given: implementation-plan/SKILL.md Integration Test Task Rule
# When: we look for the Primary path constraint (33a8-6762)
# Then: the skill must contain a constraint prohibiting privileged bypass paths
#       when user-facing flows are in the success criteria
#
# Structural boundary: the "Primary path constraint" paragraph must exist in the
# Integration Test Task Rule section, co-located with the exemption list.
# RED before fix: constraint absent → agent free to use admin-initiate-auth bypass.
# GREEN after fix: constraint present → agent must exercise browser/user path.
# ===========================================================================
test_integration_test_rule_has_primary_path_constraint() {
  local _skill_content
  _skill_content=$(cat "$SKILL_FILE" 2>/dev/null || true)

  local _found_primary_path="missing"

  # Must contain the primary-path constraint at the integration test rule site
  # grep directly on file to avoid echo|grep-q SIGPIPE false-negative under set -uo pipefail
  if grep -qiE "Primary path constraint|privileged bypass.*not satisfy|administrative.*bypass.*does not satisfy" "$SKILL_FILE"; then
    _found_primary_path="found"
  fi

  assert_eq \
    "test_integration_test_rule_has_primary_path_constraint: integration test rule must prohibit admin/CLI bypass for user-facing flow SCs (33a8-6762)" \
    "found" "$_found_primary_path"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_no_bare_create_without_description_flag
test_integration_test_rule_has_primary_path_constraint

print_summary
