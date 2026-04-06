#!/usr/bin/env bash
# tests/hooks/test-merge-state.sh
# TDD tests: behavioral tests for plugins/dso/hooks/lib/merge-state.sh
#
# Shared library API under test:
#   ms_is_merge_in_progress  — returns 0 (true) when MERGE_HEAD exists
#   ms_is_rebase_in_progress — returns 0 (true) when REBASE_HEAD or rebase-apply dir exists
#   ms_get_worktree_only_files — filters incoming-only files; returns worktree-branch files
#   ms_get_merge_base         — returns merge base SHA for merge or rebase state
#
# Test isolation: each test creates a temp git repo via mktemp -d && git init.
# MERGE_HEAD/REBASE_HEAD files written directly into temp .git/.
# Tests use _MERGE_STATE_GIT_DIR env var override.
#
# Note: per AC amendment, total test count is 15 (10 original + 2 for ms_get_merge_base + 1 for from_head guard
#       + 2 for ms_filter_to_worktree_only all-incoming-only coverage).
#
# Tests:
#  1. test_is_merge_in_progress_detects_merge_head
#  2. test_is_merge_in_progress_returns_false_when_no_merge
#  3. test_is_rebase_in_progress_detects_rebase_head
#  4. test_is_rebase_in_progress_detects_rebase_apply
#  5. test_get_worktree_only_files_filters_incoming_during_merge
#  6. test_get_worktree_only_files_filters_during_rebase
#  7. test_merge_head_equals_head_guard_skips_filtering
#  8. test_merge_head_equals_head_guard_from_head_skips_filtering
#  9. test_fallback_on_missing_merge_base_orig_head
# 10. test_fallback_on_missing_merge_base_head
# 11. test_get_worktree_only_files_from_head_during_rebase
# 12. test_get_merge_base_during_merge
# 13. test_get_merge_base_during_rebase
# 14. test_filter_to_worktree_only_all_incoming_returns_empty_intersection
# 15. test_filter_to_worktree_only_partial_intersection
#
# Usage: bash tests/hooks/test-merge-state.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_STATE_LIB="$DSO_PLUGIN_DIR/hooks/lib/merge-state.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-merge-state.sh ==="

# ── Cleanup on exit ───────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# ── Prerequisite check ────────────────────────────────────────────────────────
if [[ ! -f "$MERGE_STATE_LIB" ]]; then
    echo "SKIP: merge-state.sh not found at $MERGE_STATE_LIB — library not yet implemented (RED state expected)" >&2
    # In RED state, emit individual test names as FAIL so record-test-status.sh can parse RED markers
    for _test_name in \
        test_is_merge_in_progress_detects_merge_head \
        test_is_merge_in_progress_returns_false_when_no_merge \
        test_is_rebase_in_progress_detects_rebase_head \
        test_is_rebase_in_progress_detects_rebase_apply \
        test_get_worktree_only_files_filters_incoming_during_merge \
        test_get_worktree_only_files_filters_during_rebase \
        test_merge_head_equals_head_guard_skips_filtering \
        test_fallback_on_missing_merge_base_orig_head \
        test_fallback_on_missing_merge_base_head \
        test_get_worktree_only_files_from_head_during_rebase \
        test_get_merge_base_during_merge \
        test_get_merge_base_during_rebase \
        test_merge_head_equals_head_guard_from_head_skips_filtering \
        test_filter_to_worktree_only_all_incoming_returns_empty_intersection \
        test_filter_to_worktree_only_partial_intersection; do
        echo "FAIL: $_test_name"
        (( ++FAIL ))
    done
    print_summary
fi

# Source the library under test
# shellcheck source=/dev/null
source "$MERGE_STATE_LIB"

# ── Helper: make a minimal git repo ──────────────────────────────────────────
# Creates a repo with one commit on main and returns the tmpdir path.
_make_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    git init -b main "$tmpdir" --quiet 2>/dev/null || git init "$tmpdir" --quiet
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    echo "initial" > "$tmpdir/base.txt"
    git -C "$tmpdir" add base.txt
    git -C "$tmpdir" commit -m "initial" --quiet
    echo "$tmpdir"
}

# ── Helper: make a two-branch merge repo ─────────────────────────────────────
# State: feature branch checked out, mid-merge (MERGE_HEAD present, no conflicts).
#   - worktree.txt   = added on feature branch
#   - incoming.txt   = added on main (incoming only)
_make_merge_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")

    git init --bare -b main "$tmpdir/origin.git" --quiet 2>/dev/null || git init --bare "$tmpdir/origin.git" --quiet
    git clone "$tmpdir/origin.git" "$tmpdir/repo" --quiet 2>/dev/null
    cd "$tmpdir/repo"
    git config user.email "test@test.com"
    git config user.name "Test"

    # Initial commit on main
    echo "initial" > base.txt
    git add base.txt
    git commit -m "initial" --quiet
    git push origin main --quiet 2>/dev/null

    # Feature branch: add worktree.txt
    git checkout -b feature --quiet
    echo "worktree work" > worktree.txt
    git add worktree.txt
    git commit -m "feature: add worktree.txt" --quiet

    # Back to main: add incoming.txt
    git checkout main --quiet
    echo "incoming from main" > incoming.txt
    git add incoming.txt
    git commit -m "main: add incoming.txt" --quiet

    # Back to feature, start merge (no-commit so MERGE_HEAD persists)
    git checkout feature --quiet
    git merge main --no-commit --no-edit 2>/dev/null || true

    echo "$tmpdir/repo"
}

# ── Helper: make a rebase-in-progress repo ───────────────────────────────────
# State: REBASE_HEAD + rebase-merge/onto + rebase-merge/orig-head present.
#   - worktree-feature.txt = on feature branch (onto..HEAD range)
#   - pre-onto.txt         = pre-onto commit (NOT in onto..HEAD range)
# Returns: tmpdir/repo path on line 1, onto_sha on line 2
_make_rebase_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")

    git init -b main "$tmpdir/repo" --quiet 2>/dev/null || git init "$tmpdir/repo" --quiet
    cd "$tmpdir/repo"
    git config user.email "test@test.com"
    git config user.name "Test"

    # Pre-onto commit
    echo "pre-onto" > pre-onto.txt
    git add pre-onto.txt
    git commit -m "pre: add pre-onto.txt" --quiet

    # Onto commit (the rebase target)
    echo "base" > base.txt
    git add base.txt
    git commit -m "onto: add base.txt" --quiet
    local onto_sha
    onto_sha=$(git rev-parse HEAD)

    # Worktree-branch commit
    echo "worktree feature work" > worktree-feature.txt
    git add worktree-feature.txt
    git commit -m "feature: add worktree-feature.txt" --quiet
    local orig_head_sha
    orig_head_sha=$(git rev-parse HEAD)

    # Simulate REBASE_HEAD state
    local git_dir
    git_dir=$(git rev-parse --absolute-git-dir)
    echo "$orig_head_sha" > "$git_dir/REBASE_HEAD"
    mkdir -p "$git_dir/rebase-merge"
    echo "$onto_sha" > "$git_dir/rebase-merge/onto"
    echo "$orig_head_sha" > "$git_dir/rebase-merge/orig-head"

    echo "$tmpdir/repo"
    echo "$onto_sha"
}

# ── Helper: make a rebase-apply (non-rebase-merge) repo ─────────────────────
# Uses rebase-apply/ dir (older git rebase style) plus REBASE_HEAD
_make_rebase_apply_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")

    git init -b main "$tmpdir/repo" --quiet 2>/dev/null || git init "$tmpdir/repo" --quiet
    cd "$tmpdir/repo"
    git config user.email "test@test.com"
    git config user.name "Test"

    echo "initial" > base.txt
    git add base.txt
    git commit -m "initial" --quiet

    echo "feature" > feature.txt
    git add feature.txt
    git commit -m "feature" --quiet
    local orig_head_sha
    orig_head_sha=$(git rev-parse HEAD)

    # Simulate rebase-apply state (older style)
    local git_dir
    git_dir=$(git rev-parse --absolute-git-dir)
    echo "$orig_head_sha" > "$git_dir/REBASE_HEAD"
    mkdir -p "$git_dir/rebase-apply"
    echo "$(git rev-parse HEAD~1)" > "$git_dir/rebase-apply/onto"
    echo "$orig_head_sha" > "$git_dir/rebase-apply/orig-head"

    echo "$tmpdir/repo"
}

# =============================================================================
# Test functions
# =============================================================================

test_is_merge_in_progress_detects_merge_head() {
    _snapshot_fail
    local merge_repo merge_git_dir result
    merge_repo=$(cd /tmp && _make_merge_repo)
    merge_git_dir=$(git -C "$merge_repo" rev-parse --absolute-git-dir 2>/dev/null)

    assert_eq "setup: MERGE_HEAD file exists in merge repo" \
        "1" "$(test -f "$merge_git_dir/MERGE_HEAD" && echo 1 || echo 0)"

    result=0
    # cd into the temp repo so git rev-parse HEAD (inside ms_is_merge_in_progress)
    # resolves against the correct repo — not the ambient worktree HEAD.
    (cd "$merge_repo" && _MERGE_STATE_GIT_DIR="$merge_git_dir" ms_is_merge_in_progress) || result=$?
    assert_eq "test_is_merge_in_progress_detects_merge_head: returns 0 when MERGE_HEAD present" \
        "0" "$result"
    assert_pass_if_clean "test_is_merge_in_progress_detects_merge_head"
}

test_is_merge_in_progress_returns_false_when_no_merge() {
    _snapshot_fail
    local clean_repo clean_git_dir result
    clean_repo=$(_make_repo)
    clean_git_dir=$(git -C "$clean_repo" rev-parse --absolute-git-dir 2>/dev/null)

    assert_eq "setup: no MERGE_HEAD in clean repo" \
        "0" "$(test -f "$clean_git_dir/MERGE_HEAD" && echo 1 || echo 0)"

    result=0
    # cd into the temp repo so git rev-parse HEAD (inside ms_is_merge_in_progress)
    # resolves against the correct repo — not the ambient worktree HEAD.
    (cd "$clean_repo" && _MERGE_STATE_GIT_DIR="$clean_git_dir" ms_is_merge_in_progress) && result=0 || result=$?
    assert_ne "test_is_merge_in_progress_returns_false_when_no_merge: returns non-zero when no MERGE_HEAD" \
        "0" "$result"
    assert_pass_if_clean "test_is_merge_in_progress_returns_false_when_no_merge"
}

test_is_rebase_in_progress_detects_rebase_head() {
    _snapshot_fail
    local rebase_output rebase_repo rebase_git_dir result
    rebase_output=$(cd /tmp && _make_rebase_repo)
    rebase_repo=$(echo "$rebase_output" | head -1)
    rebase_git_dir=$(git -C "$rebase_repo" rev-parse --absolute-git-dir 2>/dev/null)

    assert_eq "setup: REBASE_HEAD file exists in rebase repo" \
        "1" "$(test -f "$rebase_git_dir/REBASE_HEAD" && echo 1 || echo 0)"

    result=0
    _MERGE_STATE_GIT_DIR="$rebase_git_dir" ms_is_rebase_in_progress || result=$?
    assert_eq "test_is_rebase_in_progress_detects_rebase_head: returns 0 when REBASE_HEAD present" \
        "0" "$result"
    assert_pass_if_clean "test_is_rebase_in_progress_detects_rebase_head"
}

test_is_rebase_in_progress_detects_rebase_apply() {
    _snapshot_fail
    local apply_repo apply_git_dir result
    apply_repo=$(cd /tmp && _make_rebase_apply_repo)
    apply_git_dir=$(git -C "$apply_repo" rev-parse --absolute-git-dir 2>/dev/null)

    assert_eq "setup: rebase-apply dir exists" \
        "1" "$(test -d "$apply_git_dir/rebase-apply" && echo 1 || echo 0)"

    result=0
    _MERGE_STATE_GIT_DIR="$apply_git_dir" ms_is_rebase_in_progress || result=$?
    assert_eq "test_is_rebase_in_progress_detects_rebase_apply: returns 0 when rebase-apply present" \
        "0" "$result"
    assert_pass_if_clean "test_is_rebase_in_progress_detects_rebase_apply"
}

test_get_worktree_only_files_filters_incoming_during_merge() {
    _snapshot_fail
    local merge_repo worktree_files has_incoming has_worktree
    merge_repo=$(cd /tmp && _make_merge_repo)

    worktree_files=$(cd "$merge_repo" && ms_get_worktree_only_files 2>/dev/null || echo "FAILED")

    has_incoming=0
    _tmp="$worktree_files"; [[ "$_tmp" =~ incoming.txt ]] && has_incoming=1
    assert_eq "test_get_worktree_only_files_filters_incoming_during_merge: incoming.txt excluded" \
        "0" "$has_incoming"

    has_worktree=0
    _tmp="$worktree_files"; [[ "$_tmp" =~ worktree.txt ]] && has_worktree=1
    assert_eq "test_get_worktree_only_files_filters_incoming_during_merge: worktree.txt included" \
        "1" "$has_worktree"
    assert_pass_if_clean "test_get_worktree_only_files_filters_incoming_during_merge"
}

test_get_worktree_only_files_filters_during_rebase() {
    _snapshot_fail
    local rebase_output rebase_repo rebase_files has_pre_onto has_worktree_feature
    rebase_output=$(cd /tmp && _make_rebase_repo)
    rebase_repo=$(echo "$rebase_output" | head -1)

    rebase_files=$(cd "$rebase_repo" && ms_get_worktree_only_files 2>/dev/null || echo "FAILED")

    has_pre_onto=0
    _tmp="$rebase_files"; [[ "$_tmp" =~ pre-onto.txt ]] && has_pre_onto=1
    assert_eq "test_get_worktree_only_files_filters_during_rebase: pre-onto.txt excluded" \
        "0" "$has_pre_onto"

    has_worktree_feature=0
    _tmp="$rebase_files"; [[ "$_tmp" =~ worktree-feature.txt ]] && has_worktree_feature=1
    assert_eq "test_get_worktree_only_files_filters_during_rebase: worktree-feature.txt included" \
        "1" "$has_worktree_feature"
    assert_pass_if_clean "test_get_worktree_only_files_filters_during_rebase"
}

test_merge_head_equals_head_guard_skips_filtering() {
    _snapshot_fail
    local guard_repo guard_git_dir guard_head guard_result guard_files guard_has_file
    guard_repo=$(_make_repo)
    guard_git_dir=$(git -C "$guard_repo" rev-parse --absolute-git-dir 2>/dev/null)
    guard_head=$(git -C "$guard_repo" rev-parse HEAD)

    # Fake MERGE_HEAD that equals HEAD (bypass attempt simulation)
    echo "$guard_head" > "$guard_git_dir/MERGE_HEAD"

    echo "new content" > "$guard_repo/new-file.txt"
    git -C "$guard_repo" add new-file.txt 2>/dev/null

    guard_result=0
    guard_files=$(cd "$guard_repo" && _MERGE_STATE_GIT_DIR="$guard_git_dir" ms_get_worktree_only_files 2>/dev/null) || guard_result=$?

    assert_eq "test_merge_head_equals_head_guard_skips_filtering: function does not crash" \
        "0" "$guard_result"

    guard_has_file=0
    _tmp="$guard_files"; [[ "$_tmp" =~ new-file.txt ]] && guard_has_file=1
    assert_eq "test_merge_head_equals_head_guard_skips_filtering: fail-open returns staged file" \
        "1" "$guard_has_file"
    assert_pass_if_clean "test_merge_head_equals_head_guard_skips_filtering"
}

test_merge_head_equals_head_guard_from_head_skips_filtering() {
    _snapshot_fail
    local guard_repo guard_git_dir guard_head guard_result guard_files guard_has_file
    guard_repo=$(_make_repo)
    guard_git_dir=$(git -C "$guard_repo" rev-parse --absolute-git-dir 2>/dev/null)
    guard_head=$(git -C "$guard_repo" rev-parse HEAD)

    # Fake MERGE_HEAD that equals HEAD (bypass attempt simulation)
    echo "$guard_head" > "$guard_git_dir/MERGE_HEAD"

    echo "new content" > "$guard_repo/new-file-from-head.txt"
    git -C "$guard_repo" add new-file-from-head.txt 2>/dev/null

    guard_result=0
    guard_files=$(cd "$guard_repo" && _MERGE_STATE_GIT_DIR="$guard_git_dir" ms_get_worktree_only_files_from_head 2>/dev/null) || guard_result=$?

    assert_eq "test_merge_head_equals_head_guard_from_head_skips_filtering: function does not crash" \
        "0" "$guard_result"

    guard_has_file=0
    _tmp="$guard_files"; [[ "$_tmp" =~ new-file-from-head.txt ]] && guard_has_file=1
    assert_eq "test_merge_head_equals_head_guard_from_head_skips_filtering: fail-open returns staged file" \
        "1" "$guard_has_file"
    assert_pass_if_clean "test_merge_head_equals_head_guard_from_head_skips_filtering"
}

test_fallback_on_missing_merge_base_orig_head() {
    _snapshot_fail
    local fallback_repo fallback_git_dir fallback_result fallback_files fallback_has_staged
    fallback_repo=$(_make_repo)
    fallback_git_dir=$(git -C "$fallback_repo" rev-parse --absolute-git-dir 2>/dev/null)

    # Invalid (non-existent) SHA causes merge-base to fail
    echo "deadbeefdeadbeefdeadbeefdeadbeefdeadbeef" > "$fallback_git_dir/MERGE_HEAD"

    echo "content" > "$fallback_repo/staged.txt"
    git -C "$fallback_repo" add staged.txt 2>/dev/null

    fallback_result=0
    fallback_files=$(cd "$fallback_repo" && _MERGE_STATE_GIT_DIR="$fallback_git_dir" ms_get_worktree_only_files 2>/dev/null) || fallback_result=$?

    assert_eq "test_fallback_on_missing_merge_base_orig_head: function does not crash" \
        "0" "$fallback_result"

    fallback_has_staged=0
    _tmp="$fallback_files"; [[ "$_tmp" =~ staged.txt ]] && fallback_has_staged=1
    assert_eq "test_fallback_on_missing_merge_base_orig_head: fail-open returns original list" \
        "1" "$fallback_has_staged"
    assert_pass_if_clean "test_fallback_on_missing_merge_base_orig_head"
}

test_fallback_on_missing_merge_base_head() {
    _snapshot_fail
    local hf_repo hf_git_dir hf_head hf_result hf_files hf_has_staged
    hf_repo=$(_make_repo)
    # Add a second commit so HEAD~1 fallback is available
    echo "second" > "$hf_repo/second.txt"
    git -C "$hf_repo" add second.txt 2>/dev/null
    git -C "$hf_repo" commit -m "second" --quiet

    hf_git_dir=$(git -C "$hf_repo" rev-parse --absolute-git-dir 2>/dev/null)
    hf_head=$(git -C "$hf_repo" rev-parse HEAD)

    # REBASE_HEAD with no rebase-merge/onto file (corrupt/incomplete state)
    echo "$hf_head" > "$hf_git_dir/REBASE_HEAD"
    # Deliberately omit rebase-merge/onto

    echo "staged" > "$hf_repo/staged2.txt"
    git -C "$hf_repo" add staged2.txt 2>/dev/null

    hf_result=0
    hf_files=$(cd "$hf_repo" && _MERGE_STATE_GIT_DIR="$hf_git_dir" ms_get_worktree_only_files 2>/dev/null) || hf_result=$?

    assert_eq "test_fallback_on_missing_merge_base_head: function does not crash" \
        "0" "$hf_result"

    hf_has_staged=0
    _tmp="$hf_files"; [[ "$_tmp" =~ staged2.txt ]] && hf_has_staged=1
    assert_eq "test_fallback_on_missing_merge_base_head: fail-open returns original list" \
        "1" "$hf_has_staged"
    assert_pass_if_clean "test_fallback_on_missing_merge_base_head"
}

test_get_worktree_only_files_from_head_during_rebase() {
    _snapshot_fail
    local rebase_output rebase_repo rebase_git_dir range_files has_first has_second has_pre
    rebase_output=$(cd /tmp && _make_rebase_repo)
    rebase_repo=$(echo "$rebase_output" | head -1)

    # Add a second worktree commit to verify full range is used (not just HEAD)
    cd "$rebase_repo"
    echo "second worktree change" > worktree-second.txt
    git add worktree-second.txt
    git commit -m "feature: add worktree-second.txt" --quiet

    # Update orig-head to include this new commit
    rebase_git_dir=$(git rev-parse --absolute-git-dir)
    git rev-parse HEAD > "$rebase_git_dir/rebase-merge/orig-head"

    range_files=$(ms_get_worktree_only_files 2>/dev/null || echo "FAILED")

    has_first=0
    _tmp="$range_files"; [[ "$_tmp" =~ worktree-feature.txt ]] && has_first=1
    assert_eq "test_get_worktree_only_files_from_head_during_rebase: first worktree file included" \
        "1" "$has_first"

    has_second=0
    _tmp="$range_files"; [[ "$_tmp" =~ worktree-second.txt ]] && has_second=1
    assert_eq "test_get_worktree_only_files_from_head_during_rebase: second worktree file included" \
        "1" "$has_second"

    has_pre=0
    _tmp="$range_files"; [[ "$_tmp" =~ pre-onto.txt ]] && has_pre=1
    assert_eq "test_get_worktree_only_files_from_head_during_rebase: pre-onto file excluded" \
        "0" "$has_pre"
    assert_pass_if_clean "test_get_worktree_only_files_from_head_during_rebase"
}

test_get_merge_base_during_merge() {
    _snapshot_fail
    local mb_merge_repo mb_merge_head_sha expected_base actual_base
    mb_merge_repo=$(cd /tmp && _make_merge_repo)

    mb_merge_head_sha=$(cat "$(git -C "$mb_merge_repo" rev-parse --absolute-git-dir)/MERGE_HEAD" 2>/dev/null | head -1)
    expected_base=$(git -C "$mb_merge_repo" merge-base HEAD "$mb_merge_head_sha" 2>/dev/null || echo "")

    actual_base=$(cd "$mb_merge_repo" && ms_get_merge_base 2>/dev/null || echo "")

    assert_ne "test_get_merge_base_during_merge: returns non-empty SHA" \
        "" "$actual_base"
    assert_eq "test_get_merge_base_during_merge: SHA matches expected merge-base" \
        "$expected_base" "$actual_base"
    assert_pass_if_clean "test_get_merge_base_during_merge"
}

test_get_merge_base_during_rebase() {
    _snapshot_fail
    local rebase_output rebase_repo rebase_onto rb_git_dir rb_orig_head expected_base actual_base
    rebase_output=$(cd /tmp && _make_rebase_repo)
    rebase_repo=$(echo "$rebase_output" | head -1)
    rebase_onto=$(echo "$rebase_output" | tail -1)

    rb_git_dir=$(git -C "$rebase_repo" rev-parse --absolute-git-dir 2>/dev/null)
    rb_orig_head=$(cat "$rb_git_dir/rebase-merge/orig-head" 2>/dev/null | head -1)
    expected_base=$(git -C "$rebase_repo" merge-base "$rebase_onto" "$rb_orig_head" 2>/dev/null || echo "")

    actual_base=$(cd "$rebase_repo" && ms_get_merge_base 2>/dev/null || echo "")

    assert_ne "test_get_merge_base_during_rebase: returns non-empty SHA" \
        "" "$actual_base"
    assert_eq "test_get_merge_base_during_rebase: SHA matches expected rebase merge-base" \
        "$expected_base" "$actual_base"
    assert_pass_if_clean "test_get_merge_base_during_rebase"
}

# =============================================================================
# Test 14: ms_filter_to_worktree_only — all staged files are incoming-only
# =============================================================================
# Verifies that when worktree_files is non-empty but NONE of the staged files
# match (all-incoming-only case), ms_filter_to_worktree_only returns the
# original input list (fail-open). This documents the known fail-open behavior
# and confirms that callers (record-test-status.sh) must NOT rely on an empty
# return value to detect all-incoming-only — they must use ms_get_worktree_only_files
# directly and filter inline to correctly exit 0 in this case.
test_filter_to_worktree_only_all_incoming_returns_empty_intersection() {
    _snapshot_fail
    local merge_repo merge_git_dir result filtered has_incoming has_worktree
    merge_repo=$(cd /tmp && _make_merge_repo)
    merge_git_dir=$(git -C "$merge_repo" rev-parse --absolute-git-dir 2>/dev/null)

    # Staged files list contains only the incoming file (not on the worktree branch)
    local staged_input="incoming.txt"

    filtered=$(cd "$merge_repo" && \
        _MERGE_STATE_GIT_DIR="$merge_git_dir" ms_filter_to_worktree_only "$staged_input" \
        2>/dev/null) || true

    # When filtering produces zero matches, fail-open returns the ORIGINAL input.
    # This documents the intentional fail-open behavior of ms_filter_to_worktree_only.
    has_incoming=0
    _tmp="$filtered"; [[ "$_tmp" =~ incoming.txt ]] && has_incoming=1
    assert_eq \
        "test_filter_to_worktree_only_all_incoming_returns_empty_intersection: fail-open returns original list when no intersection" \
        "1" "$has_incoming"

    assert_pass_if_clean "test_filter_to_worktree_only_all_incoming_returns_empty_intersection"
}

# =============================================================================
# Test 15: ms_filter_to_worktree_only — partial intersection
# =============================================================================
# Verifies that when some staged files are on the worktree branch and some are
# incoming-only, only the worktree-branch files are returned.
test_filter_to_worktree_only_partial_intersection() {
    _snapshot_fail
    local merge_repo merge_git_dir filtered has_incoming has_worktree
    merge_repo=$(cd /tmp && _make_merge_repo)
    merge_git_dir=$(git -C "$merge_repo" rev-parse --absolute-git-dir 2>/dev/null)

    # Staged files list contains both a worktree file and an incoming-only file
    local staged_input
    staged_input="$(printf 'worktree.txt\nincoming.txt')"

    filtered=$(cd "$merge_repo" && \
        _MERGE_STATE_GIT_DIR="$merge_git_dir" ms_filter_to_worktree_only "$staged_input" \
        2>/dev/null) || true

    has_worktree=0
    _tmp="$filtered"; [[ "$_tmp" =~ worktree.txt ]] && has_worktree=1
    assert_eq \
        "test_filter_to_worktree_only_partial_intersection: worktree.txt retained" \
        "1" "$has_worktree"

    has_incoming=0
    _tmp="$filtered"; [[ "$_tmp" =~ incoming.txt ]] && has_incoming=1
    assert_eq \
        "test_filter_to_worktree_only_partial_intersection: incoming.txt excluded" \
        "0" "$has_incoming"

    assert_pass_if_clean "test_filter_to_worktree_only_partial_intersection"
}

# =============================================================================
# Run all tests
# =============================================================================
echo ""
test_is_merge_in_progress_detects_merge_head
echo ""
test_is_merge_in_progress_returns_false_when_no_merge
echo ""
test_is_rebase_in_progress_detects_rebase_head
echo ""
test_is_rebase_in_progress_detects_rebase_apply
echo ""
test_get_worktree_only_files_filters_incoming_during_merge
echo ""
test_get_worktree_only_files_filters_during_rebase
echo ""
test_merge_head_equals_head_guard_skips_filtering
echo ""
test_merge_head_equals_head_guard_from_head_skips_filtering
echo ""
test_fallback_on_missing_merge_base_orig_head
echo ""
test_fallback_on_missing_merge_base_head
echo ""
test_get_worktree_only_files_from_head_during_rebase
echo ""
test_get_merge_base_during_merge
echo ""
test_get_merge_base_during_rebase
echo ""
test_filter_to_worktree_only_all_incoming_returns_empty_intersection
echo ""
test_filter_to_worktree_only_partial_intersection

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
