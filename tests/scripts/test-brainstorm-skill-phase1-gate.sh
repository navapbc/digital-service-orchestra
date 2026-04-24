#!/usr/bin/env bash
set -uo pipefail
# tests/scripts/test-brainstorm-skill-phase1-gate.sh
# Structural tests for 7c1d-e70d and a3e6-ac52:
#
#   7c1d-e70d: /dso:brainstorm Phase 1 Gate Step 1 (Understanding Summary)
#     uses inconsistent closing phrasing because the required phrasing is
#     only in the template block (example), not a hard requirement.
#     Fix: promote to an explicit MUST requirement section heading so the agent
#     treats it as mandatory, not advisory.
#
#   a3e6-ac52: /dso:brainstorm Phase 1 question answered by codebase inspection.
#     The "investigate before asking" rule is present but too soft — agent still
#     asked questions answerable by reading codebase.
#     Fix: promote codebase-investigation gate to an explicit mandatory section
#     heading so the agent recognizes it as a hard gate, not a suggestion.
#
# Per behavioral testing standard Rule 5 (instruction files): test the structural
# boundary of the skill file (section headings), not its content.
#
# Usage: bash tests/scripts/test-brainstorm-skill-phase1-gate.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/brainstorm/SKILL.md"

# skill-refactor: brainstorm phases extracted. Rebind SKILL_FILE to aggregated corpus
# (SKILL.md + phases/*.md + verifiable-sc-check.md).
_orig_SKILL_FILE="$SKILL_FILE"
source "$(git rev-parse --show-toplevel)/tests/skills/lib/brainstorm-skill-aggregate.sh"
SKILL_FILE=$(brainstorm_aggregate_path)
trap brainstorm_aggregate_cleanup EXIT


source "$REPO_ROOT/tests/lib/assert.sh"

if [[ ! -f "$SKILL_FILE" ]]; then
    echo "SKIP: brainstorm/SKILL.md not found at $SKILL_FILE"
    exit 0
fi

# ============================================================
# test_skill_has_understanding_summary_phrasing_section (7c1d-e70d)
#
# The Understanding Summary closing phrasing must be a hard requirement,
# not just template text. The skill must have an explicit section heading
# for the phrasing requirement so agents treat it as mandatory.
#
# Section heading (structural boundary): "### Understanding Summary Phrasing"
# or equivalent that signals a MUST requirement, not example text.
# ============================================================
test_skill_has_understanding_summary_phrasing_section() {
    local found=0
    grep -q '^### Understanding Summary Phrasing\|^### Closing Phrasing\|^#### Required Closing Phrasing\|^#### Understanding Summary Phrasing' \
        "$SKILL_FILE" 2>/dev/null && found=1 || true
    assert_eq "skill has Understanding Summary phrasing requirement section (7c1d-e70d)" "1" "$found"
}

# ============================================================
# test_skill_has_codebase_investigation_gate_section (a3e6-ac52)
#
# The codebase-investigation rule must be elevated to a mandatory gate
# section heading so agents recognize it as a hard gate before presenting
# any question to the user — not a soft suggestion buried in prose.
#
# Section heading (structural boundary): "### Codebase Investigation Gate"
# or equivalent signaling a mandatory pre-question check.
# ============================================================
test_skill_has_codebase_investigation_gate_section() {
    local found=0
    grep -q '^### Codebase Investigation Gate\|^### Investigation Gate\|^#### Codebase Investigation' \
        "$SKILL_FILE" 2>/dev/null && found=1 || true
    assert_eq "skill has codebase investigation gate section heading (a3e6-ac52)" "1" "$found"
}

# ============================================================
# test_brainstorm_skill_references_preconditions_record (ee92-7fb9)
#
# The brainstorm SKILL.md must reference preconditions-record.sh at the
# brainstorm:complete transition point so the preconditions baseline is
# captured before the tag is written.
#
# Structural boundary: presence of the script reference in the skill file.
# ============================================================
test_brainstorm_skill_references_preconditions_record() {
    local found
    found=$(grep -c "preconditions-record.sh" "$SKILL_FILE" 2>/dev/null || echo "0")
    assert_eq "brainstorm SKILL.md references preconditions-record.sh" "1" "$([ "${found:-0}" -ge 1 ] && echo 1 || echo 0)"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_skill_has_understanding_summary_phrasing_section
test_skill_has_codebase_investigation_gate_section
test_brainstorm_skill_references_preconditions_record

print_summary
