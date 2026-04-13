#!/usr/bin/env bash
# tests/skills/test-preplanning-noninteractive-checkpoints.sh
# RED tests for story 12bf-521f (task 241e-0fdf):
#   PREPLANNING_INTERACTIVE branching must exist in all 7 checkpoint locations
#   in preplanning SKILL.md and ui-designer-dispatch-protocol.md.
#
# Assertions (structural boundary tests per Behavioral Testing Standard Rule 5):
#   CP1: Phase 1 Step 1 (epic selection) has PREPLANNING_INTERACTIVE + INTERACTIVITY_DEFERRED
#   CP2: Phase 1 Step 1b (escalation policy) has PREPLANNING_INTERACTIVE
#   CP3: Phase 1 Step 3 (scope clarification) has PREPLANNING_INTERACTIVE + INTERACTIVITY_DEFERRED
#   CP4: Phase 1 Step 4 (reconciliation approval) has PREPLANNING_INTERACTIVE + in_progress guard
#   CP5: Phase 4 Step 3 (story dashboard) has PREPLANNING_INTERACTIVE
#   CP6: Phase 4 Step 5 (final approval) has PREPLANNING_INTERACTIVE
#   CP7: ui-designer-dispatch-protocol.md has PREPLANNING_INTERACTIVE anywhere
#
# Expected (RED): All 7 tests FAIL against current SKILL.md (patterns not yet present).
# Will turn GREEN after tasks T2 and T3 of story 12bf-521f are implemented.
#
# Usage: bash tests/skills/test-preplanning-noninteractive-checkpoints.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/preplanning/SKILL.md"
DISPATCH_PROTOCOL="${REPO_ROOT}/plugins/dso/skills/preplanning/prompts/ui-designer-dispatch-protocol.md"

PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Section extractor: extracts text from a heading until the next same-level heading or EOF.
# Args: $1=file, $2=heading_regex (Python regex matching the start of the heading line)
# ---------------------------------------------------------------------------
extract_section() {
  local file="$1"
  local heading_pattern="$2"
  python3 - "$file" "$heading_pattern" <<'PYEOF'
import sys, re

file_path = sys.argv[1]
heading_pattern = sys.argv[2]

text = open(file_path).read()

# Find the start of the target heading
start_match = re.search(heading_pattern, text, re.MULTILINE)
if not start_match:
    sys.exit(0)  # empty output — heading not found

rest = text[start_match.start():]

# Determine heading level (number of leading '#' chars)
level_match = re.match(r'^(#+)', rest)
level = len(level_match.group(1)) if level_match else 3

# Find the next heading at same or higher level (fewer or equal '#')
next_heading_pattern = r'\n' + r'#{1,' + str(level) + r'}' + r' '
end_match = re.search(next_heading_pattern, rest[1:])
if end_match:
    section = rest[:end_match.start() + 1]
else:
    section = rest

print(section)
PYEOF
}

# ---------------------------------------------------------------------------
# test_cp1_no_epic_id_non_interactive
# Phase 1 Step 1 (epic selection): must have PREPLANNING_INTERACTIVE + INTERACTIVITY_DEFERRED
# ---------------------------------------------------------------------------
echo "=== test_cp1_no_epic_id_non_interactive ==="
SECTION="test_cp1_no_epic_id_non_interactive"

STEP1_SECTION="$(extract_section "$SKILL_MD" '^### Step 1: Select and Load Epic')"

CP1_INTERACTIVE=false
CP1_DEFERRED=false

if grep -qE "PREPLANNING_INTERACTIVE" <<< "$STEP1_SECTION"; then
  CP1_INTERACTIVE=true
fi
if grep -qE "INTERACTIVITY_DEFERRED" <<< "$STEP1_SECTION"; then
  CP1_DEFERRED=true
fi

if [ "$CP1_INTERACTIVE" = "true" ] && [ "$CP1_DEFERRED" = "true" ]; then
  pass "CP1 (Step 1 epic selection) has PREPLANNING_INTERACTIVE and INTERACTIVITY_DEFERRED branches"
else
  [ "$CP1_INTERACTIVE" = "false" ] && fail "CP1 missing PREPLANNING_INTERACTIVE branch in Phase 1 Step 1 (epic selection)"
  [ "$CP1_DEFERRED" = "false" ] && fail "CP1 missing INTERACTIVITY_DEFERRED branch in Phase 1 Step 1 (epic selection)"
fi

# ---------------------------------------------------------------------------
# test_cp2_escalation_policy_default
# Phase 1 Step 1b (escalation policy): must have PREPLANNING_INTERACTIVE near AskUserQuestion
# ---------------------------------------------------------------------------
echo ""
echo "=== test_cp2_escalation_policy_default ==="
SECTION="test_cp2_escalation_policy_default"

STEP1B_SECTION="$(extract_section "$SKILL_MD" '^### Step 1b: Select Escalation Policy')"

if grep -qE "PREPLANNING_INTERACTIVE" <<< "$STEP1B_SECTION"; then
  pass "CP2 (Step 1b escalation policy) has PREPLANNING_INTERACTIVE branch"
else
  fail "CP2 missing PREPLANNING_INTERACTIVE branch in Phase 1 Step 1b (escalation policy / AskUserQuestion)"
fi

# ---------------------------------------------------------------------------
# test_cp3_scope_clarification_exit
# Phase 1 Step 3 (reconcile existing work): must have PREPLANNING_INTERACTIVE + INTERACTIVITY_DEFERRED
# near "pause and ask" / scope clarification text
# ---------------------------------------------------------------------------
echo ""
echo "=== test_cp3_scope_clarification_exit ==="
SECTION="test_cp3_scope_clarification_exit"

STEP3_SECTION="$(extract_section "$SKILL_MD" '^### Step 3: Reconcile Existing Work')"

CP3_INTERACTIVE=false
CP3_DEFERRED=false

if grep -qE "PREPLANNING_INTERACTIVE" <<< "$STEP3_SECTION"; then
  CP3_INTERACTIVE=true
fi
if grep -qE "INTERACTIVITY_DEFERRED" <<< "$STEP3_SECTION"; then
  CP3_DEFERRED=true
fi

if [ "$CP3_INTERACTIVE" = "true" ] && [ "$CP3_DEFERRED" = "true" ]; then
  pass "CP3 (Step 3 scope clarification) has PREPLANNING_INTERACTIVE and INTERACTIVITY_DEFERRED branches"
else
  [ "$CP3_INTERACTIVE" = "false" ] && fail "CP3 missing PREPLANNING_INTERACTIVE branch in Phase 1 Step 3 (scope clarification / pause and ask)"
  [ "$CP3_DEFERRED" = "false" ] && fail "CP3 missing INTERACTIVITY_DEFERRED branch in Phase 1 Step 3 (scope clarification / pause and ask)"
fi

# ---------------------------------------------------------------------------
# test_cp4_reconciliation_auto_apply
# Phase 1 Step 4 (reconciliation plan): must have PREPLANNING_INTERACTIVE near AskUserQuestion
# and an in_progress guard preventing auto-deletion of in_progress children
# ---------------------------------------------------------------------------
echo ""
echo "=== test_cp4_reconciliation_auto_apply ==="
SECTION="test_cp4_reconciliation_auto_apply"

STEP4_SECTION="$(extract_section "$SKILL_MD" '^### Step 4: Document Reconciliation Plan')"

CP4_INTERACTIVE=false
CP4_INPROGRESS_GUARD=false

if grep -qE "PREPLANNING_INTERACTIVE" <<< "$STEP4_SECTION"; then
  CP4_INTERACTIVE=true
fi
if grep -qiE "in_progress.*guard|guard.*in_progress|skip.*in_progress.*delete|in_progress.*auto|never.*delete.*in_progress|do not.*delete.*in_progress" <<< "$STEP4_SECTION"; then
  CP4_INPROGRESS_GUARD=true
fi

if [ "$CP4_INTERACTIVE" = "true" ] && [ "$CP4_INPROGRESS_GUARD" = "true" ]; then
  pass "CP4 (Step 4 reconciliation) has PREPLANNING_INTERACTIVE branch and in_progress guard"
else
  [ "$CP4_INTERACTIVE" = "false" ] && fail "CP4 missing PREPLANNING_INTERACTIVE branch in Phase 1 Step 4 (reconciliation / AskUserQuestion)"
  [ "$CP4_INPROGRESS_GUARD" = "false" ] && fail "CP4 missing in_progress guard in Phase 1 Step 4 (must not auto-delete in_progress children)"
fi

# ---------------------------------------------------------------------------
# test_cp5_story_dashboard_suppress
# Phase 4 Step 3 (story dashboard): must have PREPLANNING_INTERACTIVE near "Present" / dashboard text
# ---------------------------------------------------------------------------
echo ""
echo "=== test_cp5_story_dashboard_suppress ==="
SECTION="test_cp5_story_dashboard_suppress"

STEP_DASHBOARD_SECTION="$(extract_section "$SKILL_MD" '^### Step 3: Present Story Dashboard')"

if grep -qE "PREPLANNING_INTERACTIVE" <<< "$STEP_DASHBOARD_SECTION"; then
  pass "CP5 (Phase 4 Step 3 story dashboard) has PREPLANNING_INTERACTIVE branch"
else
  fail "CP5 missing PREPLANNING_INTERACTIVE branch in Phase 4 Step 3 (Story Dashboard / Present)"
fi

# ---------------------------------------------------------------------------
# test_cp6_final_approval_skip
# Phase 4 Step 5 (final review prompt / approval): must have PREPLANNING_INTERACTIVE near AskUserQuestion
# ---------------------------------------------------------------------------
echo ""
echo "=== test_cp6_final_approval_skip ==="
SECTION="test_cp6_final_approval_skip"

STEP5_SECTION="$(extract_section "$SKILL_MD" '^### Step 5: Final Review Prompt')"

if grep -qE "PREPLANNING_INTERACTIVE" <<< "$STEP5_SECTION"; then
  pass "CP6 (Phase 4 Step 5 final approval) has PREPLANNING_INTERACTIVE branch"
else
  fail "CP6 missing PREPLANNING_INTERACTIVE branch in Phase 4 Step 5 (final approval / AskUserQuestion)"
fi

# ---------------------------------------------------------------------------
# test_cp7_ui_designer_interactivity_deferred
# ui-designer-dispatch-protocol.md: must contain PREPLANNING_INTERACTIVE anywhere in the file
# ---------------------------------------------------------------------------
echo ""
echo "=== test_cp7_ui_designer_interactivity_deferred ==="
SECTION="test_cp7_ui_designer_interactivity_deferred"

if grep -qE "PREPLANNING_INTERACTIVE" "$DISPATCH_PROTOCOL"; then
  pass "CP7 (ui-designer-dispatch-protocol.md) contains PREPLANNING_INTERACTIVE"
else
  fail "CP7 missing PREPLANNING_INTERACTIVE in ui-designer-dispatch-protocol.md (required for non-interactive scope-split handling)"
fi

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
