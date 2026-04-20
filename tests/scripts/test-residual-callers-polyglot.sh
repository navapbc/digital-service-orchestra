#!/usr/bin/env bash
# tests/scripts/test-residual-callers-polyglot.sh
# Structural RED tests for story efe0-69c3 (residual callers polyglot changes)
#
# These tests verify structural properties of validate-phase.sh,
# format-and-lint.sh, and pre-commit-format-fix.sh after polyglot refactoring.
# All 5 tests should FAIL before implementation tasks 3886-648a and a33d-2ac8
# add the production changes.
#
# Usage: bash tests/scripts/test-residual-callers-polyglot.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

VALIDATE_PHASE="$REPO_ROOT/plugins/dso/scripts/validate-phase.sh"
FORMAT_AND_LINT="$REPO_ROOT/plugins/dso/scripts/format-and-lint.sh"
PRE_COMMIT_FORMAT_FIX="$REPO_ROOT/plugins/dso/scripts/pre-commit-format-fix.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-residual-callers-polyglot.sh ==="

# -- test_validate_phase_no_cfg_required_for_format_check ----------------------
# Assert: validate-phase.sh does NOT use _cfg_required for format/lint keys.
# After polyglot refactoring, format/lint commands are optional (warn-only),
# so _cfg_required must not gate them. Fails RED until the refactor lands.
_snapshot_fail
found=$(grep -E '_cfg_required.*(commands\.(format|format_check|lint))' "$VALIDATE_PHASE" 2>/dev/null && echo "found_cfg_required" || echo "")
assert_eq "test_validate_phase_no_cfg_required_for_format_check" "" "$found"
assert_pass_if_clean "test_validate_phase_no_cfg_required_for_format_check"

# -- test_validate_phase_warns_when_format_check_absent ------------------------
# Assert: validate-phase.sh emits a [DSO WARN] when commands.format_check is
# not configured, rather than erroring out. Required for polyglot repos where
# format_check may not be set. Fails RED until warn path is added.
_snapshot_fail
if grep -qE '\[DSO WARN\].*commands\.format_check|commands\.format_check.*not configured' "$VALIDATE_PHASE" 2>/dev/null; then
    warn_result="found"
else
    warn_result=""
fi
assert_eq "test_validate_phase_warns_when_format_check_absent" "found" "$warn_result"
assert_pass_if_clean "test_validate_phase_warns_when_format_check_absent"

# -- test_validate_phase_guards_run_check_with_nonempty_check ------------------
# Assert: validate-phase.sh guards run_check calls for CMD_FORMAT_CHECK with a
# non-empty variable check, so an absent format_check command is silently
# skipped rather than triggering an error. Fails RED until guard is added.
_snapshot_fail
if grep -qE '\[\[ -n.*CMD_FORMAT_CHECK.*\]\]|\[ -n.*CMD_FORMAT_CHECK.*\]' "$VALIDATE_PHASE" 2>/dev/null; then
    guard_result="found"
else
    guard_result=""
fi
assert_eq "test_validate_phase_guards_run_check_with_nonempty_check" "found" "$guard_result"
assert_pass_if_clean "test_validate_phase_guards_run_check_with_nonempty_check"

# -- test_format_and_lint_has_python_only_rationale_comment --------------------
# Assert: format-and-lint.sh contains a comment explaining it is intentionally
# Python-only, so maintainers understand the scope is deliberate. Fails RED
# until the rationale comment is added.
_snapshot_fail
if grep -qiE 'intentionally python.only|pre.commit.*python files only|python.only.*pre.commit' "$FORMAT_AND_LINT" 2>/dev/null; then
    fmt_comment_result="found"
else
    fmt_comment_result=""
fi
assert_eq "test_format_and_lint_has_python_only_rationale_comment" "found" "$fmt_comment_result"
assert_pass_if_clean "test_format_and_lint_has_python_only_rationale_comment"

# -- test_pre_commit_format_fix_has_python_only_rationale_comment --------------
# Assert: pre-commit-format-fix.sh contains a similar rationale comment
# explaining its Python-only scope is intentional. Fails RED until added.
_snapshot_fail
if grep -qiE 'intentionally python.only|pre.commit.*python files only|python.only.*pre.commit' "$PRE_COMMIT_FORMAT_FIX" 2>/dev/null; then
    prefmt_comment_result="found"
else
    prefmt_comment_result=""
fi
assert_eq "test_pre_commit_format_fix_has_python_only_rationale_comment" "found" "$prefmt_comment_result"
assert_pass_if_clean "test_pre_commit_format_fix_has_python_only_rationale_comment"

# -- Summary -------------------------------------------------------------------
print_summary
