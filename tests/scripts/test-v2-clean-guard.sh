#!/usr/bin/env bash
# tests/scripts/test-v2-clean-guard.sh
# RED tests: assert no v2 tk stub/log patterns in test files.
#
# TDD RED phase (10f6-325d): all tests FAIL until the GREEN story removes
# FAKE_TK / TK_CALLS_FILE / TK_LOG_FILE stubs from tests/ and
# _CVF_TK_LOG / _SS_TK_LOG patterns from tests/hooks/.
#
# These tests assert that v2 patterns are ABSENT. They currently FAIL because
# v2 patterns ARE present. After the removal story cleans up the test files,
# these tests will pass (GREEN).
#
# Usage: bash tests/scripts/test-v2-clean-guard.sh
# Returns: exit 1 in RED state (v2 patterns present), exit 0 in GREEN state (removed)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-v2-clean-guard.sh ==="
echo ""

# ── test_no_fake_tk_stubs_in_test_files ──────────────────────────────────────
# No test file under tests/ may use the FAKE_TK stub pattern or the associated
# TK_CALLS_FILE / TK_LOG_FILE log-capture variables — these are v2 tk shim
# patterns that must be replaced with v3 ticket CLI equivalents.
# RED: FAIL because tests/scripts/test-lock-acquire-ticket-format.sh still
#      contains these patterns.
echo "Test: test_no_fake_tk_stubs_in_test_files"
_snapshot_fail
matches=$(grep -rl 'FAKE_TK\|TK_CALLS_FILE\|TK_LOG_FILE' \
    "$REPO_ROOT/tests/" --include='*.sh' 2>/dev/null \
    | grep -v 'test-v2-clean-guard\.sh' || true)
if [[ -z "$matches" ]]; then
    assert_eq "test_no_fake_tk_stubs_in_test_files: no matching files" "" ""
else
    (( ++FAIL ))
    printf "FAIL: test_no_fake_tk_stubs_in_test_files\n" >&2
    printf "  expected: no files containing FAKE_TK/TK_CALLS_FILE/TK_LOG_FILE\n" >&2
    printf "  found:\n%s\n" "$matches" | sed 's/^/    /' >&2
fi
assert_pass_if_clean "test_no_fake_tk_stubs_in_test_files"
echo ""

# ── test_no_cvf_tk_log_in_hook_tests ─────────────────────────────────────────
# No hook test file under tests/hooks/ may use the _CVF_TK_LOG or _SS_TK_LOG
# log-file variables — these are v2 per-hook tk log capture patterns that must
# be removed when those hooks no longer invoke the tk shim directly.
# RED: FAIL because tests/hooks/test-check-validation-failures.sh and
#      tests/hooks/test-session-safety.sh still contain these patterns.
echo "Test: test_no_cvf_tk_log_in_hook_tests"
_snapshot_fail
matches=$(grep -rl '_CVF_TK_LOG\|_SS_TK_LOG' \
    "$REPO_ROOT/tests/hooks/" --include='*.sh' 2>/dev/null || true)
if [[ -z "$matches" ]]; then
    assert_eq "test_no_cvf_tk_log_in_hook_tests: no matching files" "" ""
else
    (( ++FAIL ))
    printf "FAIL: test_no_cvf_tk_log_in_hook_tests\n" >&2
    printf "  expected: no files containing _CVF_TK_LOG/_SS_TK_LOG\n" >&2
    printf "  found:\n%s\n" "$matches" | sed 's/^/    /' >&2
fi
assert_pass_if_clean "test_no_cvf_tk_log_in_hook_tests"
echo ""

# ── test_no_v2_md_fixture_writes ─────────────────────────────────────────────
# No test file under tests/scripts/ may write v2-style .tickets/*.md frontmatter
# fixtures (e.g., printf/echo with status/id fields redirected to a .tickets/
# path). These are v2 ticket format patterns that must be replaced with v3
# ticket event-sourced fixtures.
# RED: FAIL because tests/scripts/test-sprint-next-batch.sh,
#      tests/scripts/test-validate-issues.sh, and others still create .tickets/*.md
#      files via redirect (> .tickets/foo.md) with YAML frontmatter.
echo "Test: test_no_v2_md_fixture_writes"
_snapshot_fail
matches=$(grep -rl '>\s*.*\.tickets/.*\.md' \
    "$REPO_ROOT/tests/scripts/" --include='*.sh' 2>/dev/null \
    | grep -v 'test-v2-clean-guard\.sh' || true)
if [[ -z "$matches" ]]; then
    assert_eq "test_no_v2_md_fixture_writes: no matching files" "" ""
else
    (( ++FAIL ))
    printf "FAIL: test_no_v2_md_fixture_writes\n" >&2
    printf "  expected: no files writing .tickets/*.md frontmatter fixtures\n" >&2
    printf "  found:\n%s\n" "$matches" | sed 's/^/    /' >&2
fi
assert_pass_if_clean "test_no_v2_md_fixture_writes"
echo ""

# ── test_no_tickets_dir_md_writes_in_validate_tests ──────────────────────────
# test-validate-issues.sh must not write .tickets/*.md fixture files directly.
# Fixture helpers should be migrated to v3 event-sourced format.
# RED: FAIL because tests/scripts/test-validate-issues.sh still writes
#      .tickets/*.md files via redirect (> .tickets/foo.md) and the write_ticket
#      helper that redirects output to "$base/.tickets/$tid.md".
echo "Test: test_no_tickets_dir_md_writes_in_validate_tests"
_snapshot_fail
validate_file="$REPO_ROOT/tests/scripts/test-validate-issues.sh"
matches=""
if [[ -f "$validate_file" ]]; then
    matches=$(grep -E '>\s*.*\.tickets/.*\.md|\.tickets/[^"]*\.md' \
        "$validate_file" 2>/dev/null || true)
fi
if [[ -z "$matches" ]]; then
    assert_eq "test_no_tickets_dir_md_writes_in_validate_tests: no .tickets/*.md writes" "" ""
else
    (( ++FAIL ))
    printf "FAIL: test_no_tickets_dir_md_writes_in_validate_tests\n" >&2
    printf "  expected: test-validate-issues.sh has no .tickets/*.md fixture writes\n" >&2
    printf "  found matching lines:\n" >&2
    printf "%s\n" "$matches" | sed 's/^/    /' >&2
fi
assert_pass_if_clean "test_no_tickets_dir_md_writes_in_validate_tests"
echo ""

# ── test_no_tickets_dir_md_writes_in_orphaned_tests ──────────────────────────
# test-orphaned-tasks.sh (if it exists) must not write .tickets/*.md fixture
# files directly. Any fixture helpers should use v3 event-sourced format.
# GREEN: test-orphaned-tasks.sh currently has no .tickets/*.md writes, so this
#        test passes immediately. It acts as a regression guard to prevent
#        reintroduction of v2-style fixture writes.
echo "Test: test_no_tickets_dir_md_writes_in_orphaned_tests"
_snapshot_fail
orphaned_file="$REPO_ROOT/tests/scripts/test-orphaned-tasks.sh"
matches=""
if [[ -f "$orphaned_file" ]]; then
    matches=$(grep -E '>\s*.*\.tickets/.*\.md|\.tickets/[^"]*\.md' \
        "$orphaned_file" 2>/dev/null || true)
fi
if [[ -z "$matches" ]]; then
    assert_eq "test_no_tickets_dir_md_writes_in_orphaned_tests: no .tickets/*.md writes" "" ""
else
    (( ++FAIL ))
    printf "FAIL: test_no_tickets_dir_md_writes_in_orphaned_tests\n" >&2
    printf "  expected: test-orphaned-tasks.sh has no .tickets/*.md fixture writes\n" >&2
    printf "  found matching lines:\n" >&2
    printf "%s\n" "$matches" | sed 's/^/    /' >&2
fi
assert_pass_if_clean "test_no_tickets_dir_md_writes_in_orphaned_tests"
echo ""

# ── test_no_issue_tracker_create_cmd_in_config_fixtures ──────────────────────
# No config test fixture file may contain the deprecated 'issue_tracker.create_cmd'
# key. This key was removed from the config schema in the v3 ticket system
# migration. Its presence in test fixtures perpetuates stale config assumptions.
# RED: FAIL because tests/scripts/test-read-config.sh and
#      tests/scripts/test-flat-config-e2e.sh still contain test fixtures with
#      'issue_tracker.create_cmd'.
echo "Test: test_no_issue_tracker_create_cmd_in_config_fixtures"
_snapshot_fail
matches=$(grep -rl 'issue_tracker\.create_cmd' \
    "$REPO_ROOT/tests/scripts/test-read-config.sh" \
    "$REPO_ROOT/tests/scripts/test-flat-config-e2e.sh" 2>/dev/null || true)
if [[ -z "$matches" ]]; then
    assert_eq "test_no_issue_tracker_create_cmd_in_config_fixtures: no matching files" "" ""
else
    (( ++FAIL ))
    printf "FAIL: test_no_issue_tracker_create_cmd_in_config_fixtures\n" >&2
    printf "  expected: no files containing issue_tracker.create_cmd\n" >&2
    printf "  found:\n%s\n" "$matches" | sed 's/^/    /' >&2
fi
assert_pass_if_clean "test_no_issue_tracker_create_cmd_in_config_fixtures"
echo ""

print_summary
