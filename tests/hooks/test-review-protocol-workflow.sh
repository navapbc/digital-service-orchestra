#!/usr/bin/env bash
# tests/hooks/test-review-protocol-workflow.sh
# Verifies that REVIEW-PROTOCOL-WORKFLOW.md exists and contains key structural elements.

set -uo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
WORKFLOW_FILE="${REPO_ROOT}/plugins/dso/docs/workflows/REVIEW-PROTOCOL-WORKFLOW.md"

pass=0
fail=0

assert() {
  local description="$1"
  local result="$2"
  if [ "$result" = "0" ]; then
    echo "PASS: $description"
    pass=$((pass + 1))
  else
    echo "FAIL: $description"
    fail=$((fail + 1))
  fi
}

run_check() {
  local description="$1"
  shift
  if "$@" 2>/dev/null; then
    assert "$description" 0
  else
    assert "$description" 1
  fi
}

# Test 1: File exists
run_check "REVIEW-PROTOCOL-WORKFLOW.md exists" test -f "$WORKFLOW_FILE"

# Test 2: Contains Stage 1 section
run_check "Contains Stage 1 section" grep -q "## Stage 1" "$WORKFLOW_FILE"

# Test 3: Contains Stage 2 section
run_check "Contains Stage 2 section" grep -q "## Stage 2" "$WORKFLOW_FILE"

# Test 4: Contains Stage 3 section
run_check "Contains Stage 3 section" grep -q "## Stage 3" "$WORKFLOW_FILE"

# Test 5: Contains at least 3 Stage sections
if [ -f "$WORKFLOW_FILE" ]; then
  stage_count=$(grep -c "## Stage" "$WORKFLOW_FILE" 2>/dev/null || echo 0)
  if [ "$stage_count" -ge 3 ]; then
    assert "Contains at least 3 Stage sections (found: $stage_count)" 0
  else
    assert "Contains at least 3 Stage sections (found: $stage_count)" 1
  fi
else
  assert "Contains at least 3 Stage sections (file missing)" 1
fi

# Test 6: Contains pass_threshold reference
run_check "Contains pass_threshold reference" grep -q "pass_threshold" "$WORKFLOW_FILE"

# Test 7: Contains conflict detection
run_check "Contains conflict detection" grep -q "conflict" "$WORKFLOW_FILE"

# Test 8: Contains revision cycle logic
run_check "Contains revision cycle logic" grep -q "revision" "$WORKFLOW_FILE"

# Test 9: Contains Parameters section
run_check "Contains Parameters section" grep -q "## Parameters" "$WORKFLOW_FILE"

# Test 10: Contains Revision Protocol section
run_check "Contains Revision Protocol section" grep -q "## Revision Protocol" "$WORKFLOW_FILE"

echo ""
echo "Results: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
