#!/usr/bin/env bash
# tests/skills/test-sprint-pause-state-skill-boundary.sh
# Structural boundary tests for sprint SKILL.md pause-state integration (task d384-a569).
#
# Tests:
#   1. sprint SKILL.md references sprint-pause-state.sh
#   2. sprint SKILL.md references --resume in pause-state context
#   3. sprint SKILL.md has a pause state section/subsection heading
#
# Usage: bash tests/skills/test-sprint-pause-state-skill-boundary.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-sprint-pause-state-skill-boundary.sh ==="

if [[ ! -f "$SKILL_MD" ]]; then
    echo "FATAL: sprint SKILL.md not found at $SKILL_MD" >&2
    exit 1
fi

# ── test_skill_references_sprint_pause_state_script ──────────────────────────
_snapshot_fail
_has=0
if grep -q "sprint-pause-state.sh" "$SKILL_MD"; then
    _has=1
fi
assert_eq "test_skill_references_sprint_pause_state_script: SKILL.md must reference sprint-pause-state.sh" "1" "$_has"
assert_pass_if_clean "test_skill_references_sprint_pause_state_script"

# ── test_skill_references_resume_for_pause ───────────────────────────────────
_snapshot_fail
# Extract Phase 3.5 section content to check --resume in that specific context
_phase35=$(awk 'flag && /^## Phase [0-9]/{exit} /^## Phase 3\.5:/{flag=1} flag' "$SKILL_MD")
_has_resume=0
if echo "$_phase35" | grep -q -- "--resume"; then
    _has_resume=1
fi
assert_eq "test_skill_references_resume_for_pause: Phase 3.5 must reference --resume for pause-state recovery" "1" "$_has_resume"
assert_pass_if_clean "test_skill_references_resume_for_pause"

# ── test_skill_pause_state_section_exists ────────────────────────────────────
_snapshot_fail
_has=0
if grep -qiE "pause state|manual.pause|pause.state" "$SKILL_MD"; then
    _has=1
fi
assert_eq "test_skill_pause_state_section_exists: SKILL.md must contain pause state section or reference" "1" "$_has"
assert_pass_if_clean "test_skill_pause_state_section_exists"

print_summary
