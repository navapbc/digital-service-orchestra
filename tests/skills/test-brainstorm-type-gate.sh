#!/usr/bin/env bash
# Structural validation for brainstorm type detection gate documentation in SKILL.md.
# Tests: type detection gate section presence, non-epic convert/enrich options,
# epic flow routing to Phase 1, and usage section showing non-epic invocation.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"

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

echo "=== test_type_gate_section_exists ==="
SECTION="test_type_gate_section_exists"

# The type detection gate must exist as a named section in SKILL.md and must
# reference checking the ticket type via `dso ticket show` before Phase 1.
_type_gate_section=$(python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Look for a type detection gate SECTION by heading (anchored to `##+` prefix)
# — the layout table references the phrase too, which we must not match.
patterns = [
    r'(?m)(^##+\s+Type\s+Detection\s+Gate.*?)(?=^## [A-Z]|\Z)',
    r'(?m)(^##+\s+Ticket\s+Type.*?gate.*?)(?=^## [A-Z]|\Z)',
    r'(?m)(^##+\s+Type\s+Check.*?gate.*?)(?=^## [A-Z]|\Z)',
]
for pattern in patterns:
    match = re.search(pattern, content, re.DOTALL | re.IGNORECASE)
    if match:
        print(match.group(1))
        sys.exit(0)

sys.exit(1)
EOF
) || true

if [ -z "$_type_gate_section" ]; then
  fail "SKILL.md missing type detection gate section"
else
  pass "SKILL.md has a type detection gate section"
fi

# The gate must reference dso ticket show to detect the ticket type
if grep -qiE 'ticket show|dso ticket show' <<< "$_type_gate_section"; then
  pass "type detection gate references 'dso ticket show' for type detection"
else
  fail "type detection gate missing reference to 'dso ticket show' for type detection"
fi

# The gate must be placed before Phase 1 (early in the skill flow)
_gate_position=$(python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Find position of type gate and Phase 1
gate_patterns = [
    r'type.detection.gate',
    r'ticket.type.*gate',
    r'type.check.*gate',
    r'TYPE.DETECTION.GATE',
]
phase1_pattern = r'^## Phase 1'  # Match the section heading, not forward-references

gate_pos = None
for pat in gate_patterns:
    m = re.search(pat, content, re.IGNORECASE)
    if m:
        gate_pos = m.start()
        break

phase1_match = re.search(phase1_pattern, content, re.MULTILINE)
phase1_pos = phase1_match.start() if phase1_match else None

if gate_pos is not None and phase1_pos is not None and gate_pos < phase1_pos:
    print("gate_before_phase1")
elif gate_pos is None:
    print("gate_not_found")
else:
    print("gate_after_phase1")
EOF
) || true

if [ "$_gate_position" = "gate_before_phase1" ]; then
  pass "type detection gate appears before Phase 1 in SKILL.md"
elif [ "$_gate_position" = "gate_not_found" ]; then
  fail "type detection gate not found in SKILL.md (cannot verify position)"
else
  fail "type detection gate appears after Phase 1 — must be a pre-Phase-1 check"
fi

echo ""
echo "=== test_non_epic_presents_convert_enrich_options ==="
SECTION="test_non_epic_presents_convert_enrich_options"

# For non-epic ticket types (story, task, bug), the gate must present two options:
# (1) convert to epic, (2) enrich in-place.

_full_content=$(python3 - "$SKILL_MD" <<'EOF'
import sys
with open(sys.argv[1], 'r') as f:
    print(f.read())
EOF
) || true

# Must mention non-epic ticket types by name (story, task, bug)
if grep -qiE 'story|task|bug' <<< "$_full_content"; then
  pass "SKILL.md references non-epic ticket types (story/task/bug) in type gate context"
else
  fail "SKILL.md missing reference to non-epic ticket types (story, task, bug) in type gate"
fi

# Must offer "convert to epic" option
if grep -qiE 'convert.to.epic|convert.*epic' <<< "$_full_content"; then
  pass "SKILL.md presents 'convert to epic' option for non-epic types"
else
  fail "SKILL.md missing 'convert to epic' option for non-epic ticket types"
fi

# Must offer "enrich in-place" option
if grep -qiE 'enrich.in.place|enrich.*in.place' <<< "$_full_content"; then
  pass "SKILL.md presents 'enrich in-place' option for non-epic types"
else
  fail "SKILL.md missing 'enrich in-place' option for non-epic ticket types"
fi

# Both options must appear together (in the same gate context, not scattered)
_both_options=$(python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Find a window that contains both options within 500 chars of each other
convert_match = re.search(r'convert.{0,10}epic', content, re.IGNORECASE)
enrich_match  = re.search(r'enrich.{0,10}in.place', content, re.IGNORECASE)

if convert_match and enrich_match:
    distance = abs(convert_match.start() - enrich_match.start())
    if distance < 600:
        print("close")
    else:
        print("far")
else:
    print("missing")
EOF
) || true

if [ "$_both_options" = "close" ]; then
  pass "convert-to-epic and enrich-in-place options appear together in the gate section"
else
  fail "convert-to-epic and enrich-in-place options not co-located in the gate section (distance > 600 chars or missing)"
fi

echo ""
echo "=== test_epic_flow_preserved ==="
SECTION="test_epic_flow_preserved"

# The type gate must route epic tickets through to Phase 1 unchanged —
# the gate should not alter the existing dialogue or output for epic-type tickets.

# Gate must distinguish epic vs non-epic explicitly
if grep -qiE 'type.*epic|epic.*type|is.*epic|epic.*ticket' <<< "$_full_content"; then
  pass "SKILL.md type gate explicitly identifies epic ticket type"
else
  fail "SKILL.md type gate missing explicit epic-type identification"
fi

# Gate must route epics to Phase 1 (not a different path)
_epic_routing=$(python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Find context around "epic" near "Phase 1" within 400 chars
matches = list(re.finditer(r'epic', content, re.IGNORECASE))
phase1_matches = list(re.finditer(r'Phase 1', content))

for m in matches:
    for p in phase1_matches:
        if abs(m.start() - p.start()) < 400:
            # Extract the window around this co-occurrence
            start = max(0, min(m.start(), p.start()) - 50)
            end   = min(len(content), max(m.end(), p.end()) + 50)
            print(content[start:end])
            sys.exit(0)

sys.exit(1)
EOF
) || true

if [ -n "$_epic_routing" ]; then
  pass "SKILL.md links epic type to Phase 1 routing"
else
  fail "SKILL.md missing co-location of epic type routing and Phase 1"
fi

# The gate documentation must assert that existing Phase 1 behavior is unchanged
if grep -qiE 'unchanged|unmodified|proceed.*phase.1|continue.*phase.1|route.*phase.1|proceed to phase 1|continue to phase 1' <<< "$_full_content"; then
  pass "SKILL.md documents that epic flow proceeds to Phase 1 unchanged"
else
  fail "SKILL.md missing assertion that epic flow routes to Phase 1 unchanged"
fi

echo ""
echo "=== test_usage_section_shows_non_epic ==="
SECTION="test_usage_section_shows_non_epic"

# The Usage section must show invocation for non-epic ticket types (story, task, bug, or
# generic "any ticket type"), not just epic-id invocation.

_usage_section=$(extract_section "## Usage") || true

if [ -z "$_usage_section" ]; then
  fail "SKILL.md missing Usage section"
else
  pass "SKILL.md has a Usage section"
fi

# Usage section must reference non-epic types or generic ticket-id invocation
if grep -qiE 'story|task|bug|non.epic|any ticket|ticket.id|ticket-id' <<< "$_usage_section"; then
  pass "Usage section shows invocation for non-epic ticket types"
else
  fail "Usage section only shows epic-id invocation — missing non-epic ticket type examples"
fi

# Usage section must have an example command for a non-epic invocation
if grep -qiE 'story[-_]?id|task[-_]?id|bug[-_]?id|<ticket-id>|<story|<task|<bug' <<< "$_usage_section"; then
  pass "Usage section includes a concrete non-epic invocation example"
else
  fail "Usage section missing concrete non-epic invocation example (e.g., <story-id>, <task-id>, <bug-id>)"
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
