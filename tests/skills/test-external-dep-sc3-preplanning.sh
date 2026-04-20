#!/usr/bin/env bash
# tests/skills/test-external-dep-sc3-preplanning.sh
# Structural boundary tests for preplanning SKILL.md External Dependencies SC3 features.
#
# Rule 5 compliant: tests structural tokens that preplanning SKILL.md must contain —
# section headings and behavioral boundary tokens, not content assertions.
#
# Asserts:
#   1. SKILL.md contains Phase 1.5 External Dependencies block reader section
#   2. SKILL.md contains the Refusal Gate section with diagnostic when block is missing
#   3. SKILL.md contains the handling=user_manual → manual:awaiting_user tag assignment
#
# Usage: bash tests/skills/test-external-dep-sc3-preplanning.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
set -uo pipefail
# Note: -e intentionally omitted — assert.sh uses arithmetic ((++FAIL)) which exits non-zero under -e

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/preplanning/SKILL.md"

source "${REPO_ROOT}/tests/lib/assert.sh"

echo "=== test-external-dep-sc3-preplanning.sh ==="

if [[ ! -f "$SKILL_MD" ]]; then
    echo "FATAL: preplanning SKILL.md not found at $SKILL_MD" >&2
    exit 1
fi

# ── test_skill_md_has_ext_dep_block_reader_section ───────────────────────────
_snapshot_fail
_has=0
if grep -q 'Phase 1.5: External Dependencies Block Reading' "$SKILL_MD"; then
    _has=1
fi
assert_eq "test_skill_md_has_ext_dep_block_reader_section: Phase 1.5 External Dependencies heading must be in SKILL.md" "1" "$_has"
assert_pass_if_clean "test_skill_md_has_ext_dep_block_reader_section"

# ── test_skill_md_has_refusal_gate_section ────────────────────────────────────
_snapshot_fail
_has=0
if grep -q 'Refusal Gate: External Dependencies Block Check' "$SKILL_MD"; then
    _has=1
fi
assert_eq "test_skill_md_has_refusal_gate_section: Refusal Gate section heading must be in SKILL.md" "1" "$_has"
assert_pass_if_clean "test_skill_md_has_refusal_gate_section"

# ── test_skill_md_has_user_manual_awaiting_tag ───────────────────────────────
_snapshot_fail
_has=0
if grep -q 'manual:awaiting_user' "$SKILL_MD"; then
    _has=1
fi
assert_eq "test_skill_md_has_user_manual_awaiting_tag: manual:awaiting_user tag assignment must be in SKILL.md" "1" "$_has"
assert_pass_if_clean "test_skill_md_has_user_manual_awaiting_tag"

print_summary
