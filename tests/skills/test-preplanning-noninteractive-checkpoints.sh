#!/usr/bin/env bash
# tests/skills/test-preplanning-noninteractive-checkpoints.sh
# Structural boundary tests for PREPLANNING_INTERACTIVE conditional branches in
# plugins/dso/skills/preplanning/SKILL.md (CP1-CP6) and
# plugins/dso/skills/preplanning/prompts/ui-designer-dispatch-protocol.md (CP7).
#
# Each test asserts that the relevant section of SKILL.md (or dispatch-protocol.md)
# contains the required PREPLANNING_INTERACTIVE branching text at the checkpoint.
#
# Per behavioral-testing-standard.md Rule 5: structural boundary tests are the
# correct test type for non-executable LLM instruction files.
#
# Usage: bash tests/skills/test-preplanning-noninteractive-checkpoints.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/preplanning/SKILL.md"
DISPATCH_PROTOCOL="${REPO_ROOT}/plugins/dso/skills/preplanning/prompts/ui-designer-dispatch-protocol.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Helper: extract text around a heading (the section from heading to next ##-heading or EOF)
# ---------------------------------------------------------------------------
extract_section_by_heading() {
  local file="$1"
  local heading_pattern="$2"
  python3 - "$file" "$heading_pattern" <<'PYEOF'
import sys, re

file_path = sys.argv[1]
heading_pattern = sys.argv[2]

text = open(file_path).read()
start = re.search(heading_pattern, text, re.MULTILINE)
if not start:
    sys.exit(0)
rest = text[start.start():]
end_match = re.search(r'\n## ', rest[1:])
if end_match:
    section = rest[:end_match.start() + 1]
else:
    section = rest
print(section)
PYEOF
}

# ---------------------------------------------------------------------------
# Helper: extract a numbered step section from SKILL.md
# (from "### Step N:" heading to next "### " heading or "---" or "## " or EOF)
# ---------------------------------------------------------------------------
extract_step_section() {
  local file="$1"
  local step_pattern="$2"
  python3 - "$file" "$step_pattern" <<'PYEOF'
import sys, re

file_path = sys.argv[1]
step_pattern = sys.argv[2]

text = open(file_path).read()
start = re.search(step_pattern, text, re.MULTILINE)
if not start:
    sys.exit(0)
rest = text[start.start():]
# Find the next ### heading, --- separator, or ## heading
end_match = re.search(r'\n(###|##\s|---)', rest[4:])
if end_match:
    section = rest[:end_match.start() + 4]
else:
    section = rest
print(section)
PYEOF
}

# ===========================================================================
# CP1: Phase 1 Step 1 — epic selection non-interactive exit
# ===========================================================================
echo "=== test_cp1_no_epic_id_non_interactive ==="
SECTION="test_cp1_no_epic_id_non_interactive"

STEP1_SECTION="$(extract_step_section "$SKILL_MD" '^### Step 1: Select and Load Epic')"

if grep -qiE "PREPLANNING_INTERACTIVE" <<< "$STEP1_SECTION"; then
  pass "Phase 1 Step 1 contains PREPLANNING_INTERACTIVE branch"
else
  fail "Phase 1 Step 1 missing PREPLANNING_INTERACTIVE branch — required for non-interactive mode when no epic-id is provided"
fi

echo ""
SECTION="test_cp1_exit_on_no_epic_id"
if grep -qiE "INTERACTIVITY_DEFERRED|Exit with error|no epic-id|epic-id.*not.*provided|no.*epic.*provided" <<< "$STEP1_SECTION"; then
  pass "Phase 1 Step 1 contains exit/error instruction for non-interactive mode without epic-id"
else
  fail "Phase 1 Step 1 missing exit/error text for non-interactive mode without epic-id (expected INTERACTIVITY_DEFERRED or similar)"
fi

# ===========================================================================
# CP2: Phase 1 Step 1b — escalation policy default in non-interactive mode
# ===========================================================================
echo ""
echo "=== test_cp2_escalation_policy_default ==="
SECTION="test_cp2_escalation_policy_default"

STEP1B_SECTION="$(extract_step_section "$SKILL_MD" '^### Step 1b: Select Escalation Policy')"

if grep -qiE "PREPLANNING_INTERACTIVE" <<< "$STEP1B_SECTION"; then
  pass "Phase 1 Step 1b contains PREPLANNING_INTERACTIVE branch"
else
  fail "Phase 1 Step 1b missing PREPLANNING_INTERACTIVE branch — required for non-interactive mode default escalation policy"
fi

echo ""
SECTION="test_cp2_escalate_when_blocked_default"
if grep -qiE "Escalate when blocked|escalation.*default|default.*escalation" <<< "$STEP1B_SECTION"; then
  pass "Phase 1 Step 1b specifies 'Escalate when blocked' as default for non-interactive mode"
else
  fail "Phase 1 Step 1b missing default escalation policy ('Escalate when blocked') for non-interactive mode"
fi

# ===========================================================================
# CP3: Phase 1 Step 3 — scope clarification non-interactive exit
# ===========================================================================
echo ""
echo "=== test_cp3_scope_clarification_exit ==="
SECTION="test_cp3_scope_clarification_exit"

STEP3_SECTION="$(extract_step_section "$SKILL_MD" '^### Step 3: Reconcile Existing Work')"

if grep -qiE "PREPLANNING_INTERACTIVE" <<< "$STEP3_SECTION"; then
  pass "Phase 1 Step 3 contains PREPLANNING_INTERACTIVE branch"
else
  fail "Phase 1 Step 3 missing PREPLANNING_INTERACTIVE branch — required for non-interactive scope clarification exit"
fi

echo ""
SECTION="test_cp3_interactivity_deferred"
if grep -qiE "INTERACTIVITY_DEFERRED|Exit with error|scope clarification" <<< "$STEP3_SECTION"; then
  pass "Phase 1 Step 3 contains INTERACTIVITY_DEFERRED or exit instruction for non-interactive scope clarification"
else
  fail "Phase 1 Step 3 missing INTERACTIVITY_DEFERRED or exit instruction for non-interactive scope clarification"
fi

# ===========================================================================
# CP4: Phase 1 Step 4 — reconciliation auto-apply in non-interactive mode
# ===========================================================================
echo ""
echo "=== test_cp4_reconciliation_auto_apply ==="
SECTION="test_cp4_reconciliation_auto_apply"

STEP4_SECTION="$(extract_step_section "$SKILL_MD" '^### Step 4: Document Reconciliation Plan')"

if grep -qiE "PREPLANNING_INTERACTIVE" <<< "$STEP4_SECTION"; then
  pass "Phase 1 Step 4 contains PREPLANNING_INTERACTIVE branch"
else
  fail "Phase 1 Step 4 missing PREPLANNING_INTERACTIVE branch — required for non-interactive reconciliation auto-apply"
fi

echo ""
SECTION="test_cp4_auto_apply"
if grep -qiE "auto-apply|automatically apply|skip.*AskUserQuestion|AskUserQuestion.*skip" <<< "$STEP4_SECTION"; then
  pass "Phase 1 Step 4 contains auto-apply instruction for non-interactive mode"
else
  fail "Phase 1 Step 4 missing auto-apply instruction for non-interactive mode (expected auto-apply or skip AskUserQuestion)"
fi

echo ""
SECTION="test_cp4_in_progress_guard"
if grep -qiE "in_progress|in-progress" <<< "$STEP4_SECTION"; then
  pass "Phase 1 Step 4 contains in_progress guard for auto-apply (no auto-delete of in_progress stories)"
else
  fail "Phase 1 Step 4 missing in_progress guard — non-interactive auto-apply must not delete in_progress stories"
fi

# ===========================================================================
# CP5: Phase 4 Step 3 — story dashboard suppress in non-interactive mode
# ===========================================================================
echo ""
echo "=== test_cp5_story_dashboard_suppress ==="
SECTION="test_cp5_story_dashboard_suppress"

STEP3_P4_SECTION="$(extract_step_section "$SKILL_MD" '^### Step 3: Present Story Dashboard')"

if grep -qiE "PREPLANNING_INTERACTIVE" <<< "$STEP3_P4_SECTION"; then
  pass "Phase 4 Step 3 contains PREPLANNING_INTERACTIVE branch"
else
  fail "Phase 4 Step 3 missing PREPLANNING_INTERACTIVE branch — required for non-interactive dashboard suppress"
fi

echo ""
SECTION="test_cp5_suppress_dashboard"
if grep -qiE "suppress|skip.*dashboard|dashboard.*skip|continue.*silently|silently.*continue|omit.*dashboard|dashboard.*omit" <<< "$STEP3_P4_SECTION"; then
  pass "Phase 4 Step 3 contains suppress/skip instruction for non-interactive mode"
else
  fail "Phase 4 Step 3 missing suppress instruction for non-interactive mode (expected suppress, skip, or continue silently)"
fi

# ===========================================================================
# CP6: Phase 4 Step 5 — final approval skip in non-interactive mode
# ===========================================================================
echo ""
echo "=== test_cp6_final_approval_skip ==="
SECTION="test_cp6_final_approval_skip"

STEP5_P4_SECTION="$(extract_step_section "$SKILL_MD" '^### Step 5: Final Review Prompt')"

if grep -qiE "PREPLANNING_INTERACTIVE" <<< "$STEP5_P4_SECTION"; then
  pass "Phase 4 Step 5 contains PREPLANNING_INTERACTIVE branch"
else
  fail "Phase 4 Step 5 missing PREPLANNING_INTERACTIVE branch — required for non-interactive final approval skip"
fi

echo ""
SECTION="test_cp6_skip_approval"
if grep -qiE "skip.*approval|approval.*skip|skip.*AskUserQuestion|AskUserQuestion.*skip|proceed.*automatically|automatically.*proceed" <<< "$STEP5_P4_SECTION"; then
  pass "Phase 4 Step 5 contains skip-approval instruction for non-interactive mode"
else
  fail "Phase 4 Step 5 missing skip-approval instruction for non-interactive mode (expected skip approval or proceed automatically)"
fi

# ===========================================================================
# CP7: ui-designer-dispatch-protocol.md — INTERACTIVITY_DEFERRED wiring
# (This test remains RED until task 63f6-a768 is implemented)
# ===========================================================================
echo ""
echo "=== test_cp7_ui_designer_interactivity_deferred ==="
SECTION="test_cp7_ui_designer_interactivity_deferred"

if [[ ! -f "$DISPATCH_PROTOCOL" ]]; then
  fail "ui-designer-dispatch-protocol.md not found at $DISPATCH_PROTOCOL"
else
  if grep -qE "PREPLANNING_INTERACTIVE" "$DISPATCH_PROTOCOL"; then
    pass "ui-designer-dispatch-protocol.md references PREPLANNING_INTERACTIVE to wire INTERACTIVITY_DEFERRED paths"
  else
    fail "ui-designer-dispatch-protocol.md missing PREPLANNING_INTERACTIVE reference — CP7 is handled by task 63f6-a768 (T3)"
  fi
fi

# ===========================================================================
# Summary
# ===========================================================================
echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
  echo "VALIDATION FAILED"
  exit 1
else
  echo "VALIDATION PASSED"
  exit 0
fi
