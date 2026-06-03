#!/usr/bin/env bash
# tests/hooks/test-sprint-auto-resume-sprint-active.sh
# Structural tests verifying that auto-resume.md re-creates the .sprint-active
# marker before routing to Phase C (section (d)).
#
# Testing mode: RED → GREEN — test was written before the fix was applied.
#
# What we test (structural boundary contracts):
#   1. auto-resume.md contains 'touch ... .sprint-active' (re-create marker on resume)
#   2. The touch command references the repo root via git rev-parse --show-toplevel
#   3. The touch appears in section (d) (the ACTIVE > 0 branch that routes to Phase C)
#
# Rationale: auto-resume bypasses Phase A which creates the .sprint-active marker.
# Without explicit re-creation in section (d), resumed sessions run unguarded —
# check-session-merge-only.sh never activates. See bug 9643-620e-3fa5-449a.
#
# Usage:
#   bash tests/hooks/test-sprint-auto-resume-sprint-active.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

AUTO_RESUME_FILE="$PLUGIN_ROOT/plugins/dso/skills/sprint/prompts/auto-resume.md"

echo "=== test-sprint-auto-resume-sprint-active.sh ==="

# ---------------------------------------------------------------------------
# Guard: auto-resume.md must exist
# ---------------------------------------------------------------------------
if [[ ! -f "$AUTO_RESUME_FILE" ]]; then
    echo "FATAL: auto-resume.md not found at $AUTO_RESUME_FILE" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Assertion 1: auto-resume.md contains 'touch' with '.sprint-active'
# Verifies the re-creation command is present anywhere in the file.
# ---------------------------------------------------------------------------
if grep -q "touch.*\.sprint-active" "$AUTO_RESUME_FILE"; then
    assert_eq "touch_sprint_active_present" "present" "present"
else
    assert_eq "touch_sprint_active_present" "present" "missing"
fi

# ---------------------------------------------------------------------------
# Assertion 2: The touch command references git rev-parse --show-toplevel
# Mirrors Phase A verbatim: touch "$(git rev-parse --show-toplevel)/.sprint-active"
# ---------------------------------------------------------------------------
if grep -q 'git rev-parse --show-toplevel.*\.sprint-active\|\.sprint-active.*git rev-parse --show-toplevel' "$AUTO_RESUME_FILE"; then
    assert_eq "touch_uses_git_rev_parse_toplevel" "present" "present"
else
    assert_eq "touch_uses_git_rev_parse_toplevel" "present" "missing"
fi

# ---------------------------------------------------------------------------
# Assertion 3: The touch appears in section (d) context
# Extract section (d) (from '\(d\)' up to next lettered section '\(e\)')
# and verify it contains '.sprint-active'.
# ---------------------------------------------------------------------------
SECTION_D_CONTENT=$(awk '/^\(d\)/{found=1} found && /^\(e\)/{exit} found{print}' "$AUTO_RESUME_FILE")
if grep -q "\.sprint-active" <(echo "$SECTION_D_CONTENT"); then
    assert_eq "sprint_active_in_section_d" "present" "present"
else
    assert_eq "sprint_active_in_section_d" "present" "missing"
fi

print_summary
