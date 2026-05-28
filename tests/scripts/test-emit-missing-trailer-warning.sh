#!/usr/bin/env bash
# tests/scripts/test-emit-missing-trailer-warning.sh
# Behavioral coverage for plugins/dso/scripts/emit-missing-trailer-warning.sh
# (cycle-2 llm-review finding 3/4: prior coverage was structural-only).
#
# Each test sets up a real git scratch repo with controlled commit history,
# invokes the helper with env vars matching a CI scenario, and asserts on
# the captured stdout (the warning lines GitHub Actions consumes).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
HELPER="$REPO_ROOT/plugins/dso/scripts/emit-missing-trailer-warning.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-emit-missing-trailer-warning.sh ==="

# --- Scratch git repo factory ----------------------------------------------

_make_repo() {
    local commits="$1"  # number of non-merge commits to put past origin/main
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/emit-warn-test.XXXXXX")
    (
        cd "$tmp" || exit 1
        git init -q -b main
        git config user.email "test@local"
        git config user.name "test"
        git commit -q --allow-empty -m "base"
        # Simulate an `origin` remote with origin/main pointing at the base.
        git update-ref refs/remotes/origin/main HEAD
        local i
        for (( i = 0; i < commits; i++ )); do
            git commit -q --allow-empty -m "story-${i}"
        done
    )
    echo "$tmp"
}

_run_helper() {
    # Args: scope_empty event_name base_ref head_ref [cwd]
    local scope="$1" event="$2" base="$3" head="$4" cwd="${5:-}"
    if [[ -n "$cwd" ]]; then
        ( cd "$cwd" && \
          SCOPE_EMPTY="$scope" EVENT_NAME="$event" BASE_REF="$base" HEAD_REF="$head" \
          bash "$HELPER" 2>&1 )
    else
        SCOPE_EMPTY="$scope" EVENT_NAME="$event" BASE_REF="$base" HEAD_REF="$head" \
          bash "$HELPER" 2>&1
    fi
}

# --- T1: push event does NOT emit (base_ref/head_ref empty) ----------------
echo "--- T1: push_event_suppressed ---"
repo=$(_make_repo 3)
out=$(_run_helper "true" "push" "" "" "$repo")
_snapshot_fail
if [[ -z "$out" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: T1 expected no output on push event, got: $out" >&2
fi
assert_pass_if_clean "T1_push_event_suppressed"
rm -rf "$repo"

# --- T2: pull_request, scope NOT empty → suppressed -------------------------
echo "--- T2: scope_not_empty_suppressed ---"
repo=$(_make_repo 3)
out=$(_run_helper "false" "pull_request" "main" "story/x" "$repo")
_snapshot_fail
if [[ -z "$out" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: T2 expected no output when SCOPE_EMPTY=false, got: $out" >&2
fi
assert_pass_if_clean "T2_scope_not_empty_suppressed"
rm -rf "$repo"

# --- T3: pull_request, empty base_ref → suppressed --------------------------
echo "--- T3: pr_empty_base_ref_suppressed ---"
repo=$(_make_repo 3)
out=$(_run_helper "true" "pull_request" "" "story/x" "$repo")
_snapshot_fail
if [[ -z "$out" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: T3 expected no output when BASE_REF empty, got: $out" >&2
fi
assert_pass_if_clean "T3_pr_empty_base_ref_suppressed"
rm -rf "$repo"

# --- T4: pull_request, multi-commit, scope empty → warning emitted ---------
echo "--- T4: multi_commit_emits_warning ---"
repo=$(_make_repo 3)
out=$(_run_helper "true" "pull_request" "main" "story/abc" "$repo")
assert_contains "T4_multi_commit_emits_warning" "::warning::No per-story DSO-Story-Merge trailers found on story/abc" "$out"
assert_contains "T4_multi_commit_cites_bug" "db71-e078-ec99-4fbf" "$out"
rm -rf "$repo"

# --- T5: pull_request, single commit, scope empty → no warning -------------
echo "--- T5: single_commit_no_warning ---"
repo=$(_make_repo 1)
out=$(_run_helper "true" "pull_request" "main" "story/abc" "$repo")
_snapshot_fail
if [[ -z "$out" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: T5 expected no warning for single-commit PR, got: $out" >&2
fi
assert_pass_if_clean "T5_single_commit_no_warning"
rm -rf "$repo"

# --- T6: git failure surfaces diagnostic warning, exits 0 ------------------
echo "--- T6: git_failure_surfaces_diagnostic ---"
repo=$(_make_repo 3)
# Reference a base ref that does NOT exist locally to force git log failure.
out=$(_run_helper "true" "pull_request" "nonexistent-branch" "story/abc" "$repo")
rc=$?
assert_eq "T6_helper_exits_zero_on_git_failure" "0" "$rc"
assert_contains "T6_diagnostic_warning_emitted" "::warning::Could not enumerate non-merge commits" "$out"
assert_contains "T6_diagnostic_cites_bug" "db71-e078-ec99-4fbf" "$out"
# Ensure the misleading "trailers found" warning is NOT also emitted —
# a git failure should produce exactly the diagnostic, nothing more.
_snapshot_fail
if [[ "$out" != *"No per-story DSO-Story-Merge trailers found"* ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: T6 should not emit primary warning when git failed" >&2
fi
assert_pass_if_clean "T6_no_primary_warning_on_git_failure"
rm -rf "$repo"

# --- T7: empty range (HEAD == origin/main) → no warning --------------------
echo "--- T7: empty_range_no_warning ---"
repo=$(_make_repo 0)
out=$(_run_helper "true" "pull_request" "main" "story/x" "$repo")
_snapshot_fail
if [[ -z "$out" ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: T7 expected no warning for empty range, got: $out" >&2
fi
assert_pass_if_clean "T7_empty_range_no_warning"
rm -rf "$repo"

print_summary
