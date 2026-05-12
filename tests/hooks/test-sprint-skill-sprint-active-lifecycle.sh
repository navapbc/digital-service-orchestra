#!/usr/bin/env bash
# tests/hooks/test-sprint-skill-sprint-active-lifecycle.sh
# Structural tests verifying that sprint SKILL.md contains .sprint-active lifecycle
# instructions in the correct phase contexts (Phase A creation, Phase I removal).
#
# Testing mode: UPDATE — assertions pass after the SKILL.md edits are applied.
#
# What we test (structural boundary contracts):
#   1. SKILL.md contains 'touch ... .sprint-active' (Phase A marker creation)
#   2. SKILL.md contains 'rm -f ... .sprint-active' (Phase I marker removal)
#   3. SKILL.md contains '.sprint-active' in Phase A context
#   4. SKILL.md contains '.sprint-active' in Phase I context
#
# Usage:
#   bash tests/hooks/test-sprint-skill-sprint-active-lifecycle.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

SKILL_FILE="$PLUGIN_ROOT/plugins/dso/skills/sprint/SKILL.md"

echo "=== test-sprint-skill-sprint-active-lifecycle.sh ==="

# ---------------------------------------------------------------------------
# Guard: SKILL.md must exist
# ---------------------------------------------------------------------------
if [[ ! -f "$SKILL_FILE" ]]; then
    echo "FATAL: SKILL.md not found at $SKILL_FILE" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Assertion 1: SKILL.md contains 'touch' with '.sprint-active'
# Verifies the Phase A creation command is present anywhere in the file.
# ---------------------------------------------------------------------------
if grep -q "touch.*\.sprint-active" "$SKILL_FILE"; then
    assert_eq "touch_sprint_active_present" "present" "present"
else
    assert_eq "touch_sprint_active_present" "present" "missing"
fi

# ---------------------------------------------------------------------------
# Assertion 2: SKILL.md contains 'rm -f' with '.sprint-active'
# Verifies the Phase I removal command is present anywhere in the file.
# ---------------------------------------------------------------------------
if grep -q "rm -f.*\.sprint-active" "$SKILL_FILE"; then
    assert_eq "rm_f_sprint_active_present" "present" "present"
else
    assert_eq "rm_f_sprint_active_present" "present" "missing"
fi

# ---------------------------------------------------------------------------
# Assertion 3: '.sprint-active' appears in Phase A context
# Extract the Phase A section (from '## Phase A:' up to next '## Phase ') and
# verify it contains '.sprint-active'.
# ---------------------------------------------------------------------------
PHASE_A_CONTENT=$(awk '/^## Phase A:/{found=1} found && /^## Phase [^A]/{exit} found{print}' "$SKILL_FILE")
if grep -q "\.sprint-active" <(echo "$PHASE_A_CONTENT"); then
    assert_eq "sprint_active_in_phase_a" "present" "present"
else
    assert_eq "sprint_active_in_phase_a" "present" "missing"
fi

# ---------------------------------------------------------------------------
# Assertion 4: '.sprint-active' appears in Phase I context
# Extract the Phase I section (from '## Phase I:' to end of file or next '## Phase ')
# and verify it contains '.sprint-active'.
# ---------------------------------------------------------------------------
PHASE_I_CONTENT=$(awk '/^## Phase I:/{found=1} found && /^## Phase [^I]/{exit} found{print}' "$SKILL_FILE")
if grep -q "\.sprint-active" <(echo "$PHASE_I_CONTENT"); then
    assert_eq "sprint_active_in_phase_i" "present" "present"
else
    assert_eq "sprint_active_in_phase_i" "present" "missing"
fi

print_summary
