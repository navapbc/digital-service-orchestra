#!/usr/bin/env bash
# Structural boundary test for brainstorm SKILL.md no-arg epic-selection block.
# Rule 5 compliant: tests structural tokens (exact command invocations) that the SKILL.md
# must contain — specific flag combinations are structural identifiers, not prose.
#
# Asserts:
#   1. SKILL.md invokes ticket list-epics --brainstorm (the combined categorized call)
#   2. SKILL.md names both categories (zero-child and scrutiny-gap) so the user can distinguish them
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"

PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Section 1: combined --brainstorm invocation
# ---------------------------------------------------------------------------
echo "=== test_brainstorm_flag_call ==="
SECTION="test_brainstorm_flag_call"

if grep -qF 'ticket list-epics --brainstorm' "$SKILL_MD"; then
  pass "SKILL.md contains ticket list-epics --brainstorm"
else
  fail "SKILL.md is missing 'ticket list-epics --brainstorm' — the combined epic-selection call"
fi

# ---------------------------------------------------------------------------
# Section 2: both categories named so the no-arg selection list distinguishes them
# ---------------------------------------------------------------------------
echo "=== test_two_labeled_sections ==="
SECTION="test_two_labeled_sections"

_no_arg_block=$(python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

pattern = r'(?s)(When invoked without a ticket ID.*?)(?=When invoked with a ticket ID|^---|\Z)'
match = re.search(pattern, content, re.MULTILINE)
if match:
    print(match.group(1))
EOF
)

if [ -z "$_no_arg_block" ]; then
  fail "Could not extract no-arg invocation block from SKILL.md"
else
  _zero_child_label=$(echo "$_no_arg_block" | grep -c -iE '(zero.child|0.child|no.child|empty.epic)' 2>/dev/null || true)
  _scrutiny_gap_label=$(echo "$_no_arg_block" | grep -c -iE '(scrutiny.gap|brainstorm:complete|without.tag|needs.brainstorm)' 2>/dev/null || true)

  if [ "$_zero_child_label" -ge 1 ] && [ "$_scrutiny_gap_label" -ge 1 ]; then
    pass "No-arg block names both categories (zero-child: $_zero_child_label, scrutiny-gap: $_scrutiny_gap_label)"
  elif [ "$_zero_child_label" -lt 1 ] && [ "$_scrutiny_gap_label" -lt 1 ]; then
    fail "No-arg block is missing both category labels"
  elif [ "$_zero_child_label" -lt 1 ]; then
    fail "No-arg block is missing zero-child category label"
  else
    fail "No-arg block is missing scrutiny-gap category label"
  fi
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
