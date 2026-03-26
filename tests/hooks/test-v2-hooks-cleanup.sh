#!/usr/bin/env bash
# tests/hooks/test-v2-hooks-cleanup.sh
# RED tests: assert that v2 .tickets/ references are absent from hook and
# script source files, and that v2-only scripts no longer exist.
#
# TDD RED phase (50a0-fa5e): all tests referencing patterns that still exist
# will FAIL until the GREEN story removes those v2 artifacts from hooks/scripts.
#
# Tests assert ABSENCE of v2 patterns. When the GREEN implementation task
# removes the patterns, these tests will pass.
#
# Usage: bash tests/hooks/test-v2-hooks-cleanup.sh
# Returns: exit 1 in RED state (v2 patterns present / files still exist),
#          exit 0 in GREEN state (all v2 artifacts removed)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HOOKS_DIR="$REPO_ROOT/plugins/dso/hooks"
SCRIPTS_DIR="$REPO_ROOT/plugins/dso/scripts"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-v2-hooks-cleanup.sh ==="
echo ""

# ── test_compute_diff_hash_no_dot_tickets_exclusion ───────────────────────────
# compute-diff-hash.sh must not contain a direct .tickets/ pathspec — only
# .tickets-tracker/ is the v3 ticket store.
# GREEN: compute-diff-hash.sh already has no .tickets/ pathspec.
echo "Test: test_compute_diff_hash_no_dot_tickets_exclusion"
_snapshot_fail
_file="$HOOKS_DIR/compute-diff-hash.sh"
matches=""
if [[ -f "$_file" ]]; then
    matches=$(grep -n "':!\.tickets/\|:!\.tickets/\|\.tickets/['\"]" "$_file" 2>/dev/null \
        | grep -v "tickets-tracker" | grep -v "^[[:space:]]*#" || true)
fi
if [[ -z "$matches" ]]; then
    assert_eq "test_compute_diff_hash_no_dot_tickets_exclusion: no .tickets/ pathspec" "" ""
else
    (( ++FAIL ))
    printf "FAIL: test_compute_diff_hash_no_dot_tickets_exclusion\n" >&2
    printf "  expected: no .tickets/ pathspec in compute-diff-hash.sh\n" >&2
    printf "  found:\n%s\n" "$matches" | sed 's/^/    /' >&2
fi
assert_pass_if_clean "test_compute_diff_hash_no_dot_tickets_exclusion"
echo ""

# ── test_capture_review_diff_no_dot_tickets_grep ─────────────────────────────
# capture-review-diff.sh must not contain any grep -v .tickets/ lines —
# these were v2 exclusion patterns that filtered .tickets/ from diff output.
# GREEN: capture-review-diff.sh already has no .tickets/ grep exclusions.
echo "Test: test_capture_review_diff_no_dot_tickets_grep"
_snapshot_fail
_file="$SCRIPTS_DIR/capture-review-diff.sh"
matches=""
if [[ -f "$_file" ]]; then
    matches=$(grep -n "\.tickets/" "$_file" 2>/dev/null \
        | grep -v "tickets-tracker" | grep -v "^[[:space:]]*#" || true)
fi
if [[ -z "$matches" ]]; then
    assert_eq "test_capture_review_diff_no_dot_tickets_grep: no .tickets/ references" "" ""
else
    (( ++FAIL ))
    printf "FAIL: test_capture_review_diff_no_dot_tickets_grep\n" >&2
    printf "  expected: no .tickets/ grep exclusion in capture-review-diff.sh\n" >&2
    printf "  found:\n%s\n" "$matches" | sed 's/^/    /' >&2
fi
assert_pass_if_clean "test_capture_review_diff_no_dot_tickets_grep"
echo ""

# ── test_review_classifier_no_dot_tickets_check ──────────────────────────────
# review-complexity-classifier.sh must not check for .tickets/* when filtering
# non-test files — the v3 store is at .tickets-tracker/, not .tickets/.
# RED: FAIL because review-complexity-classifier.sh still has:
#      if ! is_test_file "$cur_file" && [[ "$cur_file" != .tickets/* ]]; then
echo "Test: test_review_classifier_no_dot_tickets_check"
_snapshot_fail
_file="$SCRIPTS_DIR/review-complexity-classifier.sh"
matches=""
if [[ -f "$_file" ]]; then
    matches=$(grep -n "\.tickets/\*" "$_file" 2>/dev/null \
        | grep -v "tickets-tracker" || true)
fi
if [[ -z "$matches" ]]; then
    assert_eq "test_review_classifier_no_dot_tickets_check: no .tickets/* check" "" ""
else
    (( ++FAIL ))
    printf "FAIL: test_review_classifier_no_dot_tickets_check\n" >&2
    printf "  expected: no .tickets/* check in review-complexity-classifier.sh\n" >&2
    printf "  found:\n%s\n" "$matches" | sed 's/^/    /' >&2
fi
assert_pass_if_clean "test_review_classifier_no_dot_tickets_check"
echo ""

# ── test_skip_review_no_dot_tickets_pattern ──────────────────────────────────
# skip-review-check.sh must not list .tickets/* as a non-reviewable pattern —
# v3 uses .tickets-tracker/** in the shared allowlist config, not a hardcoded
# .tickets/* entry in the script body.
# RED: FAIL because skip-review-check.sh still has ".tickets/*" in the
#      SKIP_PATTERNS array.
echo "Test: test_skip_review_no_dot_tickets_pattern"
_snapshot_fail
_file="$SCRIPTS_DIR/skip-review-check.sh"
matches=""
if [[ -f "$_file" ]]; then
    matches=$(grep -n '\.tickets/\*\b\|\.tickets/\*"' "$_file" 2>/dev/null \
        | grep -v "tickets-tracker" || true)
fi
if [[ -z "$matches" ]]; then
    assert_eq "test_skip_review_no_dot_tickets_pattern: no .tickets/* pattern" "" ""
else
    (( ++FAIL ))
    printf "FAIL: test_skip_review_no_dot_tickets_pattern\n" >&2
    printf "  expected: no .tickets/* entry in skip-review-check.sh\n" >&2
    printf "  found:\n%s\n" "$matches" | sed 's/^/    /' >&2
fi
assert_pass_if_clean "test_skip_review_no_dot_tickets_pattern"
echo ""

# ── test_cascade_breaker_no_dot_tickets_passthrough ──────────────────────────
# cascade-circuit-breaker.sh must not have a .tickets/ case or passthrough —
# this was a v2 pattern to exempt .tickets/ writes from the circuit breaker.
# GREEN: cascade-circuit-breaker.sh already has no .tickets/ case.
echo "Test: test_cascade_breaker_no_dot_tickets_passthrough"
_snapshot_fail
_file="$HOOKS_DIR/cascade-circuit-breaker.sh"
matches=""
if [[ -f "$_file" ]]; then
    matches=$(grep -n "\.tickets/" "$_file" 2>/dev/null \
        | grep -v "tickets-tracker" | grep -v "^[[:space:]]*#" || true)
fi
if [[ -z "$matches" ]]; then
    assert_eq "test_cascade_breaker_no_dot_tickets_passthrough: no .tickets/ case" "" ""
else
    (( ++FAIL ))
    printf "FAIL: test_cascade_breaker_no_dot_tickets_passthrough\n" >&2
    printf "  expected: no .tickets/ passthrough in cascade-circuit-breaker.sh\n" >&2
    printf "  found:\n%s\n" "$matches" | sed 's/^/    /' >&2
fi
assert_pass_if_clean "test_cascade_breaker_no_dot_tickets_passthrough"
echo ""

# ── test_review_stop_no_dot_tickets_exclusion ────────────────────────────────
# review-stop-check.sh must not have a .tickets/ grep exclusion — the stop
# check does not need to filter .tickets/ paths separately now that the v3
# store is a separate worktree at .tickets-tracker/.
# GREEN: review-stop-check.sh already has no .tickets/ exclusion.
echo "Test: test_review_stop_no_dot_tickets_exclusion"
_snapshot_fail
_file="$HOOKS_DIR/review-stop-check.sh"
matches=""
if [[ -f "$_file" ]]; then
    matches=$(grep -n "\.tickets/" "$_file" 2>/dev/null \
        | grep -v "tickets-tracker" | grep -v "^[[:space:]]*#" || true)
fi
if [[ -z "$matches" ]]; then
    assert_eq "test_review_stop_no_dot_tickets_exclusion: no .tickets/ exclusion" "" ""
else
    (( ++FAIL ))
    printf "FAIL: test_review_stop_no_dot_tickets_exclusion\n" >&2
    printf "  expected: no .tickets/ grep exclusion in review-stop-check.sh\n" >&2
    printf "  found:\n%s\n" "$matches" | sed 's/^/    /' >&2
fi
assert_pass_if_clean "test_review_stop_no_dot_tickets_exclusion"
echo ""

# ── test_title_validator_no_dot_tickets_guard ────────────────────────────────
# title-length-validator.sh must not have a .tickets/ guard — the validator
# should not need to skip .tickets/ paths since that directory no longer exists.
# GREEN: title-length-validator.sh already has no .tickets/ guard.
echo "Test: test_title_validator_no_dot_tickets_guard"
_snapshot_fail
_file="$HOOKS_DIR/title-length-validator.sh"
matches=""
if [[ -f "$_file" ]]; then
    matches=$(grep -n "\.tickets/" "$_file" 2>/dev/null \
        | grep -v "tickets-tracker" | grep -v "^[[:space:]]*#" || true)
fi
if [[ -z "$matches" ]]; then
    assert_eq "test_title_validator_no_dot_tickets_guard: no .tickets/ guard" "" ""
else
    (( ++FAIL ))
    printf "FAIL: test_title_validator_no_dot_tickets_guard\n" >&2
    printf "  expected: no .tickets/ guard in title-length-validator.sh\n" >&2
    printf "  found:\n%s\n" "$matches" | sed 's/^/    /' >&2
fi
assert_pass_if_clean "test_title_validator_no_dot_tickets_guard"
echo ""

# ── test_orphaned_tasks_deleted ───────────────────────────────────────────────
# orphaned-tasks.sh must not exist — it was a v2 utility that detected orphaned
# ticket markdown files in .tickets/. With v3 event-sourced tickets, this script
# is obsolete and should be removed.
# RED: FAIL because plugins/dso/scripts/orphaned-tasks.sh still exists.
echo "Test: test_orphaned_tasks_deleted"
_snapshot_fail
_file="$SCRIPTS_DIR/orphaned-tasks.sh"
if [[ ! -f "$_file" ]]; then
    assert_eq "test_orphaned_tasks_deleted: orphaned-tasks.sh does not exist" "" ""
else
    (( ++FAIL ))
    printf "FAIL: test_orphaned_tasks_deleted\n" >&2
    printf "  expected: %s does not exist\n" "$_file" >&2
    printf "  found: file still present\n" >&2
fi
assert_pass_if_clean "test_orphaned_tasks_deleted"
echo ""

# ── test_restore_ticket_bodies_deleted ───────────────────────────────────────
# restore-ticket-bodies.sh must not exist — it was a v2 migration utility for
# restoring ticket body text from git history into .tickets/ markdown files.
# With v3 event-sourced tickets, this script is obsolete and should be removed.
# RED: FAIL because plugins/dso/scripts/restore-ticket-bodies.sh still exists.
echo "Test: test_restore_ticket_bodies_deleted"
_snapshot_fail
_file="$SCRIPTS_DIR/restore-ticket-bodies.sh"
if [[ ! -f "$_file" ]]; then
    assert_eq "test_restore_ticket_bodies_deleted: restore-ticket-bodies.sh does not exist" "" ""
else
    (( ++FAIL ))
    printf "FAIL: test_restore_ticket_bodies_deleted\n" >&2
    printf "  expected: %s does not exist\n" "$_file" >&2
    printf "  found: file still present\n" >&2
fi
assert_pass_if_clean "test_restore_ticket_bodies_deleted"
echo ""

# ── test_claude_safe_no_dot_tickets_comment ───────────────────────────────────
# claude-safe must not contain a reference to .tickets/ files — the comment on
# line 125 says ".tickets/ files are treated like any other uncommitted change"
# which is a v2 leftover (the v3 store is .tickets-tracker/, not .tickets/).
# RED: FAIL because plugins/dso/scripts/claude-safe still has this comment.
echo "Test: test_claude_safe_no_dot_tickets_comment"
_snapshot_fail
_file="$SCRIPTS_DIR/claude-safe"
matches=""
if [[ -f "$_file" ]]; then
    matches=$(grep -n "\.tickets/" "$_file" 2>/dev/null \
        | grep -v "tickets-tracker" || true)
fi
if [[ -z "$matches" ]]; then
    assert_eq "test_claude_safe_no_dot_tickets_comment: no .tickets/ comment" "" ""
else
    (( ++FAIL ))
    printf "FAIL: test_claude_safe_no_dot_tickets_comment\n" >&2
    printf "  expected: no .tickets/ references in claude-safe\n" >&2
    printf "  found:\n%s\n" "$matches" | sed 's/^/    /' >&2
fi
assert_pass_if_clean "test_claude_safe_no_dot_tickets_comment"
echo ""

# ── test_retro_gather_no_orphaned_tasks_call ─────────────────────────────────
# retro-gather.sh must not call orphaned-tasks.sh — since orphaned-tasks.sh
# is a v2 script that will be deleted, retro-gather.sh must not depend on it.
# RED: FAIL because retro-gather.sh still contains:
#      if [ -x "${CLAUDE_PLUGIN_ROOT}/scripts/orphaned-tasks.sh" ]; then
echo "Test: test_retro_gather_no_orphaned_tasks_call"
_snapshot_fail
_file="$SCRIPTS_DIR/retro-gather.sh"
matches=""
if [[ -f "$_file" ]]; then
    matches=$(grep -n "orphaned-tasks" "$_file" 2>/dev/null || true)
fi
if [[ -z "$matches" ]]; then
    assert_eq "test_retro_gather_no_orphaned_tasks_call: no orphaned-tasks.sh call" "" ""
else
    (( ++FAIL ))
    printf "FAIL: test_retro_gather_no_orphaned_tasks_call\n" >&2
    printf "  expected: retro-gather.sh does not call orphaned-tasks.sh\n" >&2
    printf "  found:\n%s\n" "$matches" | sed 's/^/    /' >&2
fi
assert_pass_if_clean "test_retro_gather_no_orphaned_tasks_call"
echo ""

# ── test_sprint_next_batch_no_tk_prefix_vars ─────────────────────────────────
# sprint-next-batch.sh must not define or use tk_show / tk_priority as variable
# names — these were v2 Python function names (tk_show) and field names
# (tk_priority) from the inline ticket-reading logic that assumed the old tk
# shim. Under v3, ticket data is fetched via the ticket CLI, not a Python
# function called tk_show.
# RED: FAIL because sprint-next-batch.sh still contains def tk_show and
#      tk_priority variable references.
echo "Test: test_sprint_next_batch_no_tk_prefix_vars"
_snapshot_fail
_file="$SCRIPTS_DIR/sprint-next-batch.sh"
matches=""
if [[ -f "$_file" ]]; then
    # Match Python def tk_show, or variable assignment to tk_priority, or tk_show( calls
    matches=$(grep -n "\bdef tk_show\b\|\btk_priority\b" "$_file" 2>/dev/null \
        | grep -v "^[[:space:]]*#" || true)
fi
if [[ -z "$matches" ]]; then
    assert_eq "test_sprint_next_batch_no_tk_prefix_vars: no tk_show/tk_priority names" "" ""
else
    (( ++FAIL ))
    printf "FAIL: test_sprint_next_batch_no_tk_prefix_vars\n" >&2
    printf "  expected: no tk_show or tk_priority in sprint-next-batch.sh\n" >&2
    printf "  found:\n%s\n" "$matches" | sed 's/^/    /' >&2
fi
assert_pass_if_clean "test_sprint_next_batch_no_tk_prefix_vars"
echo ""

print_summary
