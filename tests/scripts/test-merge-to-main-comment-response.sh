#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-comment-response.sh
# RED behavioral tests for task 1911-d4e4 (story ac9b-ef7d):
#   comment_response phase in merge-to-main-direct.sh and merge-to-main-pr.sh
#
# These tests FAIL because the implementation doesn't exist yet.
# When implementation is complete:
#   - "comment_response" appears in _ALL_PHASES after "ci_trigger"
#   - _phase_comment_response is defined as a callable function
#   - The resume sequence treats comment_response as the next phase after ci_trigger
#
# Behavioral testing standard (Rule 5): tests assert observable behavior, not
# source code structure. Where structure tests are used, a REVIEW-DEFENSE comment
# explains why behavioral end-to-end testing is disproportionate.
#
# Usage: bash tests/scripts/test-merge-to-main-comment-response.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
DIRECT_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-direct.sh"
PR_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-pr.sh"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

PASS=0
FAIL=0

# ---------------------------------------------------------------------------
# Test 1: comment_response is present in _ALL_PHASES
#
# Given: merge-to-main-direct.sh exists and defines _ALL_PHASES
# When:  _ALL_PHASES is inspected by extracting the array declaration
# Then:  "comment_response" appears as an element
#
# REVIEW-DEFENSE: sourcing merge-to-main-direct.sh in lib mode does not expose
# _ALL_PHASES because the array declaration sits AFTER the lib-mode guard
# (line ~849). A runtime sub-shell with MERGE_TO_MAIN_DIRECT_LIB unset would
# execute CLI parsing and worktree guards, which require a real git environment
# and network. The structural extraction approach (awk on the declaration line)
# is the standard used across merge-to-main test files (see
# test-merge-to-main-ci-workflow-name.sh) and is appropriate here.
# ---------------------------------------------------------------------------
test_comment_response_in_all_phases() {
    local phases_line
    phases_line=$(grep -E '^_ALL_PHASES=' "$DIRECT_SCRIPT" 2>/dev/null || true)

    # Extract the phase names from the array declaration line
    local phases_found
    phases_found=$(echo "$phases_line" | grep -o 'comment_response' || true)

    assert_eq \
        "comment_response is present in _ALL_PHASES declaration" \
        "comment_response" \
        "$phases_found"
}

# ---------------------------------------------------------------------------
# Test 2: comment_response appears after ci_trigger in _ALL_PHASES
#
# Given: _ALL_PHASES is declared in merge-to-main-direct.sh
# When:  the phase ordering is inspected
# Then:  "comment_response" comes after "ci_trigger" in the ordered list
#        (the resume logic iterates _ALL_PHASES in order; comment_response
#        must be the phase that runs after ci_trigger completes)
# ---------------------------------------------------------------------------
test_comment_response_ordered_after_ci_trigger() {
    local phases_line
    phases_line=$(grep -E '^_ALL_PHASES=' "$DIRECT_SCRIPT" 2>/dev/null || true)

    # Convert the bash array literal to a newline-separated list of phase names
    # by stripping the assignment prefix/suffix and splitting on whitespace
    local phases_list
    phases_list=$(echo "$phases_line" \
        | sed 's/_ALL_PHASES=(//' \
        | sed 's/)//' \
        | tr ' ' '\n' \
        | grep -v '^$' || true)

    local found_ci_trigger=false
    local found_comment_response_after_ci=false
    while IFS= read -r phase; do
        if [[ "$found_ci_trigger" == "true" && "$phase" == "comment_response" ]]; then
            found_comment_response_after_ci=true
            break
        fi
        if [[ "$phase" == "ci_trigger" ]]; then
            found_ci_trigger=true
        fi
    done <<< "$phases_list"

    assert_eq \
        "comment_response is ordered after ci_trigger in _ALL_PHASES" \
        "true" \
        "$found_comment_response_after_ci"
}

# ---------------------------------------------------------------------------
# Test 3: _phase_comment_response is a callable function in direct mode
#
# Given: merge-to-main-direct.sh is sourced in library mode
#        (MERGE_TO_MAIN_DIRECT_LIB=1 suppresses CLI side effects)
# When:  the shell is queried for the _phase_comment_response function
# Then:  the function is defined and callable
#
# Note: lib mode sources only the function definitions (lines before the lib
# guard at ~line 840). _phase_comment_response must be defined BEFORE that
# guard so it is available in lib mode — matching the pattern for other
# _phase_* functions (_phase_sync, _phase_merge, _phase_ci_trigger, etc.).
# ---------------------------------------------------------------------------
test_phase_comment_response_callable_in_lib_mode() {
    local is_callable
    is_callable=$(
        # Subshell: source the script in lib mode and check if the function exists.
        # MERGE_TO_MAIN_DIRECT_LIB=1 causes the script to return after defining
        # all phase functions without executing CLI parsing or worktree checks.
        # Suppress all output from sourcing (errors from unset env vars, etc.)
        (
            export MERGE_TO_MAIN_DIRECT_LIB=1
            # shellcheck disable=SC1090
            source "$DIRECT_SCRIPT" 2>/dev/null || true
            if type _phase_comment_response >/dev/null 2>&1; then
                echo "callable"
            else
                echo "not_callable"
            fi
        )
    )

    assert_eq \
        "_phase_comment_response is defined when direct.sh sourced in lib mode" \
        "callable" \
        "$is_callable"
}

# ---------------------------------------------------------------------------
# Test 4: _phase_comment_response is defined in merge-to-main-pr.sh
#
# Given: merge-to-main-pr.sh is the PR-mode entry point that drives the full
#        PR merge workflow
# When:  the script is inspected for a _phase_comment_response definition
# Then:  a function definition exists (the PR path must also handle comment
#        response so the phase runs whether the user is in direct or PR mode)
#
# REVIEW-DEFENSE: sourcing merge-to-main-pr.sh in a test environment requires
# shimming gh, git, and state-file infrastructure that the script initialises
# at top level. The structural assertion (function definition present) is
# proportionate for a boundary check — the callable-in-lib-mode test (Test 3)
# already covers the behavioral contract for direct mode.
# ---------------------------------------------------------------------------
test_phase_comment_response_defined_in_pr_script() {
    local definition_found
    definition_found=$(grep -c '^_phase_comment_response()' "$PR_SCRIPT" 2>/dev/null || true)

    assert_ne \
        "_phase_comment_response function definition present in merge-to-main-pr.sh" \
        "0" \
        "$definition_found"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_comment_response_in_all_phases
test_comment_response_ordered_after_ci_trigger
test_phase_comment_response_callable_in_lib_mode
test_phase_comment_response_defined_in_pr_script

print_summary
