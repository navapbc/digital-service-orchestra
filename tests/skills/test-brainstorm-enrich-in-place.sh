#!/usr/bin/env bash
# Structural validation for brainstorm enrich-in-place path documentation in SKILL.md.
# Tests: enrich-in-place section existence, ticket edit --description instruction,
# explicit phase skip logic, and ticket type preservation.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_DIR="${REPO_ROOT}/plugins/dso/skills/brainstorm"
SKILL_MD="$SKILL_DIR/SKILL.md"

PASS=0
FAIL=0
SECTION="unknown"

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
# fail() prints a machine-readable "FAIL: section_name" line (required by parse_failing_tests_from_output
# in red-zone.sh, which uses pattern '^FAIL: [a-zA-Z_][a-zA-Z0-9_-]*') followed by the human-readable
# message. The section name is set by each "=== section_name ===" block below.
fail() { echo "FAIL: ${SECTION}"; echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Extract a section from SKILL.md bounded by a heading and the next same-or-higher-level heading.
# Uses python3 for BSD sed compatibility (macOS sed lacks -z / multiline).
# Usage: extract_section "## Heading Text"
# Returns: the content between that heading and the next heading at the same level.
extract_section() {
  local heading="$1"
  python3 - "$SKILL_MD" "$heading" <<'EOF'
import sys, re

filepath = sys.argv[1]
heading = sys.argv[2]

with open(filepath, 'r') as f:
    content = f.read()

# Determine heading level (number of leading #)
level = len(heading) - len(heading.lstrip('#'))
prefix = '#' * level

# Escape heading for regex
escaped = re.escape(heading.lstrip('# ').strip())

# Match from heading to next heading of same or higher level
pattern = rf'(?m)^{re.escape(prefix)}\s+{escaped}.*?(?=^#{"{1," + str(level) + "}"}[^#]|\Z)'
match = re.search(pattern, content, re.DOTALL)
if match:
    print(match.group(0))
EOF
}

# Extract the enrich-in-place section using dedicated heading detection only.
# The section MUST exist as a proper markdown heading (##, ###, or ####) — a bold
# label like **Option (b) — Enrich in-place:** does not constitute a dedicated section.
_extract_enrich_section() {
  python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Look ONLY for a dedicated Enrich-in-Place section with a proper markdown heading.
# Bold labels (**Option (b) — ...**) are intentionally excluded — they are inline
# option labels, not dedicated path specifications with complete Socratic dialogue steps.
patterns = [
    r'(?im)(^#{2,4}\s+Enrich.in.Place\s+Path.*?)(?=^#{1,4}\s|\Z)',
    r'(?im)(^#{2,4}\s+Enrich.in.Place.*?)(?=^#{1,4}\s|\Z)',
    r'(?im)(^#{2,4}\s+Option\s+\(b\).*?Enrich.*?)(?=^#{1,4}\s|\Z)',
]
for pattern in patterns:
    match = re.search(pattern, content, re.DOTALL)
    if match:
        print(match.group(1))
        sys.exit(0)

# No dedicated section found — exit non-zero so the caller gets an empty string
sys.exit(1)
EOF
}

echo "=== test_enrich_section_exists ==="
SECTION="test_enrich_section_exists"

# The SKILL.md must have a dedicated Enrich-in-Place Path section (not just an inline option bullet).
# A dedicated section signals that the path is fully specified with Socratic dialogue instructions.
_enrich_section=$(_extract_enrich_section) || true

if [ -z "$_enrich_section" ]; then
  fail "SKILL.md missing a dedicated Enrich-in-Place Path section (requires a markdown heading, not just a bold label)"
else
  # Confirm the section contains Socratic dialogue instructions (not just a heading label)
  if echo "$_enrich_section" | grep -qiE 'socratic|one question at a time|targeted question|dialogue'; then
    pass "SKILL.md has a dedicated Enrich-in-Place Path section with Socratic dialogue instructions"
  else
    fail "SKILL.md dedicated enrich-in-place section exists but lacks Socratic dialogue instructions"
  fi
fi

echo ""
echo "=== test_enrich_updates_ticket_description ==="
SECTION="test_enrich_updates_ticket_description"

# The enrich-in-place path must instruct updating the ticket description via
# 'ticket edit --description' (not just posting a comment via 'ticket comment').
# The updated description must include structured acceptance criteria, approach summary,
# and file paths.

if [ -z "$_enrich_section" ]; then
  fail "Cannot test: enrich-in-place section not found in SKILL.md"
else
  if echo "$_enrich_section" | grep -qE 'ticket edit.*--description|ticket.*edit.*--description'; then
    pass "enrich-in-place section uses 'ticket edit --description' to update ticket"
  else
    fail "enrich-in-place section does not use 'ticket edit --description' (found 'ticket comment' or nothing)"
  fi

  # Must instruct including structured acceptance criteria
  if echo "$_enrich_section" | grep -qiE 'acceptance criteria|success criteria'; then
    pass "enrich-in-place section instructs including acceptance criteria in updated description"
  else
    fail "enrich-in-place section missing acceptance criteria instruction in ticket description update"
  fi

  # Must instruct including approach summary
  if echo "$_enrich_section" | grep -qiE 'approach summary|approach'; then
    pass "enrich-in-place section instructs including approach summary in updated description"
  else
    fail "enrich-in-place section missing approach summary instruction in ticket description update"
  fi

  # Must instruct including file paths
  if echo "$_enrich_section" | grep -qiE 'file path|relevant file|files'; then
    pass "enrich-in-place section instructs including file paths in updated description"
  else
    fail "enrich-in-place section missing file paths instruction in ticket description update"
  fi
fi

echo ""
echo "=== test_enrich_skips_epic_phases ==="
SECTION="test_enrich_skips_epic_phases"

# The enrich-in-place section must explicitly skip all 5 named phases/steps:
# fidelity review, scenario analysis, ticket creation, complexity evaluation, routing to downstream skills.

if [ -z "$_enrich_section" ]; then
  fail "Cannot test: enrich-in-place section not found in SKILL.md"
else
  if echo "$_enrich_section" | grep -qiE 'skip.*fidelity|fidelity.*skip|no fidelity|omit.*fidelity'; then
    pass "enrich-in-place section explicitly skips fidelity review"
  else
    fail "enrich-in-place section missing explicit skip of fidelity review"
  fi

  if echo "$_enrich_section" | grep -qiE 'skip.*scenario|scenario.*skip|no scenario|omit.*scenario'; then
    pass "enrich-in-place section explicitly skips scenario analysis"
  else
    fail "enrich-in-place section missing explicit skip of scenario analysis"
  fi

  if echo "$_enrich_section" | grep -qiE 'skip.*ticket creation|ticket creation.*skip|no.*ticket creation|Phase 3.*skip|skip.*Phase 3'; then
    pass "enrich-in-place section explicitly skips ticket creation"
  else
    fail "enrich-in-place section missing explicit skip of ticket creation"
  fi

  if echo "$_enrich_section" | grep -qiE 'skip.*complexity|complexity.*skip|no complexity|omit.*complexity'; then
    pass "enrich-in-place section explicitly skips complexity evaluation"
  else
    fail "enrich-in-place section missing explicit skip of complexity evaluation"
  fi

  if echo "$_enrich_section" | grep -qiE 'skip.*downstream|downstream.*skip|no.*routing|do not.*route|omit.*preplanning|skip.*preplanning'; then
    pass "enrich-in-place section explicitly skips routing to downstream skills"
  else
    fail "enrich-in-place section missing explicit skip of routing to downstream skills"
  fi
fi

echo ""
echo "=== test_enrich_preserves_ticket_type ==="
SECTION="test_enrich_preserves_ticket_type"

# The enrich-in-place section must document that the ticket type is NOT changed.
# It must NOT instruct converting the ticket type or closing/recreating the ticket.

if [ -z "$_enrich_section" ]; then
  fail "Cannot test: enrich-in-place section not found in SKILL.md"
else
  if echo "$_enrich_section" | grep -qiE 'preserve.*type|type.*unchanged|do not.*convert|not.*convert|keep.*type|retain.*type|ticket type.*preserved|original.*type'; then
    pass "enrich-in-place section documents that ticket type is preserved"
  else
    fail "enrich-in-place section missing explicit statement that ticket type is not changed"
  fi

  # Confirm the section does NOT instruct closing the original ticket (that's Option a behavior)
  if echo "$_enrich_section" | grep -qiE 'ticket transition.*closed|close the original|transition.*closed'; then
    fail "enrich-in-place section incorrectly instructs closing the original ticket (that is Option a behavior)"
  else
    pass "enrich-in-place section does not instruct closing/converting the original ticket"
  fi
fi

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
