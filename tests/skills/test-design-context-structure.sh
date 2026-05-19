#!/usr/bin/env bash
# tests/skills/test-design-context-structure.sh
# Structural tests verifying design context additions to task-execution.md
# and sprint SKILL.md. Asserts text presence only.
#
# RE-AUDIT (SDET audit P2 row 3, MODIFY): the original audit recommended
# DELETE; on re-audit at the correct path (this file lives under
# tests/skills/, NOT tests/docs/ as the audit cited) the verdict is
# RETAIN. Per the project's Behavioral Testing Standard Rule 5 and the
# code-reviewer-standard "PRESENCE of source-grep tests on structural
# artifacts" carve-out, grep-on-prose assertions are the AUTHORIZED
# testing boundary for non-executable instruction files (SKILL.md,
# prompts/*.md). Those files have no runtime to execute; grepping for
# structural anchors used by the LLM orchestrator IS the deterministic
# integration test. DO NOT convert these to behavioral assertions —
# there is no behavior to observe; the file IS the contract.
#
# Tests for task-execution.md:
#   (a) "### Design Context" heading exists
#   (b) "{design_context}" placeholder present
#   (c) "NEEDS_REVIEW" text present
#   (d) "authoritative for behavior" text present
#   (e) "authoritative for visual" text present
#
# Tests for sprint SKILL.md:
#   (f) "Design Context Population" section exists
#   (g) "design:approved" tag check documented
#   (h) sonnet minimum model enforcement present
#   (i) figma-tags.conf referenced
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
TASK_EXEC_MD="${REPO_ROOT}/plugins/dso/skills/sprint/prompts/task-execution.md"
SPRINT_SKILL_MD="${REPO_ROOT}/plugins/dso/skills/sprint/SKILL.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test (a): task-execution.md contains "### Design Context" heading
# ---------------------------------------------------------------------------
test_task_exec_design_context_heading() {
  echo "=== test_task_exec_design_context_heading ==="

  if [ ! -f "$TASK_EXEC_MD" ]; then
    fail "task-execution.md missing at ${TASK_EXEC_MD}"
    return
  fi

  if grep -qF "### Design Context" "$TASK_EXEC_MD"; then
    pass "task-execution.md contains '### Design Context' heading"
  else
    fail "task-execution.md missing '### Design Context' heading"
  fi
}

# ---------------------------------------------------------------------------
# Test (b): task-execution.md contains "{design_context}" placeholder
# ---------------------------------------------------------------------------
test_task_exec_design_context_placeholder() {
  echo ""
  echo "=== test_task_exec_design_context_placeholder ==="

  if [ ! -f "$TASK_EXEC_MD" ]; then
    fail "task-execution.md missing at ${TASK_EXEC_MD}"
    return
  fi

  if grep -qF "{design_context}" "$TASK_EXEC_MD"; then
    pass "task-execution.md contains '{design_context}' placeholder"
  else
    fail "task-execution.md missing '{design_context}' placeholder"
  fi
}

# ---------------------------------------------------------------------------
# Test (c): task-execution.md contains "NEEDS_REVIEW" text
# ---------------------------------------------------------------------------
test_task_exec_needs_review() {
  echo ""
  echo "=== test_task_exec_needs_review ==="

  if [ ! -f "$TASK_EXEC_MD" ]; then
    fail "task-execution.md missing at ${TASK_EXEC_MD}"
    return
  fi

  if grep -qF "NEEDS_REVIEW" "$TASK_EXEC_MD"; then
    pass "task-execution.md contains 'NEEDS_REVIEW' text"
  else
    fail "task-execution.md missing 'NEEDS_REVIEW' text"
  fi
}

# ---------------------------------------------------------------------------
# Test (d): task-execution.md contains "authoritative for behavior"
# ---------------------------------------------------------------------------
test_task_exec_authoritative_for_behavior() {
  echo ""
  echo "=== test_task_exec_authoritative_for_behavior ==="

  if [ ! -f "$TASK_EXEC_MD" ]; then
    fail "task-execution.md missing at ${TASK_EXEC_MD}"
    return
  fi

  if grep -qF "authoritative for behavior" "$TASK_EXEC_MD"; then
    pass "task-execution.md contains 'authoritative for behavior' text"
  else
    fail "task-execution.md missing 'authoritative for behavior' text"
  fi
}

# ---------------------------------------------------------------------------
# Test (e): task-execution.md contains "authoritative for visual"
# ---------------------------------------------------------------------------
test_task_exec_authoritative_for_visual() {
  echo ""
  echo "=== test_task_exec_authoritative_for_visual ==="

  if [ ! -f "$TASK_EXEC_MD" ]; then
    fail "task-execution.md missing at ${TASK_EXEC_MD}"
    return
  fi

  if grep -qF "authoritative for visual" "$TASK_EXEC_MD"; then
    pass "task-execution.md contains 'authoritative for visual' text"
  else
    fail "task-execution.md missing 'authoritative for visual' text"
  fi
}

# ---------------------------------------------------------------------------
# Test (f): sprint SKILL.md contains "Design Context Population" section
# ---------------------------------------------------------------------------
test_skill_design_context_population_section() {
  echo ""
  echo "=== test_skill_design_context_population_section ==="

  if [ ! -f "$SPRINT_SKILL_MD" ]; then
    fail "sprint SKILL.md missing at ${SPRINT_SKILL_MD}"
    return
  fi

  if grep -qF "Design Context Population" "$SPRINT_SKILL_MD"; then
    pass "sprint SKILL.md contains 'Design Context Population' section"
  else
    fail "sprint SKILL.md missing 'Design Context Population' section"
  fi
}

# ---------------------------------------------------------------------------
# Test (g): sprint SKILL.md documents "design:approved" tag check
# ---------------------------------------------------------------------------
test_skill_design_approved_tag() {
  echo ""
  echo "=== test_skill_design_approved_tag ==="

  if [ ! -f "$SPRINT_SKILL_MD" ]; then
    fail "sprint SKILL.md missing at ${SPRINT_SKILL_MD}"
    return
  fi

  if grep -qF "design:approved" "$SPRINT_SKILL_MD"; then
    pass "sprint SKILL.md documents 'design:approved' tag check"
  else
    fail "sprint SKILL.md missing 'design:approved' tag check"
  fi
}

# ---------------------------------------------------------------------------
# Test (h): sprint SKILL.md documents sonnet minimum model enforcement
# (matches "sonnet" near "minimum" in either order)
# ---------------------------------------------------------------------------
test_skill_sonnet_minimum() {
  echo ""
  echo "=== test_skill_sonnet_minimum ==="

  if [ ! -f "$SPRINT_SKILL_MD" ]; then
    fail "sprint SKILL.md missing at ${SPRINT_SKILL_MD}"
    return
  fi

  # Accept "minimum sonnet", "sonnet minimum", "minimum `sonnet`", etc.
  if grep -qiE "(minimum.*sonnet|sonnet.*minimum)" "$SPRINT_SKILL_MD"; then
    pass "sprint SKILL.md documents sonnet minimum model enforcement"
  else
    fail "sprint SKILL.md missing sonnet minimum model enforcement (pattern: minimum.*sonnet or sonnet.*minimum)"
  fi
}

# ---------------------------------------------------------------------------
# Test (i): sprint SKILL.md references figma-tags.conf
# ---------------------------------------------------------------------------
test_skill_figma_tags_conf_reference() {
  echo ""
  echo "=== test_skill_figma_tags_conf_reference ==="

  if [ ! -f "$SPRINT_SKILL_MD" ]; then
    fail "sprint SKILL.md missing at ${SPRINT_SKILL_MD}"
    return
  fi

  if grep -qF "figma-tags.conf" "$SPRINT_SKILL_MD"; then
    pass "sprint SKILL.md references 'figma-tags.conf'"
  else
    fail "sprint SKILL.md missing reference to 'figma-tags.conf'"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_task_exec_design_context_heading
test_task_exec_design_context_placeholder
test_task_exec_needs_review
test_task_exec_authoritative_for_behavior
test_task_exec_authoritative_for_visual
test_skill_design_context_population_section
test_skill_design_approved_tag
test_skill_sonnet_minimum
test_skill_figma_tags_conf_reference

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  echo "VALIDATION FAILED"
  exit 1
fi

echo "ALL VALIDATIONS PASSED"
exit 0
