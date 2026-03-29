#!/usr/bin/env bash
# test-sprint-skill-doc-writer-dispatch.sh
# Verifies that sprint SKILL.md contains doc-writer dispatch logic for documentation update stories.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"

pass=0
fail=0

run_test() {
  local name="$1"
  local result="$2"
  if [[ "$result" == "pass" ]]; then
    echo "PASS: $name"
    pass=$((pass + 1))
  else
    echo "FAIL: $name"
    fail=$((fail + 1))
  fi
}

# Test 1: Sprint SKILL.md contains dso:doc-writer reference
if grep -q 'dso:doc-writer' "$SKILL_FILE"; then
  run_test "Sprint SKILL.md references dso:doc-writer" "pass"
else
  run_test "Sprint SKILL.md references dso:doc-writer" "fail"
fi

# Test 2: Sprint SKILL.md contains the doc update story title pattern
if grep -q 'Update project docs to reflect' "$SKILL_FILE"; then
  run_test "Sprint SKILL.md contains 'Update project docs to reflect' pattern" "pass"
else
  run_test "Sprint SKILL.md contains 'Update project docs to reflect' pattern" "fail"
fi

# Test 3: Doc-writer dispatch section appears in Sub-Agent Launch phase (Phase 4)
# Sub-Agent Launch is Phase 4 — verify the dso:doc-writer reference appears after it
launch_phase_line=$(grep -n '## Phase 4:' "$SKILL_FILE" | head -1 | cut -d: -f1)
doc_writer_line=$(grep -n 'dso:doc-writer' "$SKILL_FILE" | head -1 | cut -d: -f1)

if [[ -n "$launch_phase_line" && -n "$doc_writer_line" && "$doc_writer_line" -gt "$launch_phase_line" ]]; then
  run_test "doc-writer dispatch section appears in Sub-Agent Launch phase (Phase 4)" "pass"
else
  run_test "doc-writer dispatch section appears in Sub-Agent Launch phase (Phase 4)" "fail"
fi

# Test 4: Documentation Story Dispatch section header exists
if grep -q 'Documentation Story Dispatch' "$SKILL_FILE"; then
  run_test "Sprint SKILL.md contains 'Documentation Story Dispatch' section" "pass"
else
  run_test "Sprint SKILL.md contains 'Documentation Story Dispatch' section" "fail"
fi

echo ""
echo "Results: $pass passed, $fail failed"

if [[ "$fail" -gt 0 ]]; then
  exit 1
fi
