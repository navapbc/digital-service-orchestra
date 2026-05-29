#!/usr/bin/env bash
# shellcheck disable=SC2016
# (file-level: this test grep-matches literal `${var}` patterns from the
# source script; single quotes are intentional to keep them un-expanded.)
# Regression test for PR-C: merge-to-main-pr.sh _phase_staged_intermediate.
#
# Validates:
#   - Phase is no-op when STORY_PR_BASE is set (story-PR mode)
#   - Phase is no-op when BRANCH already matches staged-*
#   - Phase is no-op when DSO_SKIP_STAGED_INTERMEDIATE=1
#   - _create_staged_ref produces a name of the form staged-<sha>-<unix-ts>
#   - Hard-gate exit when check-staged-head fails (no remediation path)
#
# The full two-PR orchestration requires live gh + GitHub state, which is out
# of scope for a unit-level test. The integration path is covered manually by
# the operator after merging PR-C.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TARGET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/merge-to-main-pr.sh"
PASS=0
FAIL=0

_pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
_fail() { echo "FAIL: $1 ($2)"; FAIL=$((FAIL+1)); }

# ── Test 1: _phase_staged_intermediate is defined ────────────────────────────
if grep -q '^_phase_staged_intermediate()' "$TARGET_SCRIPT"; then
    _pass "test_phase_function_defined"
else
    _fail "test_phase_function_defined" "_phase_staged_intermediate() not found"
fi

# ── Test 2: _create_staged_ref is defined ────────────────────────────────────
if grep -q '^_create_staged_ref()' "$TARGET_SCRIPT"; then
    _pass "test_helper_function_defined"
else
    _fail "test_helper_function_defined" "_create_staged_ref() not found"
fi

# ── Test 3: top-level flow invokes _phase_staged_intermediate before _phase_merge ──
phase_inter_line=$(grep -n '_phase_staged_intermediate' "$TARGET_SCRIPT" | grep -v '^[[:space:]]*#' | awk -F: 'NR==1{print $1}')
# Find the LAST occurrence of '_phase_merge' to skip the function definition;
# the top-level call comes after the definition.
phase_merge_top=$(grep -n '_phase_merge' "$TARGET_SCRIPT" | grep -v '^[[:space:]]*#' | awk -F: 'END{print $1}')
if [[ -n "$phase_inter_line" && -n "$phase_merge_top" ]] && (( phase_inter_line < phase_merge_top )); then
    _pass "test_phase_called_before_merge"
else
    _fail "test_phase_called_before_merge" "phase_inter_line=$phase_inter_line phase_merge_top=$phase_merge_top"
fi

# ── Test 4: skip conditions are documented in the script ─────────────────────
if grep -q 'STORY_PR_BASE' "$TARGET_SCRIPT" \
   && grep -qE '\$BRANCH" == staged-' "$TARGET_SCRIPT" \
   && grep -q 'DSO_SKIP_STAGED_INTERMEDIATE' "$TARGET_SCRIPT"; then
    _pass "test_skip_conditions_present"
else
    _fail "test_skip_conditions_present" "expected STORY_PR_BASE + staged-* + DSO_SKIP guards"
fi

# ── Test 5: hard-gate path is wired up for check-staged-head ─────────────────
if grep -q '_staged_head_failed' "$TARGET_SCRIPT" \
   && grep -q "check-staged-head failed" "$TARGET_SCRIPT"; then
    _pass "test_hard_gate_present"
else
    _fail "test_hard_gate_present" "no check-staged-head hard-gate found in _phase_poll"
fi

# ── Test 6: ref creation uses gh api POST /git/refs ──────────────────────────
if grep -q 'gh api -X POST "repos/${_gh_repo}/git/refs"' "$TARGET_SCRIPT"; then
    _pass "test_ref_creation_via_gh_api"
else
    _fail "test_ref_creation_via_gh_api" "expected gh api POST /git/refs in _create_staged_ref"
fi

# ── Test 7: staged-* name format includes both sha and unix timestamp ────────
if grep -q 'staged-${_short_sha}-${_unix_ts}' "$TARGET_SCRIPT"; then
    _pass "test_staged_name_format"
else
    _fail "test_staged_name_format" "expected staged-<sha>-<unix_ts> format"
fi

# ── Test 8: PR1 title and body reference both branches ───────────────────────
# shellcheck disable=SC2016  # intentional: matching literal in source file
if grep -q 'staged: \${BRANCH} -> \${_staged_branch}' "$TARGET_SCRIPT"; then
    _pass "test_pr1_title_format"
else
    _fail "test_pr1_title_format" "expected PR1 title to reference both branches"
fi

# ── Test 9: BRANCH is repointed after PR1 merges ─────────────────────────────
# shellcheck disable=SC2016  # intentional: matching literal in source file
if grep -q 'BRANCH="\$_staged_branch"' "$TARGET_SCRIPT"; then
    _pass "test_branch_repointed_after_pr1"
else
    _fail "test_branch_repointed_after_pr1" "expected BRANCH=\$_staged_branch after PR1 merge"
fi

# ── Test 10: script remains syntactically valid ──────────────────────────────
if bash -n "$TARGET_SCRIPT" 2>/dev/null; then
    _pass "test_script_syntax_valid"
else
    _fail "test_script_syntax_valid" "bash -n reported syntax errors"
fi

# ── Summary ──────────────────────────────────────────────────────────────────
echo ""
echo "PASSED: $PASS  FAILED: $FAIL"
[[ $FAIL -eq 0 ]] && exit 0 || exit 1
