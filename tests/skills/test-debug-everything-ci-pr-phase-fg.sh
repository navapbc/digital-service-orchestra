#!/usr/bin/env bash
# Behavioral tests for debug-everything SKILL.md Phase F and Phase G:
# ci-pr mode PR targeting — verifies SESSION_BRANCH resolution via
# resolve-session-branch.sh, --base "$SESSION_BRANCH" usage (not main),
# and absence of local /dso:review dispatch in ci-pr path.
#
# These are "instruction correctness" tests — they verify the SKILL.md text
# contains the required patterns. They pass because SKILL.md was updated in
# tasks 55a9 and 3ad5.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/debug-everything/SKILL.md"

PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ============================================================
echo "=== test_phase_f_resolve_session_branch ==="
SECTION="test_phase_f_resolve_session_branch"

# Phase F must reference resolve-session-branch.sh for SESSION_BRANCH resolution.
# Extract Phase F section (from "## Phase F" to "## Phase G") and check.
PHASE_F=$(awk '/^## Phase F:/,/^## Phase G:/' "$SKILL_MD")

if echo "$PHASE_F" | grep -q 'resolve-session-branch\.sh'; then
  pass "Phase F references resolve-session-branch.sh for SESSION_BRANCH resolution"
else
  fail "Phase F missing reference to resolve-session-branch.sh (expected SESSION_BRANCH resolution via this script)"
fi

if echo "$PHASE_F" | grep -qE 'SESSION_BRANCH.*resolution failed|fail-fast'; then
  pass "Phase F documents fail-fast behavior on SESSION_BRANCH resolution failure"
else
  fail "Phase F missing fail-fast / error handling for SESSION_BRANCH resolution failure"
fi

# ============================================================
echo ""
echo "=== test_phase_f_pr_base_session_branch ==="
SECTION="test_phase_f_pr_base_session_branch"

# Phase F must use --base "$SESSION_BRANCH" in gh pr create (not --base main).
# shellcheck disable=SC2016  # single-quoted pattern is intentional literal grep match
if echo "$PHASE_F" | grep -qE 'gh pr create.*--base.*SESSION_BRANCH|--base.*SESSION_BRANCH.*gh pr create|--base "\$SESSION_BRANCH"'; then
  pass "Phase F uses --base \"\$SESSION_BRANCH\" in gh pr create"
else
  fail "Phase F missing --base \"\$SESSION_BRANCH\" in gh pr create instruction"
fi

if echo "$PHASE_F" | grep -qE 'gh pr create.*--base main|--base main.*gh pr create'; then
  fail "Phase F still references --base main (should be --base \"\$SESSION_BRANCH\")"
else
  pass "Phase F does not use --base main for sub-branch PRs"
fi

# Assert the explicit "(not main)" annotation is present
if echo "$PHASE_F" | grep -qE 'not main'; then
  pass "Phase F explicitly annotates 'not main' for PR base"
else
  fail "Phase F missing explicit 'not main' annotation in PR base instruction"
fi

# ============================================================
echo ""
echo "=== test_phase_g_resolve_session_branch ==="
SECTION="test_phase_g_resolve_session_branch"

# Extract Phase G section (from "## Phase G" to the next "## Phase " heading).
PHASE_G=$(awk '/^## Phase G:/,/^## Phase [^G]/' "$SKILL_MD")

if echo "$PHASE_G" | grep -q 'resolve-session-branch\.sh'; then
  pass "Phase G references resolve-session-branch.sh for SESSION_BRANCH resolution"
else
  fail "Phase G missing reference to resolve-session-branch.sh (expected SESSION_BRANCH resolution via this script)"
fi

if echo "$PHASE_G" | grep -qE 'SESSION_BRANCH.*resolution failed|fail-fast'; then
  pass "Phase G documents fail-fast behavior on SESSION_BRANCH resolution failure"
else
  fail "Phase G missing fail-fast / error handling for SESSION_BRANCH resolution failure"
fi

# ============================================================
echo ""
echo "=== test_phase_g_pr_base_session_branch ==="
SECTION="test_phase_g_pr_base_session_branch"

# Phase G must use --base "$SESSION_BRANCH" in gh pr create (not --base main).
# shellcheck disable=SC2016  # single-quoted pattern is intentional literal grep match
if echo "$PHASE_G" | grep -qE 'gh pr create.*--base.*SESSION_BRANCH|--base.*SESSION_BRANCH.*gh pr create|--base "\$SESSION_BRANCH"'; then
  pass "Phase G uses --base \"\$SESSION_BRANCH\" in gh pr create"
else
  fail "Phase G missing --base \"\$SESSION_BRANCH\" in gh pr create instruction"
fi

if echo "$PHASE_G" | grep -qE 'gh pr create.*--base main|--base main.*gh pr create'; then
  fail "Phase G still references --base main (should be --base \"\$SESSION_BRANCH\")"
else
  pass "Phase G does not use --base main for sub-branch PRs"
fi

# Assert the explicit "(not main)" annotation is present
if echo "$PHASE_G" | grep -qE 'not main'; then
  pass "Phase G explicitly annotates 'not main' for PR base"
else
  fail "Phase G missing explicit 'not main' annotation in PR base instruction"
fi

# ============================================================
echo ""
echo "=== test_no_local_dso_review_in_ci_pr_path ==="
SECTION="test_no_local_dso_review_in_ci_pr_path"

# Phase F ci-pr path must NOT instruct a local /dso:review dispatch.
# The SKILL.md explicitly states "no local /dso:review dispatch is required or performed".
if echo "$PHASE_F" | grep -qE 'No local.*/?dso:review.*dispatch is required or performed|no local.*/?dso:review.*dispatch is required or performed'; then
  pass "Phase F ci-pr path explicitly states no local /dso:review dispatch is required or performed"
else
  fail "Phase F ci-pr path missing explicit 'no local /dso:review dispatch is required or performed' statement"
fi

# Phase F must not contain an affirmative /dso:review dispatch instruction in ci-pr context.
# (Negative signal: no 'dispatch /dso:review' or 'run /dso:review' instruction).
if echo "$PHASE_F" | grep -qE 'dispatch.*/?dso:review|run.*/?dso:review|invoke.*/?dso:review'; then
  fail "Phase F ci-pr path contains an affirmative /dso:review dispatch instruction (should be CI-handled)"
else
  pass "Phase F ci-pr path contains no affirmative /dso:review dispatch instruction"
fi

# Phase G ci-pr path must NOT instruct a local /dso:review dispatch.
if echo "$PHASE_G" | grep -qE 'No local.*/?dso:review.*dispatch is required or performed|no local.*/?dso:review.*dispatch is required or performed'; then
  pass "Phase G ci-pr path explicitly states no local /dso:review dispatch is required or performed"
else
  fail "Phase G ci-pr path missing explicit 'no local /dso:review dispatch is required or performed' statement"
fi

# Phase G must not contain an affirmative /dso:review dispatch instruction in ci-pr context.
if echo "$PHASE_G" | grep -qE 'dispatch.*/?dso:review|run.*/?dso:review|invoke.*/?dso:review'; then
  fail "Phase G ci-pr path contains an affirmative /dso:review dispatch instruction (should be CI-handled)"
else
  pass "Phase G ci-pr path contains no affirmative /dso:review dispatch instruction"
fi

# ============================================================
echo ""
echo "=== test_phase_f_g_ci_triggers_per_branch_review ==="
SECTION="test_phase_f_g_ci_triggers_per_branch_review"

# Both phases must document that the PR triggers per-branch-review.yml automatically.
if echo "$PHASE_F" | grep -qE 'per-branch-review\.yml'; then
  pass "Phase F documents that CI per-branch-review.yml workflow is triggered automatically"
else
  fail "Phase F missing per-branch-review.yml CI workflow reference"
fi

if echo "$PHASE_G" | grep -qE 'per-branch-review\.yml'; then
  pass "Phase G documents that CI per-branch-review.yml workflow is triggered automatically"
else
  fail "Phase G missing per-branch-review.yml CI workflow reference"
fi

# ============================================================
echo ""
echo "============================================================"
echo "Results: ${PASS} passed, ${FAIL} failed"
if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
