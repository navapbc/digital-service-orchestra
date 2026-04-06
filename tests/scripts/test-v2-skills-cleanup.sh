#!/usr/bin/env bash
# tests/scripts/test-v2-skills-cleanup.sh
# Tests that v2 .tickets/ references are absent from skill files and prompts.
#
# These are behavioral (negative constraint) tests verifying that the old v2
# ticket system paths (.tickets/ bare references, find .tickets/, edit .tickets/<id>.md,
# grep .tickets/*.md) have been removed from all skill files and prompts.
#
# Skills checked:
#   - sprint/SKILL.md           — no find .tickets/ or edit .tickets/<id>.md
#   - end-session/SKILL.md      — references .tickets-tracker/ not .tickets/ in guards
#   - resolve-conflicts/SKILL.md — references .tickets-tracker/ not .tickets/
#   - implementation-plan/SKILL.md — no .tickets/<id>.md references
#   - preplanning/SKILL.md       — no .tickets/<id>.md references
#   - brainstorm/SKILL.md        — no .tickets/*.md grep patterns
#   - oscillation-check/SKILL.md — references .tickets-tracker/ not .tickets/
#   - sprint/prompts/            — no .tickets/ references in any prompt file
#
# Usage: bash tests/scripts/test-v2-skills-cleanup.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILLS_DIR="$DSO_PLUGIN_DIR/skills"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-v2-skills-cleanup.sh ==="

# ---------------------------------------------------------------------------
# test_sprint_skill_no_dot_tickets_find
# sprint/SKILL.md must not instruct agents to use "find .tickets/" to look up tickets.
# This v2 pattern should be replaced by ticket CLI commands.
# ---------------------------------------------------------------------------
_snapshot_fail
sprint_find_count=0
if grep -qE 'find ["\047]?\.tickets/' "$SKILLS_DIR/sprint/SKILL.md" 2>/dev/null; then
    sprint_find_count=1
fi
assert_eq "test_sprint_skill_no_dot_tickets_find" "0" "$sprint_find_count"
assert_pass_if_clean "test_sprint_skill_no_dot_tickets_find"

# ---------------------------------------------------------------------------
# test_sprint_skill_no_dot_tickets_edit
# sprint/SKILL.md must not instruct agents to "edit .tickets/<id>.md" directly.
# This v2 pattern must be replaced by ticket CLI commands.
# ---------------------------------------------------------------------------
_snapshot_fail
sprint_edit_count=0
if grep -qE 'edit ["\047]?\.tickets/' "$SKILLS_DIR/sprint/SKILL.md" 2>/dev/null; then
    sprint_edit_count=1
fi
assert_eq "test_sprint_skill_no_dot_tickets_edit" "0" "$sprint_edit_count"
assert_pass_if_clean "test_sprint_skill_no_dot_tickets_edit"

# ---------------------------------------------------------------------------
# test_end_session_dot_tickets_updated
# end-session/SKILL.md guards must reference .tickets-tracker/ (v3 path), not .tickets/
# ---------------------------------------------------------------------------
_snapshot_fail
end_session_bare_count=0
# Count lines that have .tickets/ but NOT .tickets-tracker/
while IFS= read -r line; do
    if [[ "$line" == *".tickets/"* ]] && [[ "$line" != *".tickets-tracker/"* ]]; then
        end_session_bare_count=$((end_session_bare_count + 1))
    fi
done < <(grep '\.tickets/' "$SKILLS_DIR/end-session/SKILL.md" 2>/dev/null || true)
assert_eq "test_end_session_dot_tickets_updated" "0" "$end_session_bare_count"
assert_pass_if_clean "test_end_session_dot_tickets_updated"

# ---------------------------------------------------------------------------
# test_resolve_conflicts_dot_tickets_updated
# resolve-conflicts/SKILL.md must only reference .tickets-tracker/, not bare .tickets/
# ---------------------------------------------------------------------------
_snapshot_fail
resolve_bare_count=0
while IFS= read -r line; do
    if [[ "$line" == *".tickets/"* ]] && [[ "$line" != *".tickets-tracker/"* ]]; then
        resolve_bare_count=$((resolve_bare_count + 1))
    fi
done < <(grep '\.tickets/' "$SKILLS_DIR/resolve-conflicts/SKILL.md" 2>/dev/null || true)
assert_eq "test_resolve_conflicts_dot_tickets_updated" "0" "$resolve_bare_count"
assert_pass_if_clean "test_resolve_conflicts_dot_tickets_updated"

# ---------------------------------------------------------------------------
# test_impl_plan_no_dot_tickets
# implementation-plan/SKILL.md must not reference .tickets/<id>.md (v2 file-based tickets)
# ---------------------------------------------------------------------------
_snapshot_fail
impl_plan_count=0
if grep -qE '\.tickets/[^t]' "$SKILLS_DIR/implementation-plan/SKILL.md" 2>/dev/null; then
    impl_plan_count=1
fi
assert_eq "test_impl_plan_no_dot_tickets" "0" "$impl_plan_count"
assert_pass_if_clean "test_impl_plan_no_dot_tickets"

# ---------------------------------------------------------------------------
# test_preplanning_no_dot_tickets
# preplanning/SKILL.md must not reference .tickets/<id>.md (v2 file-based tickets)
# ---------------------------------------------------------------------------
_snapshot_fail
preplanning_count=0
if grep -qE '\.tickets/[^t]' "$SKILLS_DIR/preplanning/SKILL.md" 2>/dev/null; then
    preplanning_count=1
fi
assert_eq "test_preplanning_no_dot_tickets" "0" "$preplanning_count"
assert_pass_if_clean "test_preplanning_no_dot_tickets"

# ---------------------------------------------------------------------------
# test_brainstorm_no_dot_tickets
# brainstorm/SKILL.md must not reference .tickets/*.md grep patterns (v2 file enumeration)
# e.g., "grep -l '^type: epic' .tickets/*.md" must be replaced with CLI commands
# ---------------------------------------------------------------------------
_snapshot_fail
brainstorm_count=0
if grep -qE '\.tickets/\*\.md|\.tickets/[a-zA-Z0-9*].*\.md' "$SKILLS_DIR/brainstorm/SKILL.md" 2>/dev/null; then
    brainstorm_count=1
fi
assert_eq "test_brainstorm_no_dot_tickets" "0" "$brainstorm_count"
assert_pass_if_clean "test_brainstorm_no_dot_tickets"

# ---------------------------------------------------------------------------
# test_oscillation_no_dot_tickets
# oscillation-check/SKILL.md must reference .tickets-tracker/ not bare .tickets/
# The "Do NOT edit .tickets/ files" guard must be updated to v3 path.
# ---------------------------------------------------------------------------
_snapshot_fail
oscillation_bare_count=0
while IFS= read -r line; do
    if [[ "$line" == *".tickets/"* ]] && [[ "$line" != *".tickets-tracker/"* ]]; then
        oscillation_bare_count=$((oscillation_bare_count + 1))
    fi
done < <(grep '\.tickets/' "$SKILLS_DIR/oscillation-check/SKILL.md" 2>/dev/null || true)
assert_eq "test_oscillation_no_dot_tickets" "0" "$oscillation_bare_count"
assert_pass_if_clean "test_oscillation_no_dot_tickets"

# ---------------------------------------------------------------------------
# test_sprint_prompts_no_dot_tickets
# All sprint prompt files must have no bare .tickets/ references (v2 file-based tickets).
# Checks all .md files under skills/sprint/prompts/
# ---------------------------------------------------------------------------
_snapshot_fail
prompts_dir="$SKILLS_DIR/sprint/prompts"
sprint_prompts_total=0
while IFS= read -r line; do
    if [[ "$line" == *".tickets/"* ]] && [[ "$line" != *".tickets-tracker/"* ]]; then
        sprint_prompts_total=$((sprint_prompts_total + 1))
    fi
done < <(grep -r '\.tickets/' "$prompts_dir/" 2>/dev/null || true)
assert_eq "test_sprint_prompts_no_dot_tickets" "0" "$sprint_prompts_total"
assert_pass_if_clean "test_sprint_prompts_no_dot_tickets"

print_summary
