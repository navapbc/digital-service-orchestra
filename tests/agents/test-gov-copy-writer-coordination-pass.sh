#!/usr/bin/env bash
# tests/test-gov-copy-writer-coordination-pass.sh
# Behavioral tests for the coordination-pass dispatch documentation.
#
# Covers story c5ef-a8ba-e889-4c88, task cb7a-ea94-a2ba-4d62.
# DDs tested:
#   dd-3 (c5ef): the coordination-pass dispatch receives the full first-pass rationale
#                (rule_ids, conflicts, deviations) as input
#
# Test plan:
#   1. gov-copy-writer.md documents a "Coordination Pass Mode" section
#   2. gov-copy-writer.md mentions hard-constraint immutability in coordination-pass context
#   3. gov-copy-writer.md references the first_pass_rationale_path input parameter
#   4. sprint SKILL.md documents coordination-pass dispatch under copy story dispatch
#   5. gov-copy-writer.md coordination section specifies IMMUTABLE items are never changed
#   6. gov-copy-writer.md coordination section documents snapshot as read-only input
#   7. gov-copy-writer.md coordination section defines GOV_COPY_WRITER_COORDINATION_RESULT
#   8. sprint SKILL.md references snapshot to avoid first-pass artifact race condition

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_PLUGIN_ROOT="$(cd "$_SCRIPT_DIR/../../plugins/dso" && pwd)"

AGENT_FILE="$_PLUGIN_ROOT/agents/gov-copy-writer.md"
SPRINT_SKILL="$_PLUGIN_ROOT/skills/sprint/SKILL.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "=== gov-copy-writer coordination-pass dispatch behavioral tests ==="

# ---------------------------------------------------------------------------
# Test 1: gov-copy-writer.md documents "Coordination Pass Mode" section
# ---------------------------------------------------------------------------
echo ""
echo "--- test 1: Coordination Pass Mode section in gov-copy-writer.md ---"
if grep -q 'Coordination Pass Mode' "$AGENT_FILE"; then
  pass "gov-copy-writer.md contains 'Coordination Pass Mode' section"
else
  fail "gov-copy-writer.md is missing 'Coordination Pass Mode' section"
fi

# ---------------------------------------------------------------------------
# Test 2: gov-copy-writer.md mentions hard-constraint immutability in
#         coordination-pass context
# ---------------------------------------------------------------------------
echo ""
echo "--- test 2: hard-constraint immutability in coordination-pass context ---"
if grep -q 'Coordination Pass' "$AGENT_FILE" && grep -q 'hard_constraint' "$AGENT_FILE" && grep -qiE 'IMMUTABLE|immutable' "$AGENT_FILE"; then
  pass "gov-copy-writer.md documents hard_constraint immutability (IMMUTABLE keyword present)"
else
  fail "gov-copy-writer.md does not document hard_constraint immutability in coordination-pass context"
fi

# Verify immutability is explicitly stated for the coordination-pass section specifically
if grep -A 60 'Coordination Pass Mode' "$AGENT_FILE" | grep -qiE 'IMMUTABLE|immutable'; then
  pass "Coordination Pass Mode section itself mentions IMMUTABLE"
else
  fail "Coordination Pass Mode section does not mention IMMUTABLE"
fi

# ---------------------------------------------------------------------------
# Test 3: gov-copy-writer.md references the first_pass_rationale_path input parameter
# ---------------------------------------------------------------------------
echo ""
echo "--- test 3: first_pass_rationale_path input parameter ---"
if grep -q 'first_pass_rationale_path' "$AGENT_FILE"; then
  pass "gov-copy-writer.md references 'first_pass_rationale_path' input parameter"
else
  fail "gov-copy-writer.md does not reference 'first_pass_rationale_path'"
fi

# Verify it appears in the Inputs or Coordination Pass Mode section context
if grep -A 20 'Coordination Pass Mode' "$AGENT_FILE" | grep -q 'first_pass_rationale_path'; then
  pass "Coordination Pass Mode section references first_pass_rationale_path"
else
  fail "Coordination Pass Mode section does not reference first_pass_rationale_path"
fi

# ---------------------------------------------------------------------------
# Test 4: sprint SKILL.md documents coordination-pass dispatch under copy story dispatch
# ---------------------------------------------------------------------------
echo ""
echo "--- test 4: sprint SKILL.md documents coordination-pass dispatch ---"
if grep -q 'coordination-pass' "$SPRINT_SKILL" || grep -q 'Coordination-Pass' "$SPRINT_SKILL"; then
  pass "sprint SKILL.md contains coordination-pass dispatch documentation"
else
  fail "sprint SKILL.md does not document coordination-pass dispatch"
fi

# Verify it appears near the copy story dispatch section
if grep -A 80 'Copy Story Dispatch' "$SPRINT_SKILL" | grep -qiE 'coordination.pass|Coordination.Pass'; then
  pass "Coordination-pass dispatch is documented within the Copy Story Dispatch section of sprint SKILL.md"
else
  fail "Coordination-pass dispatch is not documented within Copy Story Dispatch in sprint SKILL.md"
fi

# ---------------------------------------------------------------------------
# Test 5: gov-copy-writer.md coordination section specifies IMMUTABLE items
#         are never changed
# ---------------------------------------------------------------------------
echo ""
echo "--- test 5: IMMUTABLE items are never changed ---"
# Check that the coordination-pass section explicitly says IMMUTABLE items cannot be changed
if grep -A 100 'Coordination Pass Mode' "$AGENT_FILE" | grep -qiE 'never changed|values unchanged|never.*(alter|modify|change).*IMMUTABLE|IMMUTABLE.*never'; then
  pass "Coordination Pass Mode section states IMMUTABLE items are never changed"
else
  fail "Coordination Pass Mode section does not state IMMUTABLE items are never changed"
fi

# Check that immutability is absolute (no override)
if grep -A 100 'Coordination Pass Mode' "$AGENT_FILE" | grep -qiE 'cannot be overridden|absolute|no.*override|supersedes'; then
  pass "Coordination Pass Mode section states immutability rule is absolute/cannot be overridden"
else
  fail "Coordination Pass Mode section does not state immutability rule is absolute"
fi

# ---------------------------------------------------------------------------
# Test 6: gov-copy-writer.md coordination section documents snapshot as read-only
# ---------------------------------------------------------------------------
echo ""
echo "--- test 6: snapshot is read-only input ---"
if grep -A 100 'Coordination Pass Mode' "$AGENT_FILE" | grep -qiE 'read.only|snapshot'; then
  pass "Coordination Pass Mode section documents snapshot as read-only reference"
else
  fail "Coordination Pass Mode section does not mention snapshot or read-only constraint"
fi

# Verify snapshot cannot be written to
if grep -A 100 'Coordination Pass Mode' "$AGENT_FILE" | grep -qiE 'do not write|never write.*snapshot|snapshot.*read.only'; then
  pass "Coordination Pass Mode section explicitly prohibits writing to snapshot path"
else
  fail "Coordination Pass Mode section does not prohibit writing to snapshot path"
fi

# ---------------------------------------------------------------------------
# Test 7: gov-copy-writer.md coordination section defines
#         GOV_COPY_WRITER_COORDINATION_RESULT
# ---------------------------------------------------------------------------
echo ""
echo "--- test 7: GOV_COPY_WRITER_COORDINATION_RESULT output format ---"
if grep -q 'GOV_COPY_WRITER_COORDINATION_RESULT' "$AGENT_FILE"; then
  pass "gov-copy-writer.md defines GOV_COPY_WRITER_COORDINATION_RESULT output format"
else
  fail "gov-copy-writer.md does not define GOV_COPY_WRITER_COORDINATION_RESULT"
fi

# Verify it includes items_immutable to distinguish from first-pass result
if grep -A 10 'GOV_COPY_WRITER_COORDINATION_RESULT' "$AGENT_FILE" | grep -q 'items_immutable'; then
  pass "GOV_COPY_WRITER_COORDINATION_RESULT includes items_immutable field"
else
  fail "GOV_COPY_WRITER_COORDINATION_RESULT missing items_immutable field"
fi

# ---------------------------------------------------------------------------
# Test 8: sprint SKILL.md references snapshot to avoid race condition with
#         first-pass artifact
# ---------------------------------------------------------------------------
echo ""
echo "--- test 8: sprint SKILL.md documents snapshot to avoid race condition ---"
if grep -A 80 'Coordination-Pass Dispatch' "$SPRINT_SKILL" | grep -qiE 'snapshot|stable.*input|race'; then
  pass "sprint SKILL.md documents snapshot mechanism in coordination-pass dispatch"
else
  fail "sprint SKILL.md does not document snapshot mechanism for coordination-pass dispatch"
fi

if grep -A 80 'Coordination-Pass Dispatch' "$SPRINT_SKILL" | grep -q 'mktemp'; then
  pass "sprint SKILL.md shows mktemp usage for snapshot path (avoids hardcoded paths)"
else
  fail "sprint SKILL.md does not use mktemp for snapshot path"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if [[ "$FAIL" -gt 0 ]]; then
  exit 1
fi
exit 0
