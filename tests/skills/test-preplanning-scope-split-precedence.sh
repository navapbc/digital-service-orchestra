#!/usr/bin/env bash
# tests/skills/test-preplanning-scope-split-precedence.sh
# RED test for SC6 of epic 28cb-a23a:
#   dispatch-protocol.md Section 5 must enforce a splitRole guard at its start:
#   when preplanning already split the story (story has splitRole metadata),
#   agent scope_split_proposals are skipped entirely.
#   When preplanning has NOT split the story, agent proposals are processed normally.
#
# Assertions (all must pass GREEN after fix):
#   1. Section 5 heading exists in dispatch-protocol.md
#   2. Section 5 contains an explicit guard/gate at its start that checks
#      whether preplanning has already split the story via splitRole metadata
#   3. Section 5 explicitly states that the preplanning split is authoritative
#      and agent proposals are skipped when splitRole is present
#   4. SKILL.md around line 385 references the Section 5 enforcement gate
#      (not just a behavioral note without enforcement)
#
# Usage: bash tests/skills/test-preplanning-scope-split-precedence.sh
set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
DISPATCH_PROTOCOL="${REPO_ROOT}/plugins/dso/skills/preplanning/prompts/ui-designer-dispatch-protocol.md"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/preplanning/SKILL.md"

PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Extract Section 5 from dispatch-protocol.md:
#   from the "## 5." heading to the next "## " heading (or EOF).
# Returns empty string if the heading is not found.
# ---------------------------------------------------------------------------
extract_section_5() {
  python3 - "$DISPATCH_PROTOCOL" <<'PYEOF'
import sys, re

text = open(sys.argv[1]).read()
# Match "## 5." heading (with any suffix after "5.")
start = re.search(r'^## 5\.', text, re.MULTILINE)
if not start:
    sys.exit(0)
rest = text[start.start():]
# Find the next ## heading after the first line
end_match = re.search(r'\n## ', rest[1:])
if end_match:
    section = rest[:end_match.start() + 1]
else:
    section = rest
print(section)
PYEOF
}

SECTION5="$(extract_section_5)"

# ---------------------------------------------------------------------------
# Test 1: Section 5 heading exists in dispatch-protocol.md
# ---------------------------------------------------------------------------
echo "=== test_section5_heading ==="
SECTION="test_section5_heading"
if grep -qE "^## 5\." "$DISPATCH_PROTOCOL"; then
  pass "dispatch-protocol.md has a '## 5.' section heading"
else
  fail "dispatch-protocol.md missing '## 5.' section heading"
fi

# ---------------------------------------------------------------------------
# Test 2: Section 5 has an explicit splitRole guard at its start
#   The guard must use the term "splitRole" to identify whether preplanning
#   already created a split. Terms like "Foundation" and "Enhancement" alone
#   do not constitute a guard — the guard must reference the metadata key.
# ---------------------------------------------------------------------------
echo ""
echo "=== test_section5_splitrole_metadata_check ==="
SECTION="test_section5_splitrole_metadata_check"
if grep -qiE "splitRole" <<< "$SECTION5"; then
  pass "Section 5 references 'splitRole' metadata to detect a preplanning-already-split story"
else
  fail "Section 5 missing 'splitRole' guard — must check story metadata for splitRole: Foundation or Enhancement before processing agent proposals"
fi

# ---------------------------------------------------------------------------
# Test 3: Section 5 states the preplanning split is authoritative and
#   that agent proposals are skipped (not just deferred or noted) when
#   a splitRole marker is present.
# ---------------------------------------------------------------------------
echo ""
echo "=== test_section5_authoritative_skip ==="
SECTION="test_section5_authoritative_skip"
if grep -qiE "authoritative|skip.*agent|agent.*skip|skip.*proposal|proposal.*skip" <<< "$SECTION5"; then
  pass "Section 5 explicitly states that agent proposals are skipped when preplanning already split"
else
  fail "Section 5 does not state agent proposals are skipped when preplanning already split — expected 'authoritative' or explicit skip instruction"
fi

# ---------------------------------------------------------------------------
# Test 4: SKILL.md behavioral note references the Section 5 enforcement gate
# ---------------------------------------------------------------------------
echo ""
echo "=== test_skill_md_references_enforcement_gate ==="
SECTION="test_skill_md_references_enforcement_gate"
# Extract ~30 lines around the behavioral note at/near line 385
SKILL_WINDOW=$(python3 - "$SKILL_MD" <<'PYEOF'
import sys
lines = open(sys.argv[1]).readlines()
# Print lines 375-415 (0-indexed: 374-414)
start = max(0, 374)
end = min(len(lines), 415)
print("".join(lines[start:end]))
PYEOF
)
if grep -qiE "Section 5|dispatch.protocol|enforcement gate|splitRole guard|enforced" <<< "$SKILL_WINDOW"; then
  pass "SKILL.md around line 385 references the enforcement gate (Section 5 or splitRole guard in dispatch-protocol.md)"
else
  fail "SKILL.md around line 385 is a behavioral note only — does not reference the Section 5 enforcement gate in dispatch-protocol.md"
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
