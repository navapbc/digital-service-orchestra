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

print_summary
