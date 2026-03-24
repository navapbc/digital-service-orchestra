#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-qt4u.sh
# Tests for dso-qt4u: archive rename/delete conflict auto-resolution and resume support.
#
# TDD tests (static analysis):
#   1. test_auto_resolve_archive_rename_delete_fn_exists — _auto_resolve_archive_conflicts() defined
#   2. test_pull_rebase_failure_calls_auto_resolve — pull failure path calls auto-resolve helper
#   3. test_auto_resolve_handles_rename_delete_pattern — function checks for rename/delete conflicts
#   4. test_auto_resolve_uses_git_rm — resolves deleted side via git rm
#   5. test_auto_resolve_continues_rebase — calls git rebase --continue after resolving
#   6. test_resume_detects_mid_rebase_state — --resume detects REBASE_HEAD and offers continue
#   7. test_pull_conflict_emits_resume_instruction — conflict path prints --resume instruction
#   8. test_bash_syntax_passes — bash -n check on merge-to-main.sh
#
# TDD tests (integration):
#   9. test_archive_rename_delete_auto_resolved — static: function has archive-pattern logic
#   10. test_non_archive_conflict_still_aborts — non-archive conflict has abort path
#
# Usage: bash tests/scripts/test-merge-to-main-qt4u.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# =============================================================================
# Test 1: _auto_resolve_archive_conflicts function exists in merge-to-main.sh
# =============================================================================
HAS_FUNCTION=$(grep -c '_auto_resolve_archive_conflicts()' "$MERGE_SCRIPT" || true)
assert_ne "test_auto_resolve_archive_rename_delete_fn_exists" "0" "$HAS_FUNCTION"

# =============================================================================
# Test 2: pull --rebase failure path calls _auto_resolve_archive_conflicts
# The pull failure handler should attempt auto-resolution before giving up.
# =============================================================================
PULL_SECTION=$(sed -n '/git pull --rebase/,/OK: Pulled remote/p' "$MERGE_SCRIPT")
HAS_AUTO_RESOLVE_CALL=$(echo "$PULL_SECTION" | grep -c '_auto_resolve_archive_conflicts' || true)
assert_ne "test_pull_rebase_failure_calls_auto_resolve" "0" "$HAS_AUTO_RESOLVE_CALL"

# =============================================================================
# Test 3: _auto_resolve_archive_conflicts checks for rename/delete conflict pattern
# The function should inspect conflicts and only proceed for archive patterns.
# =============================================================================
FN_BODY=$(sed -n '/_auto_resolve_archive_conflicts()/,/^}/p' "$MERGE_SCRIPT")
HAS_ARCHIVE_PATH_CHECK=$(echo "$FN_BODY" | grep -cE 'archive|tickets/archive' || true)
assert_ne "test_auto_resolve_handles_rename_delete_pattern" "0" "$HAS_ARCHIVE_PATH_CHECK"

# =============================================================================
# Test 4: _auto_resolve_archive_conflicts uses git rm to resolve the deleted side
# Archive rename/delete conflicts: accept deletion of old path via git rm.
# =============================================================================
HAS_GIT_RM=$(echo "$FN_BODY" | grep -c 'git rm' || true)
assert_ne "test_auto_resolve_uses_git_rm" "0" "$HAS_GIT_RM"

# =============================================================================
# Test 5: _auto_resolve_archive_conflicts calls git rebase --continue
# After resolving conflicts, the function must continue the rebase.
# =============================================================================
HAS_REBASE_CONTINUE=$(echo "$FN_BODY" | grep -c 'rebase --continue' || true)
assert_ne "test_auto_resolve_continues_rebase" "0" "$HAS_REBASE_CONTINUE"

# =============================================================================
# Test 6: --resume dispatch detects mid-rebase state (REBASE_HEAD present)
# When --resume is called with a rebase in progress, it should detect the
# REBASE_HEAD file and offer to continue rather than abort and restart.
# =============================================================================
RESUME_SECTION=$(sed -n '/Dispatch: --resume/,/No-args/p' "$MERGE_SCRIPT")
HAS_REBASE_HEAD_CHECK=$(echo "$RESUME_SECTION" | grep -c 'REBASE_HEAD' || true)
assert_ne "test_resume_detects_mid_rebase_state" "0" "$HAS_REBASE_HEAD_CHECK"

# =============================================================================
# Test 7: Pull conflict path prints --resume instruction for agents
# When git pull --rebase fails and auto-resolve can't fix it, the error message
# should instruct the agent to run --resume after manual resolution.
# =============================================================================
PULL_CONFLICT_SECTION=$(sed -n '/CONFLICT_DATA: phase=pull_rebase/,/exit 1/p' "$MERGE_SCRIPT" | head -10)
HAS_RESUME_INSTRUCTION=$(echo "$PULL_CONFLICT_SECTION" | grep -cE '\-\-resume' || true)
assert_ne "test_pull_conflict_emits_resume_instruction" "0" "$HAS_RESUME_INSTRUCTION"

# =============================================================================
# Test 8: bash -n syntax check passes after all changes
# =============================================================================
if bash -n "$MERGE_SCRIPT" 2>/dev/null; then
    SYNTAX_OK="pass"
else
    SYNTAX_OK="fail"
fi
assert_eq "test_bash_syntax_passes" "pass" "$SYNTAX_OK"

# =============================================================================
# Test 9: _auto_resolve_archive_conflicts has archive-pattern logic
# The function body must reference archive-path patterns to distinguish archive
# rename/delete conflicts from other types of conflict.
# (Reuses FN_BODY extracted in Test 3 — no re-extraction needed.)
# =============================================================================
HAS_ARCHIVE_PATTERN=$(echo "$FN_BODY" | grep -cE '\.tickets/archive|archive/' || true)
assert_ne "test_archive_rename_delete_auto_resolved" "0" "$HAS_ARCHIVE_PATTERN"

# =============================================================================
# Test 10: _auto_resolve_archive_conflicts has an abort path for non-archive conflicts
# Non-archive conflicts must not be silently resolved — function must return 1.
# =============================================================================
HAS_ABORT_PATH=$(echo "$FN_BODY" | grep -cE 'return 1|rebase --abort' || true)
assert_ne "test_non_archive_conflict_still_aborts" "0" "$HAS_ABORT_PATH"

# =============================================================================
# Test 11: _auto_resolve_archive_conflicts recognizes v3 .tickets-tracker/*.json patterns
# The function must treat .tickets-tracker/ JSON event files as safe ticket-data files.
# =============================================================================
HAS_V3_PATTERN=$(echo "$FN_BODY" | grep -cE 'tickets-tracker.*\.json|\.tickets-tracker' || true)
assert_ne "test_v3_tickets_tracker_json_in_safe_patterns" "0" "$HAS_V3_PATTERN"

# =============================================================================
# Test 12: case statement includes both v2 (.tickets/*.md) and v3 (.tickets-tracker/*.json) branches
# Both patterns must appear in the case statement so the classifier covers both systems.
# =============================================================================
HAS_V2_CASE=$(echo "$FN_BODY" | grep -cE '\.tickets/\*\.md|\.tickets/archive/\*\.md' || true)
HAS_V3_CASE=$(echo "$FN_BODY" | grep -cE '\.tickets-tracker/\*\.json|\.tickets-tracker/\*/\*\.json' || true)
assert_ne "test_v2_md_pattern_in_case" "0" "$HAS_V2_CASE"
assert_ne "test_v3_json_pattern_in_case" "0" "$HAS_V3_CASE"

# =============================================================================
# Test 13: v3 pattern uses git add (accept ours) not only git rm for JSON event files
# The function body must contain git add in proximity to the .tickets-tracker elif branch.
# We verify that git add appears in the function body when .tickets-tracker is present.
# (v3 JSON resolution: accept ours via git add if file present, git rm if absent)
# =============================================================================
# Verify that the function body has git add in a branch following .tickets-tracker elif
HAS_GIT_ADD_IN_FN=$(echo "$FN_BODY" | grep -c 'git add' || true)
assert_ne "test_v3_resolution_uses_git_add" "0" "$HAS_GIT_ADD_IN_FN"

# =============================================================================
# Test 14: bash -n syntax check still passes after v3 additions
# =============================================================================
if bash -n "$MERGE_SCRIPT" 2>/dev/null; then
    SYNTAX_OK_V3="pass"
else
    SYNTAX_OK_V3="fail"
fi
assert_eq "test_bash_syntax_passes_after_v3_additions" "pass" "$SYNTAX_OK_V3"

print_summary
