#!/usr/bin/env bash
# Structural validation for shared sub-workflow documentation references.
# Tests: CLAUDE.md references shared scrutiny pipeline, value/effort scorer,
#        and scrutiny:pending gate behavior; no SKILL.md files reference old
#        reviewer paths; shared reviewer prompts exist at consolidated location.
# Tests 1-3 are RED — fail until CLAUDE.md is updated.
# Tests 4-5 should PASS — consolidation already done.
set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CLAUDE_MD="${REPO_ROOT}/CLAUDE.md"
SKILLS_DIR="${REPO_ROOT}/plugins/dso/skills"
SHARED_REVIEWERS_DIR="${REPO_ROOT}/plugins/dso/skills/shared/docs/reviewers"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: CLAUDE.md references the shared scrutiny pipeline
#         (shared/workflows/epic-scrutiny-pipeline.md)
# ---------------------------------------------------------------------------
test_claude_md_references_scrutiny_pipeline() {
  echo "=== test_claude_md_references_scrutiny_pipeline ==="

  if grep -q "shared/workflows/epic-scrutiny-pipeline.md" "$CLAUDE_MD"; then
    pass "CLAUDE.md references shared/workflows/epic-scrutiny-pipeline.md"
  else
    fail "CLAUDE.md missing reference to shared/workflows/epic-scrutiny-pipeline.md — add a reference in the Architecture or Skills section"
  fi
}

# ---------------------------------------------------------------------------
# Test 2: CLAUDE.md references the value/effort scorer
#         (shared/prompts/value-effort-scorer.md or value-effort-scorer)
# ---------------------------------------------------------------------------
test_claude_md_references_value_effort_scorer() {
  echo ""
  echo "=== test_claude_md_references_value_effort_scorer ==="

  if grep -qE "shared/prompts/value-effort-scorer\.md|value-effort-scorer" "$CLAUDE_MD"; then
    pass "CLAUDE.md references value-effort-scorer (shared/prompts/value-effort-scorer.md or value-effort-scorer)"
  else
    fail "CLAUDE.md missing reference to value-effort-scorer — add a reference in the Architecture or Skills section"
  fi
}

# ---------------------------------------------------------------------------
# Test 3: CLAUDE.md references scrutiny:pending gate behavior
# ---------------------------------------------------------------------------
test_claude_md_references_scrutiny_pending() {
  echo ""
  echo "=== test_claude_md_references_scrutiny_pending ==="

  if grep -q "scrutiny:pending" "$CLAUDE_MD"; then
    pass "CLAUDE.md references scrutiny:pending gate behavior"
  else
    fail "CLAUDE.md missing reference to scrutiny:pending — add a description of the gate behavior in the Architecture or Skills section"
  fi
}

# ---------------------------------------------------------------------------
# Test 4: No skill SKILL.md file references old brainstorm/docs/reviewers/ or
#         roadmap/docs/reviewers/ paths (negative constraint)
# ---------------------------------------------------------------------------
test_no_skill_md_references_old_reviewer_paths() {
  echo ""
  echo "=== test_no_skill_md_references_old_reviewer_paths ==="

  local violations=0
  local violation_files=()

  while IFS= read -r skill_file; do
    if grep -qE "brainstorm/docs/reviewers/|roadmap/docs/reviewers/" "$skill_file" 2>/dev/null; then
      violations=$((violations + 1))
      violation_files+=("$skill_file")
    fi
  done < <(find "$SKILLS_DIR" -name "SKILL.md")

  if [ "$violations" -eq 0 ]; then
    pass "No SKILL.md files reference old brainstorm/docs/reviewers/ or roadmap/docs/reviewers/ paths"
  else
    fail "Found $violations SKILL.md file(s) referencing old reviewer paths (must use shared/docs/reviewers/): ${violation_files[*]}"
  fi
}

# ---------------------------------------------------------------------------
# Test 5: Shared reviewer prompts exist at consolidated location
#         (plugins/dso/skills/shared/docs/reviewers/)
# ---------------------------------------------------------------------------
test_shared_reviewer_prompts_exist() {
  echo ""
  echo "=== test_shared_reviewer_prompts_exist ==="

  if [ ! -d "$SHARED_REVIEWERS_DIR" ]; then
    fail "Shared reviewer prompts directory missing: plugins/dso/skills/shared/docs/reviewers/"
    return
  fi

  local file_count
  file_count=$(find "$SHARED_REVIEWERS_DIR" -maxdepth 1 -name "*.md" | wc -l | tr -d ' ')

  if [ "$file_count" -gt 0 ]; then
    pass "Shared reviewer prompts directory exists at plugins/dso/skills/shared/docs/reviewers/ with $file_count .md file(s)"
  else
    fail "Shared reviewer prompts directory exists but contains no .md files: plugins/dso/skills/shared/docs/reviewers/"
  fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_claude_md_references_scrutiny_pipeline
test_claude_md_references_value_effort_scorer
test_claude_md_references_scrutiny_pending
test_no_skill_md_references_old_reviewer_paths
test_shared_reviewer_prompts_exist

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
