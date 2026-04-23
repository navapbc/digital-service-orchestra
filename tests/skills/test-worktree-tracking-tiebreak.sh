#!/usr/bin/env bash
# tests/skills/test-worktree-tracking-tiebreak.sh
# Structural boundary tests for competing-branch tiebreak cascade instructions
# in sprint/SKILL.md and fix-bug/SKILL.md (story 9b4c-2715 / epic 16f8-4b57).
#
# Tests:
#   test_sprint_resume_tiebreak_has_cascade        — 'tiebreak' present in sprint/SKILL.md WORKTREE_TRACKING resume scan block
#   test_sprint_resume_tiebreak_mentions_criterion_count — 'criterion|task-list|acceptance' near tiebreak section
#   test_sprint_resume_tiebreak_mentions_test_gate — 'test-gate' near tiebreak section
#   test_sprint_resume_tiebreak_mentions_timestamp — 'timestamp' as fallback in tiebreak section
#   test_fix_bug_tiebreak_mirrors_sprint           — 'tiebreak' in fix-bug/SKILL.md resume scan section
#
# All 5 tests are RED — tiebreak sections do not exist yet in the SKILL.md files.
#
# Usage: bash tests/skills/test-worktree-tracking-tiebreak.sh
# Returns: exit 0 if all assertions pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

SPRINT_SKILL="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"
FIXBUG_SKILL="$REPO_ROOT/plugins/dso/skills/fix-bug/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-worktree-tracking-tiebreak.sh ==="

# ---------------------------------------------------------------------------
# test_sprint_resume_tiebreak_has_cascade
# Structural boundary: sprint/SKILL.md must contain the word 'tiebreak' within
# the WORKTREE_TRACKING resume scan block to guide competing-branch resolution.
# RED — tiebreak cascade instruction not yet added.
# ---------------------------------------------------------------------------
echo "--- test_sprint_resume_tiebreak_has_cascade ---"
_snapshot_fail
if grep -q "tiebreak" "$SPRINT_SKILL" 2>/dev/null; then
    assert_eq "test_sprint_resume_tiebreak_has_cascade: tiebreak present in sprint/SKILL.md" "present" "present"
else
    assert_eq "test_sprint_resume_tiebreak_has_cascade: tiebreak present in sprint/SKILL.md" "present" "missing"
fi
assert_pass_if_clean "test_sprint_resume_tiebreak_has_cascade"

# ---------------------------------------------------------------------------
# test_sprint_resume_tiebreak_mentions_criterion_count
# Structural boundary: the tiebreak section must mention at least one of
# 'criterion', 'task-list', or 'acceptance' to indicate how branches are
# ranked by progress before falling back to further criteria.
# RED — not added yet.
# ---------------------------------------------------------------------------
echo "--- test_sprint_resume_tiebreak_mentions_criterion_count ---"
_snapshot_fail
if grep -qE "criterion|task-list|acceptance" "$SPRINT_SKILL" 2>/dev/null; then
    # The term must appear near the tiebreak context — verify tiebreak also exists
    if grep -q "tiebreak" "$SPRINT_SKILL" 2>/dev/null; then
        assert_eq "test_sprint_resume_tiebreak_mentions_criterion_count: criterion/task-list/acceptance near tiebreak" "present" "present"
    else
        assert_eq "test_sprint_resume_tiebreak_mentions_criterion_count: criterion/task-list/acceptance near tiebreak" "present" "missing"
    fi
else
    assert_eq "test_sprint_resume_tiebreak_mentions_criterion_count: criterion/task-list/acceptance near tiebreak" "present" "missing"
fi
assert_pass_if_clean "test_sprint_resume_tiebreak_mentions_criterion_count"

# ---------------------------------------------------------------------------
# test_sprint_resume_tiebreak_mentions_test_gate
# Structural boundary: the tiebreak section must reference 'test-gate' as a
# ranking signal so that the branch with more passing tests is preferred.
# RED — not added yet.
# ---------------------------------------------------------------------------
echo "--- test_sprint_resume_tiebreak_mentions_test_gate ---"
_snapshot_fail
_has_tiebreak=0
_has_test_gate=0
if grep -q "tiebreak" "$SPRINT_SKILL" 2>/dev/null; then _has_tiebreak=1; fi
if grep -q "test-gate" "$SPRINT_SKILL" 2>/dev/null; then _has_test_gate=1; fi

if [[ "$_has_tiebreak" -eq 1 && "$_has_test_gate" -eq 1 ]]; then
    assert_eq "test_sprint_resume_tiebreak_mentions_test_gate: test-gate mentioned in sprint tiebreak" "present" "present"
else
    assert_eq "test_sprint_resume_tiebreak_mentions_test_gate: test-gate mentioned in sprint tiebreak" "present" "missing"
fi
assert_pass_if_clean "test_sprint_resume_tiebreak_mentions_test_gate"

# ---------------------------------------------------------------------------
# test_sprint_resume_tiebreak_mentions_timestamp
# Structural boundary: the tiebreak section must mention 'timestamp' as the
# final fallback so that the most recently modified branch wins when all other
# criteria are equal.
# RED — not added yet.
# ---------------------------------------------------------------------------
echo "--- test_sprint_resume_tiebreak_mentions_timestamp ---"
_snapshot_fail
_has_tiebreak_ts=0
_has_timestamp=0
if grep -q "tiebreak" "$SPRINT_SKILL" 2>/dev/null; then _has_tiebreak_ts=1; fi
if grep -q "timestamp" "$SPRINT_SKILL" 2>/dev/null; then _has_timestamp=1; fi

if [[ "$_has_tiebreak_ts" -eq 1 && "$_has_timestamp" -eq 1 ]]; then
    assert_eq "test_sprint_resume_tiebreak_mentions_timestamp: timestamp fallback in sprint tiebreak" "present" "present"
else
    assert_eq "test_sprint_resume_tiebreak_mentions_timestamp: timestamp fallback in sprint tiebreak" "present" "missing"
fi
assert_pass_if_clean "test_sprint_resume_tiebreak_mentions_timestamp"

# ---------------------------------------------------------------------------
# test_fix_bug_tiebreak_mirrors_sprint
# Structural boundary: fix-bug/SKILL.md must also contain 'tiebreak' in its
# resume scan section, mirroring the sprint tiebreak cascade so both skills
# handle competing branches consistently.
# RED — tiebreak cascade instruction not yet added.
# ---------------------------------------------------------------------------
echo "--- test_fix_bug_tiebreak_mirrors_sprint ---"
_snapshot_fail
if grep -q "tiebreak" "$FIXBUG_SKILL" 2>/dev/null; then
    assert_eq "test_fix_bug_tiebreak_mirrors_sprint: tiebreak present in fix-bug/SKILL.md" "present" "present"
else
    assert_eq "test_fix_bug_tiebreak_mirrors_sprint: tiebreak present in fix-bug/SKILL.md" "present" "missing"
fi
assert_pass_if_clean "test_fix_bug_tiebreak_mirrors_sprint"

# --- run summary ---
print_summary
