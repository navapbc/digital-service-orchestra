#!/usr/bin/env bash
# tests/skills/test-worktree-tracking-resume-scan.sh
# Structural boundary tests for WORKTREE_TRACKING resume scan sections in
# sprint and fix-bug SKILL.md files.
#
# Epic:  16f8-4b57 (Worktree/Branch Session Tracking)
# Task:  6720-39b0 (RED test phase)
#
# Tests (all RED until feature is implemented):
#   1. test_sprint_auto_resume_has_tracking_scan
#      — Auto-Resume Detection section of sprint/SKILL.md must contain 'WORKTREE_TRACKING'
#   2. test_sprint_resume_scan_mentions_unmatched_start
#      — that section must mention 'unmatched' or 'no corresponding'
#   3. test_sprint_resume_scan_covers_child_tickets
#      — that section must mention 'ticket list' or 'child'
#   4. test_fix_bug_has_auto_resume_detection
#      — fix-bug/SKILL.md must contain an 'Auto-Resume Detection' section
#   5. test_fix_bug_resume_has_tracking_scan
#      — WORKTREE_TRACKING must appear near Step 0.5 in fix-bug/SKILL.md
#   6. test_fix_bug_resume_mentions_abandoned_branch
#      — 'abandoned' or 'unmatched' must appear near that section
#
# Usage: bash tests/skills/test-worktree-tracking-resume-scan.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SPRINT_SKILL="$DSO_PLUGIN_DIR/skills/sprint/SKILL.md"
FIX_BUG_SKILL="$DSO_PLUGIN_DIR/skills/fix-bug/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-worktree-tracking-resume-scan.sh ==="

# ---------------------------------------------------------------------------
# test_sprint_auto_resume_has_tracking_scan
# The Auto-Resume Detection section of sprint/SKILL.md must contain
# 'WORKTREE_TRACKING' so the orchestrator scans tracking state during resume.
# RED: section does not yet reference WORKTREE_TRACKING.
# ---------------------------------------------------------------------------
_snapshot_fail
auto_resume_content=$(awk '/Auto-Resume Detection/,/^#{1,4} /' "$SPRINT_SKILL" 2>/dev/null || true)
if grep -q 'WORKTREE_TRACKING' <<< "$auto_resume_content"; then
    sprint_tracking_scan="found"
else
    sprint_tracking_scan="missing"
fi
assert_eq "test_sprint_auto_resume_has_tracking_scan" "found" "$sprint_tracking_scan"
assert_pass_if_clean "test_sprint_auto_resume_has_tracking_scan"

# ---------------------------------------------------------------------------
# test_sprint_resume_scan_mentions_unmatched_start
# The Auto-Resume Detection section must mention 'unmatched' or
# 'no corresponding' so agents know to detect orphaned tracking entries
# (started but not completed/landed).
# RED: section does not yet contain this language.
# ---------------------------------------------------------------------------
_snapshot_fail
if grep -qE 'unmatched|no corresponding' <<< "$auto_resume_content"; then
    sprint_unmatched="found"
else
    sprint_unmatched="missing"
fi
assert_eq "test_sprint_resume_scan_mentions_unmatched_start" "found" "$sprint_unmatched"
assert_pass_if_clean "test_sprint_resume_scan_mentions_unmatched_start"

# ---------------------------------------------------------------------------
# test_sprint_resume_scan_covers_child_tickets
# The Auto-Resume Detection section must reference 'ticket list' or 'child'
# so the scan enumerates child tickets to reconcile tracking state against.
# RED: section does not yet contain this language.
# ---------------------------------------------------------------------------
_snapshot_fail
if grep -qE 'ticket list|child' <<< "$auto_resume_content"; then
    sprint_child_tickets="found"
else
    sprint_child_tickets="missing"
fi
assert_eq "test_sprint_resume_scan_covers_child_tickets" "found" "$sprint_child_tickets"
assert_pass_if_clean "test_sprint_resume_scan_covers_child_tickets"

# ---------------------------------------------------------------------------
# test_fix_bug_has_auto_resume_detection
# fix-bug/SKILL.md must contain an 'Auto-Resume Detection' section so it
# mirrors sprint's resume pattern and handles interrupted fix-bug sessions.
# RED: file does not yet have this section.
# ---------------------------------------------------------------------------
_snapshot_fail
if grep -q 'Auto-Resume Detection' "$FIX_BUG_SKILL" 2>/dev/null; then
    fix_bug_auto_resume="found"
else
    fix_bug_auto_resume="missing"
fi
assert_eq "test_fix_bug_has_auto_resume_detection" "found" "$fix_bug_auto_resume"
assert_pass_if_clean "test_fix_bug_has_auto_resume_detection"

# ---------------------------------------------------------------------------
# test_fix_bug_resume_has_tracking_scan
# 'WORKTREE_TRACKING' must appear near Step 0.5 in fix-bug/SKILL.md so the
# skill inspects tracking state when resuming an interrupted bug fix.
# RED: WORKTREE_TRACKING does not yet appear in the file.
# ---------------------------------------------------------------------------
_snapshot_fail
# Extract content in the vicinity of Step 0.5 (up to 50 lines after it)
step05_context=$(awk '/Step 0\.5/,/Step 1/' "$FIX_BUG_SKILL" 2>/dev/null || true)
if grep -q 'WORKTREE_TRACKING' <<< "$step05_context"; then
    fix_bug_tracking="found"
else
    fix_bug_tracking="missing"
fi
assert_eq "test_fix_bug_resume_has_tracking_scan" "found" "$fix_bug_tracking"
assert_pass_if_clean "test_fix_bug_resume_has_tracking_scan"

# ---------------------------------------------------------------------------
# test_fix_bug_resume_mentions_abandoned_branch
# 'abandoned' or 'unmatched' must appear near the Step 0.5 / Auto-Resume
# Detection area of fix-bug/SKILL.md so agents can identify stale worktrees
# from a prior interrupted session.
# RED: these terms do not yet appear near that section.
# ---------------------------------------------------------------------------
_snapshot_fail
# Combine Step 0.5 context and any Auto-Resume Detection content
fix_bug_auto_resume_content=$(awk '/Auto-Resume Detection/,/^#{1,4} /' "$FIX_BUG_SKILL" 2>/dev/null || true)
combined_context="$step05_context
$fix_bug_auto_resume_content"
if grep -qE 'abandoned|unmatched' <<< "$combined_context"; then
    fix_bug_abandoned="found"
else
    fix_bug_abandoned="missing"
fi
assert_eq "test_fix_bug_resume_mentions_abandoned_branch" "found" "$fix_bug_abandoned"
assert_pass_if_clean "test_fix_bug_resume_mentions_abandoned_branch"

print_summary
