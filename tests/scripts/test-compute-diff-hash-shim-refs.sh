#!/usr/bin/env bash
# tests/scripts/test-compute-diff-hash-shim-refs.sh
# Structural test: no SKILL.md or workflow doc should invoke compute-diff-hash.sh
# via "${CLAUDE_PLUGIN_ROOT}/hooks/compute-diff-hash.sh". Orchestrators running in
# worktree sessions get exit 127 because CLAUDE_PLUGIN_ROOT may point to the plugin
# cache (not the worktree repo tree). The correct invocation uses the shim:
#   "$REPO_ROOT/.claude/scripts/dso" compute-diff-hash.sh
# or in worktree context:
#   "$ORCHESTRATOR_ROOT/.claude/scripts/dso" compute-diff-hash.sh
#
# Tests:
#   1. test_no_plugin_root_path_in_workflow_docs   — no CLAUDE_PLUGIN_ROOT/hooks/compute-diff-hash path in workflow docs
#   2. test_no_plugin_root_path_in_skill_mds       — no CLAUDE_PLUGIN_ROOT/hooks/compute-diff-hash path in SKILL.md files
#   3. test_no_plugin_root_path_in_agent_mds       — no CLAUDE_PLUGIN_ROOT/hooks/compute-diff-hash path in agent docs
#   4. test_review_workflow_uses_shim              — REVIEW-WORKFLOW.md uses shim for compute-diff-hash
#   5. test_single_agent_integrate_uses_shim       — single-agent-integrate.md uses shim for compute-diff-hash
#
# Usage: bash tests/scripts/test-compute-diff-hash-shim-refs.sh

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
PASS=0
FAIL=0

# Pattern that should NOT appear in orchestrator-facing docs.
# Scripts inside plugins/dso/hooks/ and plugins/dso/scripts/ may legitimately
# reference CLAUDE_PLUGIN_ROOT because they resolve it from BASH_SOURCE — those
# are excluded from this check via the grep path scoping below.
_BAD_PATTERN='\$\{CLAUDE_PLUGIN_ROOT\}/hooks/compute-diff-hash\.sh'

# --- Test 1: no bad path in workflow docs ---
test_no_plugin_root_path_in_workflow_docs() {
  local desc="test_no_plugin_root_path_in_workflow_docs"
  local matches
  matches=$(grep -r "$_BAD_PATTERN" \
    "$REPO_ROOT/plugins/dso/docs/workflows/" \
    --include="*.md" -l 2>/dev/null || true)
  if [[ -z "$matches" ]]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc — found CLAUDE_PLUGIN_ROOT-based compute-diff-hash.sh path in workflow docs:"
    echo "$matches"
    FAIL=$((FAIL + 1))
  fi
}

# --- Test 2: no bad path in skill .md files ---
test_no_plugin_root_path_in_skill_mds() {
  local desc="test_no_plugin_root_path_in_skill_mds"
  local matches
  matches=$(grep -r "$_BAD_PATTERN" \
    "$REPO_ROOT/plugins/dso/skills/" \
    --include="*.md" -l 2>/dev/null || true)
  if [[ -z "$matches" ]]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc — found CLAUDE_PLUGIN_ROOT-based compute-diff-hash.sh path in skill docs:"
    echo "$matches"
    FAIL=$((FAIL + 1))
  fi
}

# --- Test 3: no bad path in agent .md files ---
test_no_plugin_root_path_in_agent_mds() {
  local desc="test_no_plugin_root_path_in_agent_mds"
  local matches
  matches=$(grep -r "$_BAD_PATTERN" \
    "$REPO_ROOT/plugins/dso/agents/" \
    --include="*.md" -l 2>/dev/null || true)
  if [[ -z "$matches" ]]; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc — found CLAUDE_PLUGIN_ROOT-based compute-diff-hash.sh path in agent docs:"
    echo "$matches"
    FAIL=$((FAIL + 1))
  fi
}

# --- Test 4: REVIEW-WORKFLOW.md uses shim for compute-diff-hash ---
test_review_workflow_uses_shim() {
  local desc="test_review_workflow_uses_shim"
  local file="$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md"
  if grep -q '\.claude/scripts/dso.*compute-diff-hash' "$file" 2>/dev/null; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc — expected shim invocation (.claude/scripts/dso compute-diff-hash.sh) in REVIEW-WORKFLOW.md"
    FAIL=$((FAIL + 1))
  fi
}

# --- Test 5: single-agent-integrate.md uses shim for compute-diff-hash ---
test_single_agent_integrate_uses_shim() {
  local desc="test_single_agent_integrate_uses_shim"
  local file="$REPO_ROOT/plugins/dso/skills/shared/prompts/single-agent-integrate.md"
  if grep -q '\.claude/scripts/dso.*compute-diff-hash' "$file" 2>/dev/null; then
    echo "PASS: $desc"
    PASS=$((PASS + 1))
  else
    echo "FAIL: $desc — expected shim invocation (.claude/scripts/dso compute-diff-hash.sh) in single-agent-integrate.md"
    FAIL=$((FAIL + 1))
  fi
}

# --- Run all tests ---
echo "=== test-compute-diff-hash-shim-refs.sh ==="

test_no_plugin_root_path_in_workflow_docs
test_no_plugin_root_path_in_skill_mds
test_no_plugin_root_path_in_agent_mds
test_review_workflow_uses_shim
test_single_agent_integrate_uses_shim

echo ""
echo "=== Summary: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  exit 1
fi
