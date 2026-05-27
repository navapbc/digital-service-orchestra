#!/usr/bin/env bash
# Tests for the 5th committee reviewer + arbitration
# Task: 498b-740a-3364-4a44
set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)

VSE_FILE="$REPO_ROOT/plugins/dso/skills/ui-designer/docs/reviewers/visual-spatial-evaluator.md"
DSL_FILE="$REPO_ROOT/plugins/dso/skills/ui-designer/docs/reviewers/design-systems-lead.md"
ARB_FILE="$REPO_ROOT/plugins/dso/skills/ui-designer/docs/arbitration.md"

pass=0
fail=0

chk() {
  local expr="$1"
  local label="$2"
  if eval "$expr" >/dev/null 2>&1; then
    echo "PASS: $label"
    pass=$((pass+1))
  else
    echo "FAIL: $label"
    fail=$((fail+1))
  fi
}

# ── File existence ──────────────────────────────────────────────────────────
chk "test -f '$VSE_FILE'" "visual-spatial-evaluator.md exists"
chk "test -f '$DSL_FILE'" "design-systems-lead.md exists"
chk "test -f '$ARB_FILE'" "arbitration.md exists"

# ── visual-spatial-evaluator.md content ────────────────────────────────────
chk "grep -q 'visual_hierarchy_legibility' '$VSE_FILE'" "VSE owns visual_hierarchy_legibility"
chk "grep -q 'pixel-observable' '$VSE_FILE'" "VSE describes pixel-observable role"
chk "grep -q 'bbox_confidence' '$VSE_FILE'" "VSE output shape includes bbox_confidence"
chk "grep -q 'dom_xpath' '$VSE_FILE'" "VSE output shape includes dom_xpath"
chk "grep -q 'visual-spatial-evaluator' '$VSE_FILE'" "VSE reviewer field is visual-spatial-evaluator"
chk "grep -q 'arbitration.md' '$VSE_FILE'" "VSE references arbitration.md"
chk "grep -q '4-reviewer' '$VSE_FILE'" "VSE documents 4-reviewer fallback"

# ── design-systems-lead.md content ─────────────────────────────────────────
chk "grep -q 'visual_hierarchy_intent' '$DSL_FILE'" "design-systems-lead has visual_hierarchy_intent"
chk "grep -q 'visual_hierarchy_intent' '$DSL_FILE'" "design-systems-lead JSON shape uses visual_hierarchy_intent"
chk "grep -q 'split' '$DSL_FILE'" "design-systems-lead documents dimension split"
# Legacy bare visual_hierarchy should only appear in transition note, not as an emitted dimension
chk "! grep -E '^[|] visual_hierarchy [|]' '$DSL_FILE'" "design-systems-lead table row does not have legacy visual_hierarchy"
chk "grep -q 'visual_hierarchy_legibility' '$DSL_FILE'" "design-systems-lead cross-references visual_hierarchy_legibility"

# ── arbitration.md content ──────────────────────────────────────────────────
chk "grep -q 'visual_hierarchy_legibility' '$ARB_FILE'" "arbitration documents visual_hierarchy_legibility tie-break"
chk "grep -q 'visual_hierarchy_intent' '$ARB_FILE'" "arbitration documents visual_hierarchy_intent tie-break"
chk "grep -qi 'fallback' '$ARB_FILE'" "arbitration documents 4-reviewer fallback"
chk "grep -qi 'tie defaults to block\|2-2' '$ARB_FILE'" "arbitration documents tie-defaults-to-block"
chk "grep -q 'visual-spatial-evaluator' '$ARB_FILE'" "arbitration names 5th reviewer"
chk "grep -q 'design-systems-lead' '$ARB_FILE'" "arbitration names design-systems-lead"
chk "grep -q 'needs-revision' '$ARB_FILE'" "arbitration uses needs-revision verdict"
chk "grep -q 'test-ui-designer-5-reviewer.sh' '$ARB_FILE'" "arbitration references regression test file"

echo ""
echo "PASSED: $pass  FAILED: $fail"
test "$fail" -eq 0
