#!/usr/bin/env bash
# tests/skills/test-interface-contracts-task-setup.sh
#
# Structural boundary test: interface-contracts/SKILL.md Task Setup section
# must include -d flag on all ticket create task commands.
#
# Rule 5 compliance: tests the structural contract of an instruction file —
# the -d flag is the behavioral interface that ensures task descriptions are
# provided at creation time, preventing positional bias (bug 19af-1a7e).
#
# Analogous to the fix for 027a-ad30 (implementation-plan positional bias).

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/interface-contracts/SKILL.md"

# Source shared assert library
# shellcheck source=tests/lib/assert.sh
source "${REPO_ROOT}/tests/lib/assert.sh"

# ---------------------------------------------------------------------------
# test_task_setup_create_commands_include_description
#
# Given: Task Setup section exists in interface-contracts/SKILL.md
# When:  All "ticket create task" lines in the section are extracted
# Then:  Every such command includes the -d flag
# ---------------------------------------------------------------------------
test_task_setup_create_commands_include_description() {
  if [ ! -f "$SKILL_MD" ]; then
    assert_eq "interface-contracts SKILL.md must exist" "exists" "missing"
    return
  fi

  # Extract the Task Setup section: from "## Task Setup" to next "##" or EOF
  local section
  section="$(awk '
    /^## Task Setup/ { in_section=1 }
    in_section && /^## / && !/^## Task Setup/ { in_section=0 }
    in_section { print }
  ' "$SKILL_MD")"

  if [ -z "$section" ]; then
    assert_eq "Task Setup section must be present" "non-empty" "empty"
    return
  fi

  # Find all "ticket create task" lines and check each has -d
  local found_any=false
  local all_have_d=true
  local bad_lines=""

  while IFS= read -r line; do
    if echo "$line" | grep -q "ticket create task"; then
      found_any=true
      if ! echo "$line" | grep -qE "[[:space:]]-d[[:space:]]|[[:space:]]--description[[:space:]]"; then
        all_have_d=false
        bad_lines="${bad_lines}  ${line}
"
      fi
    fi
  done <<< "$section"

  if [ "$found_any" = "false" ]; then
    assert_eq "Task Setup section must contain at least one ticket create task command" \
      "found" "none"
    return
  fi

  if [ "$all_have_d" = "false" ]; then
    echo "  Commands missing -d flag:" >&2
    echo "$bad_lines" >&2
  fi

  assert_eq \
    "All 'ticket create task' commands in Task Setup must include -d for description" \
    "true" \
    "$all_have_d"
}

# ---------------------------------------------------------------------------
# Run
# ---------------------------------------------------------------------------
test_task_setup_create_commands_include_description

print_summary
