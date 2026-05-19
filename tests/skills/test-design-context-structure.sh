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

# Deleted: test_task_exec_design_context_heading — heading-grep with no
# non-human consumer (LLMs paraphrase headings robustly).
#
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

# Deleted: test_task_exec_needs_review, test_task_exec_authoritative_for_behavior,
# test_task_exec_authoritative_for_visual, test_skill_design_context_population_section
# — all prose-grep on LLM instruction wording with no non-human consumer.
#
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

# Deleted: test_skill_sonnet_minimum — fuzzy regex on LLM instruction prose.
# LLMs paraphrase "minimum model: sonnet" robustly; no parser branches on
# the exact wording.
#
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
test_task_exec_design_context_placeholder
test_skill_design_approved_tag
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
