#!/usr/bin/env bash
# shellcheck disable=SC2329
# Structural validation for the Convert-to-Epic Path section in brainstorm SKILL.md.
# Tests: dedicated section existence, close-after-create ordering, original ticket
# traceability, edge case coverage (--reason flag, open children), and Type Detection
# Gate Option (a) delegating to the section rather than containing inline close commands.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"
# After phase extraction, Convert-to-Epic Path content lives in phases/convert-to-epic.md.
# Rebind SKILL_MD to the aggregated corpus; keep $_orig_SKILL_MD for SKILL.md-specific checks.
_orig_SKILL_MD="$SKILL_MD"
source "${REPO_ROOT}/tests/skills/lib/brainstorm-skill-aggregate.sh"
SKILL_MD=$(brainstorm_aggregate_path)
trap brainstorm_aggregate_cleanup EXIT

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

echo "=== test_convert_section_exists ==="
SECTION="test_convert_section_exists"

# A dedicated "Convert-to-Epic Path" section must exist in SKILL.md as a named heading.
# This is separate from the inline Option (a) steps inside the Type Detection Gate.
_convert_section=$(python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Look for a dedicated Convert-to-Epic Path section by heading
patterns = [
    r'(?m)(^#+\s+Convert.to.Epic\s+Path.*?)(?=^# [A-Z]|\Z)',
    r'(?m)(^#+\s+Convert.*Epic.*Path.*?)(?=^# [A-Z]|\Z)',
    r'(?m)(^#+\s+Convert-to-Epic.*?)(?=^# [A-Z]|\Z)',
]
for pattern in patterns:
    match = re.search(pattern, content, re.DOTALL | re.IGNORECASE)
    if match:
        print(match.group(1))
        sys.exit(0)

sys.exit(1)
EOF
) || true

if [ -z "$_convert_section" ]; then
  fail "SKILL.md missing a dedicated 'Convert-to-Epic Path' section heading"
else
  pass "SKILL.md has a dedicated Convert-to-Epic Path section"
fi

echo ""
echo "=== test_convert_closes_original_after_epic_created ==="
SECTION="test_convert_closes_original_after_epic_created"

# The Convert-to-Epic Path section must instruct closing the original ticket ONLY
# after the new epic has been successfully created. The line number of the close step
# must be greater than the line number of the create/Phase 1 step.
_ordering_result=$(python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    lines = f.readlines()

content = ''.join(lines)

# Find the Convert-to-Epic Path section boundaries
section_patterns = [
    r'(?m)^#+\s+Convert.to.Epic\s+Path',
    r'(?m)^#+\s+Convert.*Epic.*Path',
    r'(?m)^#+\s+Convert-to-Epic',
]
section_start = None
for pat in section_patterns:
    m = re.search(pat, content, re.IGNORECASE)
    if m:
        section_start = m.start()
        break

if section_start is None:
    print("section_not_found")
    sys.exit(0)

# Extract text from the section start to the next heading of same or higher level
section_match = re.search(r'(?m)^(#+)\s+Convert.{0,30}Epic.{0,30}Path.*?(?=^# [A-Z]|\Z)',
                           content[section_start:], re.DOTALL | re.IGNORECASE)
if not section_match:
    print("section_not_found")
    sys.exit(0)

section_text = section_match.group(0)
section_line_offset = content[:section_start].count('\n')

# Within the section, find the line that creates/starts the epic (create or Phase 1 reference)
create_line = None
close_line = None
for i, line in enumerate(section_text.splitlines()):
    line_num = section_line_offset + i
    if create_line is None and re.search(r'(create.*epic|new epic|Phase 1|epic.*creat)', line, re.IGNORECASE):
        create_line = line_num
    # The close/transition step for the original ticket
    if re.search(r'(ticket transition|close.*original|original.*clos)', line, re.IGNORECASE):
        close_line = line_num

if create_line is None:
    print("create_step_not_found")
elif close_line is None:
    print("close_step_not_found")
elif close_line > create_line:
    print("correct_order")
else:
    print("wrong_order")
EOF
) || true

case "$_ordering_result" in
  "correct_order")
    pass "Convert-to-Epic Path closes original ticket AFTER creating the new epic (correct order)"
    ;;
  "wrong_order")
    fail "Convert-to-Epic Path closes original ticket BEFORE creating the new epic — order must be: create first, then close"
    ;;
  "section_not_found")
    fail "Convert-to-Epic Path section not found — cannot verify close-after-create ordering"
    ;;
  "create_step_not_found")
    fail "Convert-to-Epic Path section missing a step that creates the new epic or references Phase 1"
    ;;
  "close_step_not_found")
    fail "Convert-to-Epic Path section missing a step that closes the original ticket (ticket transition)"
    ;;
  *)
    fail "Unexpected ordering check result: $_ordering_result"
    ;;
esac

echo ""
echo "=== test_convert_references_original_ticket ==="
SECTION="test_convert_references_original_ticket"

# The Convert-to-Epic Path section must instruct including the original ticket ID
# in the new epic description to maintain traceability.

if [ -z "$_convert_section" ]; then
  fail "Convert-to-Epic Path section not found — cannot verify original ticket ID traceability"
else
  # Section must mention original ticket ID inclusion in the epic description
  if grep -qiE 'original.*ticket.*id|ticket.*id.*original|original.*id.*description|description.*original.*id|traceab|superseded.by|converted.from' <<< "$_convert_section"; then
    pass "Convert-to-Epic Path section instructs including original ticket ID for traceability"
  else
    fail "Convert-to-Epic Path section missing instruction to include original ticket ID in the new epic description for traceability"
  fi
fi

echo ""
echo "=== test_convert_handles_edge_cases ==="
SECTION="test_convert_handles_edge_cases"

# The Convert-to-Epic Path section must address:
# (1) the bug ticket --reason flag requirement when closing the original ticket
# (2) tickets with open children that cannot be closed cleanly

if [ -z "$_convert_section" ]; then
  fail "Convert-to-Epic Path section not found — cannot verify edge case coverage"
else
  # Edge case 1: --reason flag requirement for closing tickets (especially bug tickets)
  if grep -qiE '\-\-reason|reason flag|reason=' <<< "$_convert_section"; then
    pass "Convert-to-Epic Path section documents --reason flag requirement when closing original ticket"
  else
    fail "Convert-to-Epic Path section missing --reason flag requirement for closing original ticket"
  fi

  # Edge case 2: open children handling
  if grep -qiE 'open child|child ticket|children|open sub' <<< "$_convert_section"; then
    pass "Convert-to-Epic Path section addresses tickets with open children"
  else
    fail "Convert-to-Epic Path section missing guidance for tickets with open children"
  fi
fi

echo ""
echo "=== test_convert_gate_delegates_not_inline ==="
SECTION="test_convert_gate_delegates_not_inline"

# The Type Detection Gate's Option (a) must DELEGATE to the Convert-to-Epic Path section
# rather than containing its own inline close command. The gate's Option (a) block must NOT
# contain a 'ticket transition' command directly.

_gate_option_a=$(python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Find the Type Detection Gate section
gate_match = re.search(
    r'(?m)^##\s+Type Detection Gate.*?(?=^##\s|\Z)',
    content, re.DOTALL | re.IGNORECASE
)
if not gate_match:
    print("gate_not_found")
    sys.exit(0)

gate_text = gate_match.group(0)

# Within the gate, find the Option (a) block — from "(a)" or "Option (a)" to the next
# option marker "(b)" or "Option (b)" or end of gate.
option_a_match = re.search(
    r'(?m)\*\*Option \(a\).*?(?=\*\*Option \(b\)|\Z)',
    gate_text, re.DOTALL | re.IGNORECASE
)
if not option_a_match:
    # Try looser pattern
    option_a_match = re.search(
        r'(?m)\(a\).*?(?=\(b\)|\Z)',
        gate_text, re.DOTALL | re.IGNORECASE
    )

if option_a_match:
    print(option_a_match.group(0))
else:
    print("option_a_not_found")
EOF
) || true

if [ "$_gate_option_a" = "gate_not_found" ]; then
  fail "Type Detection Gate section not found in SKILL.md"
elif [ "$_gate_option_a" = "option_a_not_found" ]; then
  fail "Type Detection Gate Option (a) block not found"
else
  # Option (a) must NOT contain an inline 'ticket transition' command
  if grep -q 'ticket transition' <<< "$_gate_option_a"; then
    fail "Type Detection Gate Option (a) contains an inline 'ticket transition' command — it must delegate to the Convert-to-Epic Path section instead"
  else
    pass "Type Detection Gate Option (a) does not contain inline 'ticket transition' — correctly delegates to Convert-to-Epic Path section"
  fi

  # Option (a) should reference the Convert-to-Epic Path section
  if grep -qiE 'convert.to.epic path|see.*convert|convert.*path|follow.*convert' <<< "$_gate_option_a"; then
    pass "Type Detection Gate Option (a) references the Convert-to-Epic Path section"
  else
    fail "Type Detection Gate Option (a) missing reference to the Convert-to-Epic Path section"
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
