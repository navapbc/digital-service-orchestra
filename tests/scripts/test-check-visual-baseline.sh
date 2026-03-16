#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-check-visual-baseline.sh
# TDD tests for check-visual-baseline.sh extraction from validate-work/SKILL.md Step 2b.
#
# Tests:
#   1. lockpick-workflow/scripts/check-visual-baseline.sh exists and is executable
#   2. scripts/check-visual-baseline.sh exec wrapper delegates to canonical script
#   3. validate-work/SKILL.md references check-visual-baseline.sh
#   4. Script outputs a VISUAL_REGRESSION= line to stdout (macOS / VISUAL_BASELINE_PATH unset)
#
# Usage: bash lockpick-workflow/tests/scripts/test-check-visual-baseline.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
CANONICAL_SCRIPT="$PLUGIN_ROOT/scripts/check-visual-baseline.sh"
WRAPPER_SCRIPT="$REPO_ROOT/scripts/check-visual-baseline.sh"
SKILL_MD="$PLUGIN_ROOT/skills/validate-work/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-visual-baseline.sh ==="

# ── test_canonical_script_exists ──────────────────────────────────────────────
# lockpick-workflow/scripts/check-visual-baseline.sh must exist
_snapshot_fail
if [[ -f "$CANONICAL_SCRIPT" ]]; then
    assert_eq "test_canonical_script_exists: file exists" "yes" "yes"
else
    assert_eq "test_canonical_script_exists: file exists" "yes" "no"
fi
assert_pass_if_clean "test_canonical_script_exists"

# ── test_canonical_script_is_executable ───────────────────────────────────────
# lockpick-workflow/scripts/check-visual-baseline.sh must be executable
_snapshot_fail
if [[ -x "$CANONICAL_SCRIPT" ]]; then
    assert_eq "test_canonical_script_is_executable: executable" "yes" "yes"
else
    assert_eq "test_canonical_script_is_executable: executable" "yes" "no"
fi
assert_pass_if_clean "test_canonical_script_is_executable"

# ── test_wrapper_delegates ────────────────────────────────────────────────────
# scripts/check-visual-baseline.sh exec wrapper must exist and reference the canonical script
_snapshot_fail
if [[ -f "$WRAPPER_SCRIPT" ]]; then
    assert_eq "test_wrapper_delegates: wrapper exists" "yes" "yes"
    # The wrapper must contain an exec call pointing to lockpick-workflow/scripts/check-visual-baseline.sh
    if grep -q 'lockpick-workflow/scripts/check-visual-baseline.sh' "$WRAPPER_SCRIPT" 2>/dev/null; then
        assert_eq "test_wrapper_delegates: wrapper references canonical" "yes" "yes"
    else
        assert_eq "test_wrapper_delegates: wrapper references canonical" "yes" "no"
    fi
else
    assert_eq "test_wrapper_delegates: wrapper exists" "yes" "no"
fi
assert_pass_if_clean "test_wrapper_delegates"

# ── test_skill_md_references_script ──────────────────────────────────────────
# validate-work/SKILL.md must reference check-visual-baseline.sh (not the raw inline block)
_snapshot_fail
if grep -q 'check-visual-baseline.sh' "$SKILL_MD" 2>/dev/null; then
    assert_eq "test_skill_md_references_script: SKILL.md references script" "yes" "yes"
else
    assert_eq "test_skill_md_references_script: SKILL.md references script" "yes" "no"
fi
assert_pass_if_clean "test_skill_md_references_script"

# ── test_check_visual_baseline_outputs_skipped_macos ─────────────────────────
# Script must output a VISUAL_REGRESSION= line to stdout.
# On macOS with VISUAL_BASELINE_PATH unset, output is VISUAL_REGRESSION=skipped_macos ...
# On Linux with TEST_VISUAL_CMD unset, output is VISUAL_REGRESSION=skipped ...
# Either way, a VISUAL_REGRESSION= line must appear.
_snapshot_fail
script_output=""
script_exit=0
script_output=$(VISUAL_BASELINE_PATH='' TEST_VISUAL_CMD='' bash "$CANONICAL_SCRIPT" 2>/dev/null) || script_exit=$?
assert_eq "test_check_visual_baseline_outputs_skipped_macos: exit 0" "0" "$script_exit"
if [[ "$script_output" == *"VISUAL_REGRESSION="* ]]; then
    assert_eq "test_check_visual_baseline_outputs_skipped_macos: VISUAL_REGRESSION= in output" "yes" "yes"
else
    assert_eq "test_check_visual_baseline_outputs_skipped_macos: VISUAL_REGRESSION= in output" "yes" "no"
fi
assert_pass_if_clean "test_check_visual_baseline_outputs_skipped_macos"

print_summary
