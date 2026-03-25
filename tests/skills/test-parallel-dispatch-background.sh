#!/usr/bin/env bash
# tests/skills/test-parallel-dispatch-background.sh
# Asserts that sprint and debug-everything skills instruct run_in_background: true
# for batch sub-agent dispatch, so agents execute in parallel rather than serially.
#
# Bug 6709-2809: Sprint sub-agents launched 'in parallel' must use run_in_background
# or they execute serially. Foreground Agent calls block until they return, so
# launching 4 agents in one message without run_in_background still executes serially.
#
# Usage: bash tests/skills/test-parallel-dispatch-background.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SPRINT_SKILL="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"
DEBUG_SKILL="$REPO_ROOT/plugins/dso/skills/debug-everything/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-parallel-dispatch-background.sh ==="
echo ""

# ── test_sprint_batch_dispatch_requires_background ─────────────────────────
# The sprint skill's batch dispatch instruction must specify run_in_background
# so that sub-agents execute concurrently rather than serially.
echo "--- test_sprint_batch_dispatch_requires_background ---"
_snapshot_fail

# Look for run_in_background mentioned near the batch dispatch instruction
_found=0
grep -q 'run_in_background' "$SPRINT_SKILL" && _found=1 || true
assert_eq "test_sprint_batch_dispatch_requires_background: sprint SKILL.md must mention run_in_background" \
    "1" "$_found"
assert_pass_if_clean "test_sprint_batch_dispatch_requires_background"

# ── test_sprint_dispatch_instruction_specifies_background_true ─────────────
# The specific dispatch instruction paragraph must include run_in_background: true
# (not just a general mention somewhere else in the file).
echo ""
echo "--- test_sprint_dispatch_instruction_specifies_background_true ---"
_snapshot_fail

# The dispatch instruction is the paragraph containing "Launch ALL sub-agents"
# It must also contain run_in_background
_dispatch_para=$(grep -A5 'Launch ALL sub-agents' "$SPRINT_SKILL" || true)
_has_bg=0
echo "$_dispatch_para" | grep -q 'run_in_background' && _has_bg=1 || true
assert_eq "test_sprint_dispatch_instruction_specifies_background_true: dispatch paragraph must include run_in_background" \
    "1" "$_has_bg"
assert_pass_if_clean "test_sprint_dispatch_instruction_specifies_background_true"

# ── test_debug_everything_batch_dispatch_requires_background ───────────────
# The debug-everything skill's batch dispatch instruction must also specify
# run_in_background for the same reason.
echo ""
echo "--- test_debug_everything_batch_dispatch_requires_background ---"
_snapshot_fail

_found_de=0
grep -q 'run_in_background' "$DEBUG_SKILL" && _found_de=1 || true
assert_eq "test_debug_everything_batch_dispatch_requires_background: debug-everything SKILL.md must mention run_in_background" \
    "1" "$_found_de"
assert_pass_if_clean "test_debug_everything_batch_dispatch_requires_background"

# ── test_debug_everything_dispatch_instruction_specifies_background ────────
# The specific launch instruction paragraph must include run_in_background.
echo ""
echo "--- test_debug_everything_dispatch_instruction_specifies_background ---"
_snapshot_fail

_de_dispatch_para=$(grep -A5 'Launch all sub-agents in the batch' "$DEBUG_SKILL" || true)
_de_has_bg=0
echo "$_de_dispatch_para" | grep -q 'run_in_background' && _de_has_bg=1 || true
assert_eq "test_debug_everything_dispatch_instruction_specifies_background: dispatch paragraph must include run_in_background" \
    "1" "$_de_has_bg"
assert_pass_if_clean "test_debug_everything_dispatch_instruction_specifies_background"

# ── test_no_foreground_only_batch_claim ────────────────────────────────────
# Neither skill should claim "all foreground Tasks block until they return"
# without also mentioning run_in_background, since that phrasing implies
# foreground-only dispatch is the intended pattern.
echo ""
echo "--- test_no_foreground_only_batch_claim ---"
_snapshot_fail

_sprint_fg_only=0
# Check if "foreground Tasks" appears without run_in_background nearby
_sprint_fg_lines=$(grep -n 'foreground Task' "$SPRINT_SKILL" || true)
if [ -n "$_sprint_fg_lines" ]; then
    # If foreground Tasks is mentioned, run_in_background must also be present
    grep -q 'run_in_background' "$SPRINT_SKILL" || _sprint_fg_only=1
fi
assert_eq "test_no_foreground_only_batch_claim: sprint must not claim foreground-only pattern without run_in_background" \
    "0" "$_sprint_fg_only"
assert_pass_if_clean "test_no_foreground_only_batch_claim"

echo ""
print_summary
