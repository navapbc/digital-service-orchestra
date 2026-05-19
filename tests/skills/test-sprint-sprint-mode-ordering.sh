#!/usr/bin/env bash
# tests/skills/test-sprint-sprint-mode-ordering.sh
# Structural ordering invariant for sprint SKILL.md SPRINT_MODE references.
#
# Per behavioral testing standard rule 5, instruction files are tested by
# their structural boundary (line ordering / heading structure), not by
# content strings. This test asserts that every bash-parameter reference to
# ${SPRINT_MODE...} in plugins/dso/skills/sprint/SKILL.md follows the
# SPRINT_MODE= assignment line.
#
# Bug f6fd-af80-9b13-4649: sprint silently skipped ci-pr-only Phase A blocks
# (Ruleset Preflight, Draft PR Creation) because they read ${SPRINT_MODE:-}
# at lines 158 and 175, before the SPRINT_MODE assignment at line 345 in the
# "Mode Detection" subsection. The bash blocks took the false branch silently.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
source "$SCRIPT_DIR/../lib/assert.sh"

SKILL_FILE="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"

echo "=== test-sprint-sprint-mode-ordering.sh ==="

if [[ ! -f "$SKILL_FILE" ]]; then
    (( ++FAIL ))
    printf "FAIL: skill file missing: %s\n" "$SKILL_FILE" >&2
    print_summary
fi

# Locate the SPRINT_MODE= assignment line. The canonical form is a bash code
# block starting with "SPRINT_MODE=" at column 1 (no leading whitespace, no
# inline-code backticks).
ASSIGNMENT_LINE=$(grep -nE '^SPRINT_MODE=' "$SKILL_FILE" | head -1 | cut -d: -f1)

if [[ -z "$ASSIGNMENT_LINE" ]]; then
    (( ++FAIL ))
    printf "FAIL: no 'SPRINT_MODE=' assignment line found in %s\n" "$SKILL_FILE" >&2
    print_summary
fi
echo "found SPRINT_MODE= assignment at line $ASSIGNMENT_LINE"

# Find every ${SPRINT_MODE...} bash-parameter expansion. These are the actual
# *reads* of the variable by the orchestrator's bash blocks. Prose mentions
# such as "When `SPRINT_MODE=ci-pr`" or table cells like "| SPRINT_MODE |" are
# NOT bash parameter expansions and are intentionally excluded by the ${ guard.
violations=0
while IFS=: read -r line _; do
    if [[ "$line" -lt "$ASSIGNMENT_LINE" ]]; then
        (( ++FAIL ))
        (( ++violations ))
        printf "FAIL: %s:%s references \${SPRINT_MODE...} before SPRINT_MODE= assignment at line %s\n" \
            "$SKILL_FILE" "$line" "$ASSIGNMENT_LINE" >&2
    fi
done < <(grep -nE '\$\{SPRINT_MODE' "$SKILL_FILE")

if [[ "$violations" -eq 0 ]]; then
    (( ++PASS ))
    echo "test_sprint_skill_mode_assignment_precedes_all_reads ... PASS"
fi

print_summary
