#!/usr/bin/env bash
# Structural validation for follow-on epic scrutiny gate in brainstorm SKILL.md Phase 3 Step 0.
#
# Why source-grepping is used here (precedent and rationale):
#   SKILL.md is a non-executable instruction document — its text content IS the behavioral
#   contract for agents. The agent reads these instructions and acts on them; there is no
#   runnable code to invoke. Source-grepping SKILL.md is the established testing pattern for
#   agent instruction files in this codebase (see tests/skills/test-brainstorm-approval-gate.sh,
#   test-brainstorm-type-gate.sh, test-brainstorm-scenario-analysis.sh,
#   test-brainstorm-convert-to-epic.sh, test-brainstorm-enrich-in-place.sh,
#   test-brainstorm-web-research.sh, and test-epic-scrutiny-pipeline.sh — all follow this
#   same pattern). The test quality gate's bash-grep detector does not flag .md file grepping
#   because the contract lives in the document content.
#
# Tests (all RED against current SKILL.md lines 419-441 — no scrutiny invocation, depth cap,
# request_origin handling, follow_on_depth variable, or stub presentation format exist yet):
#   - test_followon_gate_invokes_scrutiny_pipeline
#   - test_followon_gate_depth_cap
#   - test_followon_gate_request_origin_part_a_skip
#   - test_followon_gate_exposes_depth_variable
#   - test_followon_gate_stub_presentation
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# Extract the Phase 3 Step 0 section from SKILL.md using python3 (BSD sed compat).
# Returns content from the Step 0 heading through to the next ### or ## heading.
_extract_step0() {
  python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Match from the Step 0 heading through to the next heading of same or higher level
match = re.search(
    r'(?m)(### Step 0: Follow-on and Derivative Epic Gate.*?)(?=^###|^##\s|\Z)',
    content,
    re.DOTALL
)
if match:
    print(match.group(1))
EOF
}

_step0_section=$(_extract_step0) || true

# ---------------------------------------------------------------------------
# Test 1: Step 0 invokes the shared scrutiny pipeline for each follow-on epic
# ---------------------------------------------------------------------------
test_followon_gate_invokes_scrutiny_pipeline() {
  echo ""
  echo "=== test_followon_gate_invokes_scrutiny_pipeline ==="

  # The follow-on gate must instruct the agent to invoke (run/execute/invoke) the shared
  # epic scrutiny pipeline for each newly-approved follow-on epic before creating it.
  # This ensures follow-on epics receive the same quality checks as primary epics.

  if grep -qiE 'scrutiny.pipeline|epic-scrutiny-pipeline|invoke.*scrutin|run.*scrutin|scrutin.*pipeline' <<< "$_step0_section"; then
    pass "Step 0 references invoking the epic scrutiny pipeline for follow-on epics"
  else
    fail "Step 0 missing reference to scrutiny pipeline invocation for follow-on epics"
  fi

  # The pipeline invocation instruction must appear in the Step 0 procedure context
  # (not just a general mention elsewhere). It must co-locate with the procedure steps.
  local _procedure_section
  _procedure_section=$(python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

# Find the Step 0 procedure block
match = re.search(
    r'(?m)(Procedure for each follow-on epic.*?)(?=^###|^##\s|\Z)',
    content,
    re.DOTALL
)
if match:
    print(match.group(1))
EOF
) || true

  if grep -qiE 'scrutin|epic-scrutiny' <<< "$_procedure_section"; then
    pass "Scrutiny pipeline invocation appears within the Step 0 procedure block"
  else
    fail "Scrutiny pipeline invocation missing from Step 0 procedure block (co-location required)"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: Step 0 contains depth cap logic (follow_on_depth >= 1 triggers stub)
# ---------------------------------------------------------------------------
test_followon_gate_depth_cap() {
  echo ""
  echo "=== test_followon_gate_depth_cap ==="

  # Follow-on epics generated from within a follow-on brainstorm session (depth >= 1)
  # must be capped as stubs rather than recursively running the full scrutiny pipeline.
  # This prevents unbounded recursive expansion.

  if grep -qiE 'depth.cap|depth.*cap|cap.*depth|follow_on_depth\s*>=?\s*1|depth.*>=?\s*1|>=?\s*1.*depth' <<< "$_step0_section"; then
    pass "Step 0 contains depth cap condition (depth >= 1 triggers stub)"
  else
    fail "Step 0 missing depth cap logic (follow_on_depth >= 1 must trigger stub path)"
  fi

  # The depth cap must result in a stub/stub-only path (not full scrutiny for depth >= 1)
  if grep -qiE 'stub|shallow|cap.*stub|stub.*depth|depth.*stub' <<< "$_step0_section"; then
    pass "Step 0 references stub path as the depth cap result"
  else
    fail "Step 0 missing stub path for depth-capped follow-on epics"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: Step 0 handles request_origin Part A content pre-strip
# ---------------------------------------------------------------------------
test_followon_gate_request_origin_part_a_skip() {
  echo ""
  echo "=== test_followon_gate_request_origin_part_a_skip ==="

  # When a follow-on epic was identified via a scope-split (Part A / Part B pattern),
  # the gate must strip or skip Part A content before seeding the follow-on spec.
  # This prevents the primary epic's content from bleeding into the follow-on scope.

  if grep -qiE 'request_origin|origin.*part.?a|part.?a.*origin' <<< "$_step0_section"; then
    pass "Step 0 references request_origin or Part A origin handling"
  else
    fail "Step 0 missing request_origin named variable or Part A origin handling"
  fi

  # The Part A stripping must be explicitly associated with seeding the follow-on spec
  if grep -qiE 'strip|exclude|skip.*part.?a|part.?a.*skip|pre.strip|remove.*part.?a' <<< "$_step0_section"; then
    pass "Step 0 specifies stripping Part A content before seeding follow-on spec"
  else
    fail "Step 0 missing instruction to strip/exclude Part A content when seeding follow-on spec"
  fi
}

# ---------------------------------------------------------------------------
# Test 4: Step 0 exposes follow_on_depth as a named state variable
# ---------------------------------------------------------------------------
test_followon_gate_exposes_depth_variable() {
  echo ""
  echo "=== test_followon_gate_exposes_depth_variable ==="

  # The gate must expose a named variable `follow_on_depth` (or equivalent) that
  # tracks the current recursion depth for follow-on epic generation. This variable
  # is consumed by the depth cap check (Test 2) and must be named explicitly so
  # orchestrators and sub-agents can inspect/set it.

  if grep -qiE 'follow_on_depth|followon_depth|follow.on.depth' <<< "$_step0_section"; then
    pass "Step 0 exposes 'follow_on_depth' as a named state variable"
  else
    fail "Step 0 missing 'follow_on_depth' named state variable"
  fi

  # The variable must be defined or initialized (not just referenced in a condition)
  if grep -qiE 'follow_on_depth\s*=|set.*follow_on_depth|initialize.*follow_on_depth|follow_on_depth.*default|default.*follow_on_depth' <<< "$_step0_section"; then
    pass "Step 0 defines/initializes follow_on_depth variable"
  else
    fail "Step 0 references follow_on_depth but does not define or initialize it"
  fi
}

# ---------------------------------------------------------------------------
# Test 5: Step 0 documents stub presentation format for depth >= 1 follow-ons
# ---------------------------------------------------------------------------
test_followon_gate_stub_presentation() {
  echo ""
  echo "=== test_followon_gate_stub_presentation ==="

  # When follow_on_depth >= 1, follow-on epics must be presented as stubs with a
  # defined presentation format — not silently dropped or processed through full scrutiny.
  # The format must show the title and a brief context note explaining why it is a stub.

  if grep -qiE 'stub.*present|present.*stub|stub.*format|format.*stub|stub.*title|title.*stub' <<< "$_step0_section"; then
    pass "Step 0 documents stub presentation format for depth-capped follow-on epics"
  else
    fail "Step 0 missing stub presentation format documentation for depth >= 1 follow-on epics"
  fi

  # The stub must include a title field co-located with depth cap/stub instructions
  # (not from the general follow-on approval template which also has [Title])
  local _depth_stub_region
  _depth_stub_region=$(python3 - "$SKILL_MD" <<'EOF'
import sys, re

with open(sys.argv[1], 'r') as f:
    content = f.read()

match = re.search(
    r'(?m)(### Step 0: Follow-on and Derivative Epic Gate.*?)(?=^###|^##\s|\Z)',
    content,
    re.DOTALL
)
if not match:
    sys.exit(0)
section = match.group(1)

# Find text within 300 chars of "stub" keyword
stub_match = re.search(r'stub', section, re.IGNORECASE)
if stub_match:
    start = max(0, stub_match.start() - 150)
    end = min(len(section), stub_match.end() + 150)
    print(section[start:end])
EOF
) || true

  if grep -qiE '\[Title\]|\[title\]|title.*stub|stub.*title' <<< "$_depth_stub_region"; then
    pass "Stub presentation format includes title field in depth-cap context"
  else
    fail "Stub presentation format missing title field in depth-cap context"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_followon_gate_invokes_scrutiny_pipeline
test_followon_gate_depth_cap
test_followon_gate_request_origin_part_a_skip
test_followon_gate_exposes_depth_variable
test_followon_gate_stub_presentation

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
