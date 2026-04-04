#!/usr/bin/env bash
# tests/scripts/test-implementation-plan-ast-grep.sh
# Tests: verify implementation-plan SKILL.md Step 3 contains ast-grep (sg) guidance.
#
# Tests:
#  1. test_sg_guard_present        — grep for 'command -v sg' in SKILL.md
#  2. test_sg_fallback_present     — grep for Grep fallback instruction when sg unavailable
#
# Usage: bash tests/scripts/test-implementation-plan-ast-grep.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
IMPL_PLAN_SKILL="$DSO_PLUGIN_DIR/skills/implementation-plan/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-implementation-plan-ast-grep.sh ==="
echo ""

# ── test_sg_guard_present ─────────────────────────────────────────────────────
# Verify implementation-plan SKILL.md Step 3 (File Impact Enumeration) contains
# the 'command -v sg' guard for ast-grep availability check.
_snapshot_fail
_found=0
grep -q "command -v sg" "$IMPL_PLAN_SKILL" && _found=1
assert_eq "test_sg_guard_present: 'command -v sg' guard present in SKILL.md" \
  "1" "$_found"
assert_pass_if_clean "test_sg_guard_present"

# ── test_sg_fallback_present ──────────────────────────────────────────────────
# Verify implementation-plan SKILL.md Step 3 contains Grep fallback instruction
# for when sg is unavailable (the guard's else branch).
_snapshot_fail
_found=0
# Check that both sg guard and Grep fallback appear (fallback via grep or Grep tool reference)
grep -q "command -v sg" "$IMPL_PLAN_SKILL" \
  && grep -qE "Grep tool|grep -r|fall.?back" "$IMPL_PLAN_SKILL" \
  && _found=1
assert_eq "test_sg_fallback_present: Grep fallback instruction present alongside sg guard" \
  "1" "$_found"
assert_pass_if_clean "test_sg_fallback_present"

# ── Run summary ───────────────────────────────────────────────────────────────
print_summary
