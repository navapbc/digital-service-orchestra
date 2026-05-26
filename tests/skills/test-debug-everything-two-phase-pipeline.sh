#!/usr/bin/env bash
# tests/skills/test-debug-everything-two-phase-pipeline.sh
# Structural tests for the two-phase parallel bug-resolution pipeline.
#
# Binding contract between /dso:debug-everything Bug-Fix Mode and /dso:fix-bug:
#   - dispatch-fix-batch.md MUST describe both an investigation phase and a
#     fix-application phase, with ticket scratch as the handoff medium.
#   - fix-bug SKILL.md Phase C MUST carry a scratch-aware entry (Step 0) with
#     three named paths (A/B/C).
#   - fix-bug SKILL.md Phase D MUST carry the investigation-only terminator
#     that writes the fix-bug:investigation scratch key.
#
# Rule 5 (instruction-file tests): assert only on structural boundary tokens.
# The scratch key string `fix-bug:investigation` is part of the machine-read
# contract — string identity matters.
#
# Usage:
#   bash tests/skills/test-debug-everything-two-phase-pipeline.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DISPATCH_FILE="$REPO_ROOT/plugins/dso/skills/debug-everything/prompts/dispatch-fix-batch.md"
FIX_BUG_FILE="$REPO_ROOT/plugins/dso/skills/fix-bug/SKILL.md"
DEBUG_SKILL_FILE="$REPO_ROOT/plugins/dso/skills/debug-everything/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-debug-everything-two-phase-pipeline.sh ==="
echo ""

# ─────────────────────────────────────────────────────────────────────────
# test_dispatch_describes_two_phases
#
# Contract: dispatch-fix-batch.md MUST describe both phases of the pipeline.
# ─────────────────────────────────────────────────────────────────────────
test_dispatch_describes_two_phases() {
  local _inv_count _fix_count
  _inv_count=$(grep -c "Investigation batch\|investigation-only\|Phase 1 — Investigation" "$DISPATCH_FILE" 2>/dev/null || echo 0)
  _fix_count=$(grep -c "Fix-application batch\|fix-application\|Phase 2 — Fix" "$DISPATCH_FILE" 2>/dev/null || echo 0)

  assert_eq \
    "test_dispatch_describes_two_phases: dispatch-fix-batch.md must reference investigation phase" \
    "1" "$([ "$_inv_count" -ge 1 ] && echo 1 || echo 0)"

  assert_eq \
    "test_dispatch_describes_two_phases: dispatch-fix-batch.md must reference fix-application phase" \
    "1" "$([ "$_fix_count" -ge 1 ] && echo 1 || echo 0)"
}

echo "--- test_dispatch_describes_two_phases ---"
test_dispatch_describes_two_phases
echo ""

# ─────────────────────────────────────────────────────────────────────────
# test_dispatch_uses_scratch_handoff
#
# Contract: dispatch-fix-batch.md MUST hand off investigation results via
# the `fix-bug:investigation` ticket-scratch key.
# ─────────────────────────────────────────────────────────────────────────
test_dispatch_uses_scratch_handoff() {
  local _found=0
  grep -q "fix-bug:investigation" "$DISPATCH_FILE" 2>/dev/null && _found=1

  assert_eq \
    "test_dispatch_uses_scratch_handoff: dispatch-fix-batch.md must reference fix-bug:investigation scratch key" \
    "1" "$_found"
}

echo "--- test_dispatch_uses_scratch_handoff ---"
test_dispatch_uses_scratch_handoff
echo ""

# ─────────────────────────────────────────────────────────────────────────
# test_fix_bug_phase_c_has_scratch_entry
#
# Contract: fix-bug SKILL.md Phase C must carry a Step 0 with the three
# integration paths (A: pre-loaded scratch, B: investigation-only, C: normal).
# ─────────────────────────────────────────────────────────────────────────
test_fix_bug_phase_c_has_scratch_entry() {
  local _step0_count _path_a _path_b _path_c
  _step0_count=$(grep -c "^### Step 0:" "$FIX_BUG_FILE" 2>/dev/null || echo 0)
  _path_a=$(grep -c "Path A" "$FIX_BUG_FILE" 2>/dev/null || echo 0)
  _path_b=$(grep -c "Path B" "$FIX_BUG_FILE" 2>/dev/null || echo 0)
  _path_c=$(grep -c "Path C" "$FIX_BUG_FILE" 2>/dev/null || echo 0)

  assert_eq \
    "test_fix_bug_phase_c_has_scratch_entry: Phase C must carry a Step 0 header" \
    "1" "$([ "$_step0_count" -ge 1 ] && echo 1 || echo 0)"

  assert_eq \
    "test_fix_bug_phase_c_has_scratch_entry: Phase C Step 0 must name Path A" \
    "1" "$([ "$_path_a" -ge 1 ] && echo 1 || echo 0)"

  assert_eq \
    "test_fix_bug_phase_c_has_scratch_entry: Phase C Step 0 must name Path B" \
    "1" "$([ "$_path_b" -ge 1 ] && echo 1 || echo 0)"

  assert_eq \
    "test_fix_bug_phase_c_has_scratch_entry: Phase C Step 0 must name Path C" \
    "1" "$([ "$_path_c" -ge 1 ] && echo 1 || echo 0)"
}

echo "--- test_fix_bug_phase_c_has_scratch_entry ---"
test_fix_bug_phase_c_has_scratch_entry
echo ""

# ─────────────────────────────────────────────────────────────────────────
# test_fix_bug_phase_d_writes_scratch_in_investigation_only_mode
#
# Contract: fix-bug SKILL.md Phase D must contain a Step 4 (or equivalent
# terminator) that writes the fix-bug:investigation scratch key when running
# in MODE: investigation-only and emits the INVESTIGATION_COMPLETE token.
# ─────────────────────────────────────────────────────────────────────────
test_fix_bug_phase_d_writes_scratch_in_investigation_only_mode() {
  local _scratch_set _complete_token
  _scratch_set=$(grep -c "ticket scratch set.*fix-bug:investigation" "$FIX_BUG_FILE" 2>/dev/null || echo 0)
  _complete_token=$(grep -c "INVESTIGATION_COMPLETE:" "$FIX_BUG_FILE" 2>/dev/null || echo 0)

  assert_eq \
    "test_fix_bug_phase_d_writes_scratch_in_investigation_only_mode: SKILL.md must show 'ticket scratch set ... fix-bug:investigation'" \
    "1" "$([ "$_scratch_set" -ge 1 ] && echo 1 || echo 0)"

  assert_eq \
    "test_fix_bug_phase_d_writes_scratch_in_investigation_only_mode: SKILL.md must emit INVESTIGATION_COMPLETE token" \
    "1" "$([ "$_complete_token" -ge 1 ] && echo 1 || echo 0)"
}

echo "--- test_fix_bug_phase_d_writes_scratch_in_investigation_only_mode ---"
test_fix_bug_phase_d_writes_scratch_in_investigation_only_mode
echo ""

# ─────────────────────────────────────────────────────────────────────────
# test_fix_bug_phase_c_prohibits_nested_dispatch_in_path_b
#
# Contract: Path B (investigation-only mode) MUST explicitly prohibit
# dispatching investigator sub-agents — the whole point of the split is
# to avoid the Agent-in-Agent failure mode.
# ─────────────────────────────────────────────────────────────────────────
test_fix_bug_phase_c_prohibits_nested_dispatch_in_path_b() {
  local _found=0
  # Match either "do NOT dispatch" or "cannot dispatch" with sub-agent / Agent tool context
  if grep -E -i "(do NOT|cannot|must not).*dispatch.*(investigator|sub-agent)|sub-agents.*cannot dispatch" \
      "$FIX_BUG_FILE" >/dev/null 2>&1; then
    _found=1
  fi

  assert_eq \
    "test_fix_bug_phase_c_prohibits_nested_dispatch_in_path_b: Phase C must prohibit nested investigator dispatch under investigation-only mode" \
    "1" "$_found"
}

echo "--- test_fix_bug_phase_c_prohibits_nested_dispatch_in_path_b ---"
test_fix_bug_phase_c_prohibits_nested_dispatch_in_path_b
echo ""

# ─────────────────────────────────────────────────────────────────────────
# test_debug_everything_references_two_phase_pipeline
#
# Contract: debug-everything SKILL.md must reference the two-phase pipeline
# as the Bug-Fix Mode execution model.
# ─────────────────────────────────────────────────────────────────────────
test_debug_everything_references_two_phase_pipeline() {
  local _found=0
  if grep -E -i "(two-phase|investigation-only|fix-application).*pipeline|pipeline.*(investigation|fix-application)" \
      "$DEBUG_SKILL_FILE" >/dev/null 2>&1; then
    _found=1
  fi

  assert_eq \
    "test_debug_everything_references_two_phase_pipeline: debug-everything SKILL.md must reference the two-phase pipeline" \
    "1" "$_found"
}

echo "--- test_debug_everything_references_two_phase_pipeline ---"
test_debug_everything_references_two_phase_pipeline
echo ""

print_summary
