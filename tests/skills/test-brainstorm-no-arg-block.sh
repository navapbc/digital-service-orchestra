#!/usr/bin/env bash
# Structural boundary test for brainstorm SKILL.md no-arg epic-selection block.
# Rule 5 compliant: tests structural tokens (exact command invocations) that the SKILL.md
# must contain — specific flag combinations are structural identifiers, not prose.
#
# RED marker: [test_brainstorm_no_arg_block]
# GREEN sibling: task 993b-6d2f (adds the two-call block to SKILL.md)
#
# Asserts:
#   1. SKILL.md contains sprint-list-epics.sh --max-children=0 (zero-child epics call)
#   2. SKILL.md contains sprint-list-epics.sh --min-children=1 --without-tag=brainstorm:complete
#      (scrutiny-gap epics call)
#   3. Two distinct labeled sections distinguishing zero-child vs scrutiny-gap categories exist
#      in the no-arg invocation block.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"

PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Section 1: zero-child epics command invocation
# ---------------------------------------------------------------------------
echo "=== test_zero_child_call ==="
SECTION="test_zero_child_call"

if grep -qF 'sprint-list-epics.sh --max-children=0' "$SKILL_MD"; then
  pass "SKILL.md contains sprint-list-epics.sh --max-children=0"
else
  fail "SKILL.md is missing 'sprint-list-epics.sh --max-children=0' — the zero-child epics command invocation"
fi

# ---------------------------------------------------------------------------
# Section 2: scrutiny-gap epics command invocation
# ---------------------------------------------------------------------------
echo "=== test_scrutiny_gap_call ==="
SECTION="test_scrutiny_gap_call"

if grep -qF 'sprint-list-epics.sh --min-children=1 --without-tag=brainstorm:complete' "$SKILL_MD"; then
  pass "SKILL.md contains sprint-list-epics.sh --min-children=1 --without-tag=brainstorm:complete"
else
  fail "SKILL.md is missing 'sprint-list-epics.sh --min-children=1 --without-tag=brainstorm:complete' — the scrutiny-gap epics command invocation"
fi

# ---------------------------------------------------------------------------
# Section 3: two distinct labeled sections for the two categories
# ---------------------------------------------------------------------------
echo "=== test_two_labeled_sections ==="
SECTION="test_two_labeled_sections"

# Extract the no-arg invocation block: from "When invoked without a ticket ID" up to the next
# heading or "When invoked with a ticket ID". This is the structural boundary that must contain
# both labeled sections.
_no_arg_block=$(python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Capture from "When invoked without a ticket ID" to "When invoked with a ticket ID"
# or the next top-level section boundary.
pattern = r'(?s)(When invoked without a ticket ID.*?)(?=When invoked with a ticket ID|^---|\Z)'
match = re.search(pattern, content, re.MULTILINE)
if match:
    print(match.group(1))
EOF
)

if [ -z "$_no_arg_block" ]; then
  fail "Could not extract no-arg invocation block from SKILL.md — 'When invoked without a ticket ID' section not found"
else
  # Count labeled sections: look for section markers that label the two distinct categories.
  # A labeled section must have a heading or bold label that names the category.
  # We require at least two such labels — one for zero-child epics and one for scrutiny-gap epics.
  # Structural tokens: the labels must reference the category concept, not just list commands.
  _zero_child_label=$(echo "$_no_arg_block" | grep -c -iE '(zero.child|0.child|no.child|empty.epic)' 2>/dev/null || true)
  _scrutiny_gap_label=$(echo "$_no_arg_block" | grep -c -iE '(scrutiny.gap|brainstorm:complete|without.tag|needs.brainstorm)' 2>/dev/null || true)

  if [ "$_zero_child_label" -ge 1 ] && [ "$_scrutiny_gap_label" -ge 1 ]; then
    pass "No-arg block contains two distinct labeled sections: zero-child category ($_zero_child_label match(es)) and scrutiny-gap category ($_scrutiny_gap_label match(es))"
  elif [ "$_zero_child_label" -lt 1 ] && [ "$_scrutiny_gap_label" -lt 1 ]; then
    fail "No-arg block is missing both labeled sections — neither zero-child nor scrutiny-gap categories are labeled"
  elif [ "$_zero_child_label" -lt 1 ]; then
    fail "No-arg block is missing zero-child category label (scrutiny-gap label present: $_scrutiny_gap_label)"
  else
    fail "No-arg block is missing scrutiny-gap category label (zero-child label present: $_zero_child_label)"
  fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
