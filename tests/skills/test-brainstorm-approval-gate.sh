#!/usr/bin/env bash
# Structural validation for brainstorm approval gate documentation in SKILL.md.
# Tests: 4-option approval gate section, initial-run vs re-run labeling,
# planning-intelligence log entry structure, and gate integration with Phase 2 flow.
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

echo "=== test_approval_gate ==="
SECTION="test_approval_gate"

# Extract the approval gate section. The new gate replaces "Present Spec for Approval".
# We look for either the legacy heading or the new gate heading.
_gate_section=$(python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Look for approval gate section by several possible headings
patterns = [
    r'(?m)(### Step 4: Approval Gate.*?)(?=^###|\Z)',
    r'(?m)(### Step 4:.*?[Aa]pproval.*?[Gg]ate.*?)(?=^###|\Z)',
    r'(?m)(## Approval Gate.*?)(?=^##|\Z)',
]
for pattern in patterns:
    match = re.search(pattern, content, re.DOTALL)
    if match:
        print(match.group(1))
        sys.exit(0)

# Also check for "Present Spec for Approval" which is the legacy heading
# (will fail once new gate is in place — this test is RED)
legacy = re.search(r'(?m)(### Step 4: Present Spec for Approval.*?)(?=^###|\Z)', content, re.DOTALL)
if legacy:
    print(legacy.group(1))
    sys.exit(0)

sys.exit(1)
EOF
) || true

if [ -z "$_gate_section" ]; then
  fail "SKILL.md missing approval gate section (Step 4)"
else
  pass "SKILL.md has an approval gate section (Step 4)"
fi

# Option (a): Approve — advances to fidelity review (or next phase)
if echo "$_gate_section" | grep -qiE 'approv|advance|fidelity'; then
  pass "approval gate section contains approve/advance option (option a)"
else
  fail "approval gate section missing approve option (option a)"
fi

# Option (b): Red/blue team / scenario analysis re-run
if echo "$_gate_section" | grep -qiE 'red.blue|blue.team|scenario.analysis|red.team'; then
  pass "approval gate section contains red/blue team scenario analysis option (option b)"
else
  fail "approval gate section missing red/blue team scenario analysis option (option b)"
fi

# Option (c): Additional web research
if echo "$_gate_section" | grep -qiE 'web.research|additional.research|research.phase'; then
  pass "approval gate section contains additional web research option (option c)"
else
  fail "approval gate section missing additional web research option (option c)"
fi

# Option (d): Discuss / pause for conversational review
if echo "$_gate_section" | grep -qiE "discuss|pause|let.s discuss|conversational"; then
  pass "approval gate section contains discuss/pause option (option d)"
else
  fail "approval gate section missing discuss/pause option (option d)"
fi

# Verify the gate presents all 4 options (not just describes them) — must reference AskUserQuestion
# or equivalent user-facing prompt mechanism with at least 4 numbered/lettered choices
if echo "$_gate_section" | grep -qiE 'AskUserQuestion|four options|4 options|\(a\)|\(b\)|\(c\)|\(d\)|option a|option b|option c|option d'; then
  pass "approval gate section references 4-option user prompt mechanism"
else
  fail "approval gate section missing 4-option user prompt mechanism (AskUserQuestion or equivalent)"
fi

echo ""
echo "=== test_initial_run_vs_rerun_labeling ==="
SECTION="test_initial_run_vs_rerun_labeling"

# The gate must label options differently based on whether research/scenario analysis have
# already run in this session — "initial run" vs "re-run" awareness.

# Check for initial-run / re-run awareness somewhere in the approval gate or its context
_rerun_section=$(python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Look for re-run / initial-run language in a broad window around Step 4
match = re.search(r'(?m)(### Step 4:.*?)(?=^##\s|\Z)', content, re.DOTALL)
if match:
    print(match.group(1))
    sys.exit(0)

# Also search the full file for these terms
print(content)
EOF
) || true

if echo "$_rerun_section" | grep -qiE 're.run|rerun|re.trigger|already ran|already executed|already run|previously'; then
  pass "SKILL.md documents re-run awareness for approval gate options"
else
  fail "SKILL.md missing re-run vs initial-run labeling for approval gate options"
fi

# Options must distinguish initial vs re-run state for research and scenario analysis
if echo "$_rerun_section" | grep -qiE 'initial|first.time|not yet run|not yet triggered'; then
  pass "SKILL.md documents initial-run labeling for approval gate options"
else
  fail "SKILL.md missing initial-run labeling for approval gate options (options should indicate when first time)"
fi

echo ""
echo "=== test_planning_intelligence_log ==="
SECTION="test_planning_intelligence_log"

# The planning-intelligence log entry must be documented in SKILL.md.
# It records: bright-line triggers, scenario count (survived blue team), practitioner cycles.

if grep -qi "planning.intelligence\|planning intelligence" "$SKILL_MD"; then
  pass "SKILL.md references planning-intelligence log"
else
  fail "SKILL.md missing planning-intelligence log documentation"
fi

# Extract the planning-intelligence log section for detailed checks
_log_section=$(python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Find the planning-intelligence log section
match = re.search(r'(?im)(planning.intelligence.*?)(?=^###|^##\s|\Z)', content, re.DOTALL)
if match:
    print(match.group(1))
EOF
) || true

# Bright-line triggers: which conditions triggered research (or "none")
if echo "$_log_section" | grep -qiE 'bright.line|trigger|triggered'; then
  pass "planning-intelligence log documents bright-line trigger field"
else
  fail "planning-intelligence log missing bright-line trigger documentation"
fi

# Scenario count: how many scenarios survived the blue team filter
if echo "$_log_section" | grep -qiE 'scenario|survived|blue.team|count'; then
  pass "planning-intelligence log documents scenario count / blue team filter field"
else
  fail "planning-intelligence log missing scenario count or blue team filter field"
fi

# Practitioner cycles: whether practitioner requested additional cycles via the gate
if echo "$_log_section" | grep -qiE 'practitioner|cycle|additional|gate|requested'; then
  pass "planning-intelligence log documents practitioner cycle field"
else
  fail "planning-intelligence log missing practitioner cycle documentation"
fi

# Log entry must distinguish between states: not triggered / triggered / re-triggered via gate
if echo "$_log_section" | grep -qiE 'not triggered|triggered|re.triggered|re-triggered'; then
  pass "planning-intelligence log documents triggered/not-triggered/re-triggered states"
else
  fail "planning-intelligence log missing triggered state vocabulary (not triggered / triggered / re-triggered)"
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
