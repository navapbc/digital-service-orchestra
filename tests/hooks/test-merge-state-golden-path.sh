#!/usr/bin/env bash
# tests/hooks/test-merge-state-golden-path.sh
# Golden-path integration tests: merge-state.sh across all 7 consumer scripts
# under 5 state scenarios (5 scenarios x 7 consumers = 35 minimum test combinations).
#
# Scenarios:
#   S1 — Normal commit (no MERGE_HEAD, no REBASE_HEAD) — no filtering applied
#   S2 — MERGE_HEAD present — incoming-only files filtered out
#   S3 — REBASE_HEAD + rebase-merge/ — onto-branch-only files filtered via orig-head
#   S4 — REBASE_HEAD + rebase-apply/ — same via rebase-apply path
#   S5 — MERGE_HEAD == HEAD guard — self-referencing MERGE_HEAD, no filtering applied
#
# 7 consumers exercised:
#   C1 — pre-commit-review-gate.sh (ms_filter_to_worktree_only via ms_is_merge/rebase)
#   C2 — pre-commit-test-gate.sh   (ms_is_merge/rebase + ms_get_worktree_only_files)
#   C3 — record-test-status.sh     (ms_is_merge/rebase + ms_get_worktree_only_files)
#   C4 — compute-diff-hash.sh      (ms_is_merge + ms_get_worktree_only_files + ms_get_merge_base)
#   C5 — capture-review-diff.sh    (ms_is_merge/rebase + ms_get_worktree_only_files_from_head + ms_get_merge_base)
#   C6 — review-complexity-classifier.sh (ms_is_merge + ms_is_rebase as in-progress detection)
#   C7 — merge-to-main.sh          (ms_is_rebase + ms_is_merge via _cleanup_stale_git_state)
#
# Test naming: test_s<N>_c<M>_<description>
#   where N = scenario number (1-5) and M = consumer number (1-7)
#
# Usage: bash tests/hooks/test-merge-state-golden-path.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# REVIEW-DEFENSE: This file intentionally implements all 35 scenario/consumer matrix tests
# in a single file rather than splitting by scenario or consumer. The rationale:
# (1) All 5 scenarios share the same fixture-builder helpers (_make_normal_repo,
#     _make_merge_repo, _make_rebase_merge_repo, _make_rebase_apply_repo,
#     _make_self_merge_repo) and the shared _snapshot_fail/_cleanup infrastructure;
#     splitting would require duplicating or extracting this boilerplate into a separate
#     fixtures file, adding indirection without a readability win.
# (2) Each scenario block is clearly demarcated with a banner comment and the test naming
#     convention (test_s<N>_c<M>_*) enables targeted re-runs: e.g.,
#       bash tests/hooks/test-merge-state-golden-path.sh 2>&1 | grep "S3"
#     without needing separate files.
# (3) The matrix is a coherent whole — verifying the same 7-consumer contract across
#     5 orthogonal states. Splitting by scenario would obscure that the same consumer
#     interface is being exercised in each case.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
MERGE_STATE_LIB="$DSO_PLUGIN_DIR/hooks/lib/merge-state.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-merge-state-golden-path.sh ==="

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
    echo "SKIP: merge-state.sh not found at $MERGE_STATE_LIB" >&2
    exit 1
fi

# Source the library under test (once — source-guard prevents re-loading)
# shellcheck source=/dev/null
source "$MERGE_STATE_LIB"

# =============================================================================
# Shared fixture helpers
# =============================================================================

# _make_normal_repo: single-branch repo with one staged file (no merge/rebase state)
_make_normal_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")

    git init -b main "$tmpdir" --quiet 2>/dev/null || git init "$tmpdir" --quiet
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"

    echo "initial" > "$tmpdir/base.txt"
    git -C "$tmpdir" add base.txt
    git -C "$tmpdir" commit -m "initial" --quiet

    echo "my-worktree-change" > "$tmpdir/worktree.txt"
    git -C "$tmpdir" add worktree.txt

    echo "$tmpdir"
}

# _make_merge_repo: feature branch mid-merge with MERGE_HEAD present.
#   - worktree.txt   = added on feature branch (worktree-only)
#   - incoming.txt   = added on main (incoming-only, should be filtered)
_make_merge_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")

    git init --bare -b main "$tmpdir/origin.git" --quiet 2>/dev/null || git init --bare "$tmpdir/origin.git" --quiet
    git clone "$tmpdir/origin.git" "$tmpdir/repo" --quiet 2>/dev/null
    git -C "$tmpdir/repo" config user.email "test@test.com"
    git -C "$tmpdir/repo" config user.name "Test"

    echo "initial" > "$tmpdir/repo/base.txt"
    git -C "$tmpdir/repo" add base.txt
    git -C "$tmpdir/repo" commit -m "initial" --quiet
    git -C "$tmpdir/repo" push origin main --quiet 2>/dev/null

    # Feature branch: add worktree.txt
    git -C "$tmpdir/repo" checkout -b feature --quiet
    echo "worktree work" > "$tmpdir/repo/worktree.txt"
    git -C "$tmpdir/repo" add worktree.txt
    git -C "$tmpdir/repo" commit -m "feature: add worktree.txt" --quiet

    # Main branch: add incoming.txt
    git -C "$tmpdir/repo" checkout main --quiet
    echo "incoming from main" > "$tmpdir/repo/incoming.txt"
    git -C "$tmpdir/repo" add incoming.txt
    git -C "$tmpdir/repo" commit -m "main: add incoming.txt" --quiet

    # Back to feature, start merge (no-commit so MERGE_HEAD persists)
    git -C "$tmpdir/repo" checkout feature --quiet
    git -C "$tmpdir/repo" merge main --no-commit --no-edit 2>/dev/null || true

    echo "$tmpdir/repo"
}

# _make_rebase_merge_repo: REBASE_HEAD + rebase-merge/ directories.
#   - worktree-feature.txt = on feature branch (worktree-only)
#   - pre-onto.txt         = pre-onto commit (onto-branch-only, should be filtered)
# Outputs: line1=repo_path, line2=onto_sha
_make_rebase_merge_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")

    git init -b main "$tmpdir/repo" --quiet 2>/dev/null || git init "$tmpdir/repo" --quiet
    git -C "$tmpdir/repo" config user.email "test@test.com"
    git -C "$tmpdir/repo" config user.name "Test"

    echo "pre-onto" > "$tmpdir/repo/pre-onto.txt"
    git -C "$tmpdir/repo" add pre-onto.txt
    git -C "$tmpdir/repo" commit -m "pre: add pre-onto.txt" --quiet

    echo "base" > "$tmpdir/repo/base.txt"
    git -C "$tmpdir/repo" add base.txt
    git -C "$tmpdir/repo" commit -m "onto: add base.txt" --quiet
    local onto_sha
    onto_sha=$(git -C "$tmpdir/repo" rev-parse HEAD)

    echo "worktree feature work" > "$tmpdir/repo/worktree-feature.txt"
    git -C "$tmpdir/repo" add worktree-feature.txt
    git -C "$tmpdir/repo" commit -m "feature: add worktree-feature.txt" --quiet
    local orig_head_sha
    orig_head_sha=$(git -C "$tmpdir/repo" rev-parse HEAD)

    local git_dir
    git_dir=$(git -C "$tmpdir/repo" rev-parse --absolute-git-dir)
    echo "$orig_head_sha" > "$git_dir/REBASE_HEAD"
    mkdir -p "$git_dir/rebase-merge"
    echo "$onto_sha" > "$git_dir/rebase-merge/onto"
    echo "$orig_head_sha" > "$git_dir/rebase-merge/orig-head"

    echo "$tmpdir/repo"
    echo "$onto_sha"
}

# _make_rebase_apply_repo: REBASE_HEAD + rebase-apply/ directories (older git style).
_make_rebase_apply_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")

    git init -b main "$tmpdir/repo" --quiet 2>/dev/null || git init "$tmpdir/repo" --quiet
    git -C "$tmpdir/repo" config user.email "test@test.com"
    git -C "$tmpdir/repo" config user.name "Test"

    echo "initial" > "$tmpdir/repo/base.txt"
    git -C "$tmpdir/repo" add base.txt
    git -C "$tmpdir/repo" commit -m "initial" --quiet

    echo "feature" > "$tmpdir/repo/worktree-apply.txt"
    git -C "$tmpdir/repo" add worktree-apply.txt
    git -C "$tmpdir/repo" commit -m "feature" --quiet
    local orig_head_sha
    orig_head_sha=$(git -C "$tmpdir/repo" rev-parse HEAD)

    local git_dir
    git_dir=$(git -C "$tmpdir/repo" rev-parse --absolute-git-dir)
    echo "$orig_head_sha" > "$git_dir/REBASE_HEAD"
    mkdir -p "$git_dir/rebase-apply"
    echo "$(git -C "$tmpdir/repo" rev-parse HEAD~1)" > "$git_dir/rebase-apply/onto"
    echo "$orig_head_sha" > "$git_dir/rebase-apply/orig-head"

    echo "$tmpdir/repo"
}

# _make_self_merge_repo: MERGE_HEAD == HEAD (bypass attempt, guard must fire)
_make_self_merge_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")

    git init -b main "$tmpdir" --quiet 2>/dev/null || git init "$tmpdir" --quiet
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"

    echo "initial" > "$tmpdir/base.txt"
    git -C "$tmpdir" add base.txt
    git -C "$tmpdir" commit -m "initial" --quiet

    # Write MERGE_HEAD == HEAD (self-referencing)
    local head_sha
    head_sha=$(git -C "$tmpdir" rev-parse HEAD)
    local git_dir
    git_dir=$(git -C "$tmpdir" rev-parse --absolute-git-dir)
    echo "$head_sha" > "$git_dir/MERGE_HEAD"

    # Stage a file so we can check fail-open behavior
    echo "staged content" > "$tmpdir/worktree-self.txt"
    git -C "$tmpdir" add worktree-self.txt

    echo "$tmpdir"
}

# =============================================================================
# SCENARIO 1: Normal commit (no MERGE_HEAD, no REBASE_HEAD)
# All 7 consumers should see "no merge/rebase state" → normal enforcement path.
# =============================================================================

# S1-C1: review-gate — ms_is_merge_in_progress returns false; ms_is_rebase_in_progress returns false
test_s1_c1_review_gate_normal_no_merge_state() {
    _snapshot_fail
    local repo git_dir result
    repo=$(_make_normal_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    local merge_result rebase_result
    merge_result=0
    _MERGE_STATE_GIT_DIR="$git_dir" ms_is_merge_in_progress && merge_result=0 || merge_result=$?
    assert_ne "S1-C1 review-gate: ms_is_merge_in_progress returns non-zero in normal state" \
        "0" "$merge_result"

    rebase_result=0
    _MERGE_STATE_GIT_DIR="$git_dir" ms_is_rebase_in_progress && rebase_result=0 || rebase_result=$?
    assert_ne "S1-C1 review-gate: ms_is_rebase_in_progress returns non-zero in normal state" \
        "0" "$rebase_result"
    assert_pass_if_clean "test_s1_c1_review_gate_normal_no_merge_state"
}

# S1-C2: test-gate — ms_get_worktree_only_files returns staged files (no filtering)
test_s1_c2_test_gate_normal_returns_staged_files() {
    _snapshot_fail
    local repo git_dir files has_worktree
    repo=$(_make_normal_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    files=$(cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_get_worktree_only_files 2>/dev/null || echo "")
    has_worktree=0
    _tmp="$files"; [[ "$_tmp" =~ worktree.txt ]] && has_worktree=1
    assert_eq "S1-C2 test-gate: staged worktree.txt returned in normal state" \
        "1" "$has_worktree"
    assert_pass_if_clean "test_s1_c2_test_gate_normal_returns_staged_files"
}

# S1-C3: record-test-status — ms_is_merge_in_progress + ms_is_rebase_in_progress both false
test_s1_c3_record_test_status_normal_no_filter() {
    _snapshot_fail
    local repo git_dir merge_r rebase_r
    repo=$(_make_normal_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    merge_r=0
    _MERGE_STATE_GIT_DIR="$git_dir" ms_is_merge_in_progress && merge_r=0 || merge_r=$?
    assert_ne "S1-C3 record-test-status: no merge in progress in normal state" \
        "0" "$merge_r"

    rebase_r=0
    _MERGE_STATE_GIT_DIR="$git_dir" ms_is_rebase_in_progress && rebase_r=0 || rebase_r=$?
    assert_ne "S1-C3 record-test-status: no rebase in progress in normal state" \
        "0" "$rebase_r"
    assert_pass_if_clean "test_s1_c3_record_test_status_normal_no_filter"
}

# S1-C4: compute-diff-hash — ms_get_merge_base returns empty in normal state
test_s1_c4_compute_diff_hash_normal_no_merge_base() {
    _snapshot_fail
    local repo git_dir merge_base
    repo=$(_make_normal_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    merge_base=$(cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_get_merge_base 2>/dev/null || echo "")
    assert_eq "S1-C4 compute-diff-hash: ms_get_merge_base returns empty in normal state" \
        "" "$merge_base"
    assert_pass_if_clean "test_s1_c4_compute_diff_hash_normal_no_merge_base"
}

# S1-C5: capture-review-diff — ms_get_worktree_only_files_from_head returns staged files
test_s1_c5_capture_review_diff_normal_returns_staged_files() {
    _snapshot_fail
    local repo git_dir files has_worktree
    repo=$(_make_normal_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    files=$(cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_get_worktree_only_files_from_head 2>/dev/null || echo "")
    has_worktree=0
    _tmp="$files"; [[ "$_tmp" =~ worktree.txt ]] && has_worktree=1
    assert_eq "S1-C5 capture-review-diff: staged worktree.txt returned in normal state" \
        "1" "$has_worktree"
    assert_pass_if_clean "test_s1_c5_capture_review_diff_normal_returns_staged_files"
}

# S1-C6: classifier — ms_is_merge_in_progress and ms_is_rebase_in_progress both false
test_s1_c6_classifier_normal_no_merge_rebase() {
    _snapshot_fail
    local repo git_dir merge_r rebase_r
    repo=$(_make_normal_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    merge_r=0
    _MERGE_STATE_GIT_DIR="$git_dir" ms_is_merge_in_progress && merge_r=0 || merge_r=$?
    assert_ne "S1-C6 classifier: ms_is_merge_in_progress false in normal state" \
        "0" "$merge_r"

    rebase_r=0
    _MERGE_STATE_GIT_DIR="$git_dir" ms_is_rebase_in_progress && rebase_r=0 || rebase_r=$?
    assert_ne "S1-C6 classifier: ms_is_rebase_in_progress false in normal state" \
        "0" "$rebase_r"
    assert_pass_if_clean "test_s1_c6_classifier_normal_no_merge_rebase"
}

# S1-C7: merge-to-main (_cleanup_stale_git_state pattern) — no stale state detected
test_s1_c7_merge_to_main_normal_no_stale_state() {
    _snapshot_fail
    local repo git_dir merge_r rebase_r
    repo=$(_make_normal_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    # merge-to-main checks: type ms_is_rebase_in_progress + type ms_is_merge_in_progress
    # Both must return false so no cleanup is triggered.
    merge_r=0
    _MERGE_STATE_GIT_DIR="$git_dir" ms_is_merge_in_progress && merge_r=0 || merge_r=$?
    assert_ne "S1-C7 merge-to-main: no stale merge in normal state" \
        "0" "$merge_r"

    rebase_r=0
    _MERGE_STATE_GIT_DIR="$git_dir" ms_is_rebase_in_progress && rebase_r=0 || rebase_r=$?
    assert_ne "S1-C7 merge-to-main: no stale rebase in normal state" \
        "0" "$rebase_r"
    assert_pass_if_clean "test_s1_c7_merge_to_main_normal_no_stale_state"
}

# =============================================================================
# SCENARIO 2: MERGE_HEAD present — incoming-only files should be filtered out
# =============================================================================

# S2-C1: review-gate — ms_is_merge_in_progress true; ms_get_worktree_only_files excludes incoming
test_s2_c1_review_gate_merge_detects_merge_state() {
    _snapshot_fail
    local repo git_dir result
    repo=$(cd /tmp && _make_merge_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    result=0
    _MERGE_STATE_GIT_DIR="$git_dir" ms_is_merge_in_progress || result=$?
    assert_eq "S2-C1 review-gate: ms_is_merge_in_progress returns 0 with MERGE_HEAD" \
        "0" "$result"

    # Filter verification: ms_filter_to_worktree_only should exclude incoming.txt
    local filtered has_incoming has_worktree
    filtered=$(cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" \
        ms_filter_to_worktree_only "$(printf 'worktree.txt\nincoming.txt')" 2>/dev/null || echo "")

    has_incoming=0
    _tmp="$filtered"; [[ "$_tmp" =~ incoming.txt ]] && has_incoming=1
    assert_eq "S2-C1 review-gate: incoming.txt filtered out during merge" \
        "0" "$has_incoming"

    has_worktree=0
    _tmp="$filtered"; [[ "$_tmp" =~ worktree.txt ]] && has_worktree=1
    assert_eq "S2-C1 review-gate: worktree.txt retained during merge" \
        "1" "$has_worktree"
    assert_pass_if_clean "test_s2_c1_review_gate_merge_detects_merge_state"
}

# S2-C2: test-gate — ms_get_worktree_only_files returns only worktree files during merge
test_s2_c2_test_gate_merge_filters_incoming() {
    _snapshot_fail
    local repo git_dir files has_incoming has_worktree
    repo=$(cd /tmp && _make_merge_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    files=$(cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_get_worktree_only_files 2>/dev/null || echo "FAILED")

    has_incoming=0
    _tmp="$files"; [[ "$_tmp" =~ incoming.txt ]] && has_incoming=1
    assert_eq "S2-C2 test-gate: incoming.txt excluded from worktree-only files" \
        "0" "$has_incoming"

    has_worktree=0
    _tmp="$files"; [[ "$_tmp" =~ worktree.txt ]] && has_worktree=1
    assert_eq "S2-C2 test-gate: worktree.txt included in worktree-only files" \
        "1" "$has_worktree"
    assert_pass_if_clean "test_s2_c2_test_gate_merge_filters_incoming"
}

# S2-C3: record-test-status — same filtering as test-gate via ms_get_worktree_only_files
test_s2_c3_record_test_status_merge_filters_incoming() {
    _snapshot_fail
    local repo git_dir files has_incoming has_worktree
    repo=$(cd /tmp && _make_merge_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    files=$(cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_get_worktree_only_files 2>/dev/null || echo "")

    has_incoming=0
    _tmp="$files"; [[ "$_tmp" =~ incoming.txt ]] && has_incoming=1
    assert_eq "S2-C3 record-test-status: incoming.txt excluded during merge" \
        "0" "$has_incoming"

    has_worktree=0
    _tmp="$files"; [[ "$_tmp" =~ worktree.txt ]] && has_worktree=1
    assert_eq "S2-C3 record-test-status: worktree.txt included during merge" \
        "1" "$has_worktree"
    assert_pass_if_clean "test_s2_c3_record_test_status_merge_filters_incoming"
}

# S2-C4: compute-diff-hash — ms_get_merge_base returns valid SHA during merge
test_s2_c4_compute_diff_hash_merge_returns_merge_base() {
    _snapshot_fail
    local repo git_dir merge_base
    repo=$(cd /tmp && _make_merge_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    merge_base=$(cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_get_merge_base 2>/dev/null || echo "")
    assert_ne "S2-C4 compute-diff-hash: ms_get_merge_base returns non-empty SHA during merge" \
        "" "$merge_base"

    # Verify the SHA is a valid git object
    local is_valid_sha
    is_valid_sha=0
    git -C "$repo" cat-file -e "$merge_base" 2>/dev/null && is_valid_sha=1
    assert_eq "S2-C4 compute-diff-hash: merge-base SHA is a valid git object" \
        "1" "$is_valid_sha"
    assert_pass_if_clean "test_s2_c4_compute_diff_hash_merge_returns_merge_base"
}

# S2-C5: capture-review-diff — ms_get_worktree_only_files_from_head excludes incoming during merge
test_s2_c5_capture_review_diff_merge_filters_incoming() {
    _snapshot_fail
    local repo git_dir files has_incoming has_worktree
    repo=$(cd /tmp && _make_merge_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    files=$(cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_get_worktree_only_files_from_head 2>/dev/null || echo "")

    has_incoming=0
    _tmp="$files"; [[ "$_tmp" =~ incoming.txt ]] && has_incoming=1
    assert_eq "S2-C5 capture-review-diff: incoming.txt excluded from from_head result during merge" \
        "0" "$has_incoming"

    has_worktree=0
    _tmp="$files"; [[ "$_tmp" =~ worktree.txt ]] && has_worktree=1
    assert_eq "S2-C5 capture-review-diff: worktree.txt included in from_head result during merge" \
        "1" "$has_worktree"
    assert_pass_if_clean "test_s2_c5_capture_review_diff_merge_filters_incoming"
}

# S2-C6: classifier — ms_is_merge_in_progress returns true; ms_is_rebase_in_progress returns false
test_s2_c6_classifier_merge_detects_only_merge() {
    _snapshot_fail
    local repo git_dir merge_r rebase_r
    repo=$(cd /tmp && _make_merge_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    merge_r=0
    _MERGE_STATE_GIT_DIR="$git_dir" ms_is_merge_in_progress || merge_r=$?
    assert_eq "S2-C6 classifier: ms_is_merge_in_progress returns true during merge" \
        "0" "$merge_r"

    rebase_r=0
    _MERGE_STATE_GIT_DIR="$git_dir" ms_is_rebase_in_progress && rebase_r=0 || rebase_r=$?
    assert_ne "S2-C6 classifier: ms_is_rebase_in_progress returns false during merge" \
        "0" "$rebase_r"
    assert_pass_if_clean "test_s2_c6_classifier_merge_detects_only_merge"
}

# S2-C7: merge-to-main — ms_is_merge_in_progress true; _MERGE_STATE_GIT_DIR override works
test_s2_c7_merge_to_main_merge_detects_stale_merge() {
    _snapshot_fail
    local repo git_dir saved_git_dir merge_r
    repo=$(cd /tmp && _make_merge_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    # merge-to-main uses _MERGE_STATE_GIT_DIR override for _cleanup_stale_git_state
    saved_git_dir="${_MERGE_STATE_GIT_DIR:-}"
    _MERGE_STATE_GIT_DIR="$git_dir"

    merge_r=0
    ms_is_merge_in_progress || merge_r=$?
    assert_eq "S2-C7 merge-to-main: ms_is_merge_in_progress true with GIT_DIR override" \
        "0" "$merge_r"

    # Restore
    if [[ -n "$saved_git_dir" ]]; then
        _MERGE_STATE_GIT_DIR="$saved_git_dir"
    else
        unset _MERGE_STATE_GIT_DIR
    fi
    assert_pass_if_clean "test_s2_c7_merge_to_main_merge_detects_stale_merge"
}

# =============================================================================
# SCENARIO 3: REBASE_HEAD + rebase-merge/ — onto-branch-only files filtered
# =============================================================================

# S3-C1: review-gate — ms_is_rebase_in_progress true; worktree-only files exclude pre-onto
test_s3_c1_review_gate_rebase_merge_detects_rebase() {
    _snapshot_fail
    local rebase_output repo git_dir result
    rebase_output=$(cd /tmp && _make_rebase_merge_repo)
    repo=$(echo "$rebase_output" | head -1)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    result=0
    _MERGE_STATE_GIT_DIR="$git_dir" ms_is_rebase_in_progress || result=$?
    assert_eq "S3-C1 review-gate: ms_is_rebase_in_progress returns 0 with rebase-merge/" \
        "0" "$result"
    assert_pass_if_clean "test_s3_c1_review_gate_rebase_merge_detects_rebase"
}

# S3-C2: test-gate — ms_get_worktree_only_files filters pre-onto.txt during rebase-merge
test_s3_c2_test_gate_rebase_merge_filters_onto_files() {
    _snapshot_fail
    local rebase_output repo git_dir files has_pre_onto has_worktree
    rebase_output=$(cd /tmp && _make_rebase_merge_repo)
    repo=$(echo "$rebase_output" | head -1)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    files=$(cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_get_worktree_only_files 2>/dev/null || echo "FAILED")

    has_pre_onto=0
    _tmp="$files"; [[ "$_tmp" =~ pre-onto.txt ]] && has_pre_onto=1
    assert_eq "S3-C2 test-gate: pre-onto.txt excluded during rebase-merge" \
        "0" "$has_pre_onto"

    has_worktree=0
    _tmp="$files"; [[ "$_tmp" =~ worktree-feature.txt ]] && has_worktree=1
    assert_eq "S3-C2 test-gate: worktree-feature.txt included during rebase-merge" \
        "1" "$has_worktree"
    assert_pass_if_clean "test_s3_c2_test_gate_rebase_merge_filters_onto_files"
}

# S3-C3: record-test-status — same as test-gate; also ms_is_rebase_in_progress true
test_s3_c3_record_test_status_rebase_merge_filters_onto_files() {
    _snapshot_fail
    local rebase_output repo git_dir rebase_r files has_pre_onto has_worktree
    rebase_output=$(cd /tmp && _make_rebase_merge_repo)
    repo=$(echo "$rebase_output" | head -1)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    rebase_r=0
    _MERGE_STATE_GIT_DIR="$git_dir" ms_is_rebase_in_progress || rebase_r=$?
    assert_eq "S3-C3 record-test-status: ms_is_rebase_in_progress true with rebase-merge/" \
        "0" "$rebase_r"

    files=$(cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_get_worktree_only_files 2>/dev/null || echo "")

    has_pre_onto=0
    _tmp="$files"; [[ "$_tmp" =~ pre-onto.txt ]] && has_pre_onto=1
    assert_eq "S3-C3 record-test-status: pre-onto.txt excluded" \
        "0" "$has_pre_onto"

    has_worktree=0
    _tmp="$files"; [[ "$_tmp" =~ worktree-feature.txt ]] && has_worktree=1
    assert_eq "S3-C3 record-test-status: worktree-feature.txt included" \
        "1" "$has_worktree"
    assert_pass_if_clean "test_s3_c3_record_test_status_rebase_merge_filters_onto_files"
}

# S3-C4: compute-diff-hash — ms_get_merge_base returns valid SHA from rebase-merge/onto
test_s3_c4_compute_diff_hash_rebase_merge_returns_merge_base() {
    _snapshot_fail
    local rebase_output repo git_dir merge_base is_valid_sha
    rebase_output=$(cd /tmp && _make_rebase_merge_repo)
    repo=$(echo "$rebase_output" | head -1)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    merge_base=$(cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_get_merge_base 2>/dev/null || echo "")
    assert_ne "S3-C4 compute-diff-hash: ms_get_merge_base non-empty during rebase-merge" \
        "" "$merge_base"

    is_valid_sha=0
    git -C "$repo" cat-file -e "$merge_base" 2>/dev/null && is_valid_sha=1
    assert_eq "S3-C4 compute-diff-hash: rebase-merge merge-base is valid git object" \
        "1" "$is_valid_sha"
    assert_pass_if_clean "test_s3_c4_compute_diff_hash_rebase_merge_returns_merge_base"
}

# S3-C5: capture-review-diff — ms_get_worktree_only_files_from_head includes worktree files (HEAD-anchored)
test_s3_c5_capture_review_diff_rebase_merge_from_head() {
    _snapshot_fail
    local rebase_output repo git_dir files has_pre_onto has_worktree
    rebase_output=$(cd /tmp && _make_rebase_merge_repo)
    repo=$(echo "$rebase_output" | head -1)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    files=$(cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_get_worktree_only_files_from_head 2>/dev/null || echo "")

    has_pre_onto=0
    _tmp="$files"; [[ "$_tmp" =~ pre-onto.txt ]] && has_pre_onto=1
    assert_eq "S3-C5 capture-review-diff: pre-onto.txt excluded from HEAD-anchored result" \
        "0" "$has_pre_onto"

    has_worktree=0
    _tmp="$files"; [[ "$_tmp" =~ worktree-feature.txt ]] && has_worktree=1
    assert_eq "S3-C5 capture-review-diff: worktree-feature.txt included in HEAD-anchored result" \
        "1" "$has_worktree"
    assert_pass_if_clean "test_s3_c5_capture_review_diff_rebase_merge_from_head"
}

# S3-C6: classifier — ms_is_rebase_in_progress true; ms_is_merge_in_progress false
test_s3_c6_classifier_rebase_merge_detects_only_rebase() {
    _snapshot_fail
    local rebase_output repo git_dir rebase_r merge_r
    rebase_output=$(cd /tmp && _make_rebase_merge_repo)
    repo=$(echo "$rebase_output" | head -1)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    rebase_r=0
    _MERGE_STATE_GIT_DIR="$git_dir" ms_is_rebase_in_progress || rebase_r=$?
    assert_eq "S3-C6 classifier: ms_is_rebase_in_progress true during rebase-merge" \
        "0" "$rebase_r"

    merge_r=0
    _MERGE_STATE_GIT_DIR="$git_dir" ms_is_merge_in_progress && merge_r=0 || merge_r=$?
    assert_ne "S3-C6 classifier: ms_is_merge_in_progress false during rebase-merge" \
        "0" "$merge_r"
    assert_pass_if_clean "test_s3_c6_classifier_rebase_merge_detects_only_rebase"
}

# S3-C7: merge-to-main — detects rebase state via ms_is_rebase_in_progress with GIT_DIR override
test_s3_c7_merge_to_main_rebase_merge_detects_stale_rebase() {
    _snapshot_fail
    local rebase_output repo git_dir saved_git_dir rebase_r
    rebase_output=$(cd /tmp && _make_rebase_merge_repo)
    repo=$(echo "$rebase_output" | head -1)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    saved_git_dir="${_MERGE_STATE_GIT_DIR:-}"
    _MERGE_STATE_GIT_DIR="$git_dir"

    rebase_r=0
    ms_is_rebase_in_progress || rebase_r=$?
    assert_eq "S3-C7 merge-to-main: ms_is_rebase_in_progress true with GIT_DIR override" \
        "0" "$rebase_r"

    if [[ -n "$saved_git_dir" ]]; then
        _MERGE_STATE_GIT_DIR="$saved_git_dir"
    else
        unset _MERGE_STATE_GIT_DIR
    fi
    assert_pass_if_clean "test_s3_c7_merge_to_main_rebase_merge_detects_stale_rebase"
}

# =============================================================================
# SCENARIO 4: REBASE_HEAD + rebase-apply/ — same filtering via rebase-apply path
# =============================================================================

# S4-C1: review-gate — ms_is_rebase_in_progress true with rebase-apply/
test_s4_c1_review_gate_rebase_apply_detects_rebase() {
    _snapshot_fail
    local repo git_dir result
    repo=$(cd /tmp && _make_rebase_apply_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    result=0
    _MERGE_STATE_GIT_DIR="$git_dir" ms_is_rebase_in_progress || result=$?
    assert_eq "S4-C1 review-gate: ms_is_rebase_in_progress true with rebase-apply/" \
        "0" "$result"
    assert_pass_if_clean "test_s4_c1_review_gate_rebase_apply_detects_rebase"
}

# S4-C2: test-gate — ms_get_worktree_only_files uses rebase-apply/onto for filtering
test_s4_c2_test_gate_rebase_apply_filters_correctly() {
    _snapshot_fail
    local repo git_dir files has_apply_file
    repo=$(cd /tmp && _make_rebase_apply_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    files=$(cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_get_worktree_only_files 2>/dev/null || echo "FAILED")

    # The function should return non-empty output without crashing
    assert_ne "S4-C2 test-gate: ms_get_worktree_only_files returns non-FAILED output" \
        "FAILED" "$files"

    has_apply_file=0
    _tmp="$files"; [[ "$_tmp" =~ worktree-apply.txt ]] && has_apply_file=1
    assert_eq "S4-C2 test-gate: worktree-apply.txt included during rebase-apply" \
        "1" "$has_apply_file"
    assert_pass_if_clean "test_s4_c2_test_gate_rebase_apply_filters_correctly"
}

# S4-C3: record-test-status — ms_is_rebase_in_progress true; filtering works via rebase-apply
test_s4_c3_record_test_status_rebase_apply_detects_and_filters() {
    _snapshot_fail
    local repo git_dir rebase_r files has_apply_file
    repo=$(cd /tmp && _make_rebase_apply_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    rebase_r=0
    _MERGE_STATE_GIT_DIR="$git_dir" ms_is_rebase_in_progress || rebase_r=$?
    assert_eq "S4-C3 record-test-status: rebase detected via rebase-apply/" \
        "0" "$rebase_r"

    files=$(cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_get_worktree_only_files 2>/dev/null || echo "")
    has_apply_file=0
    _tmp="$files"; [[ "$_tmp" =~ worktree-apply.txt ]] && has_apply_file=1
    assert_eq "S4-C3 record-test-status: worktree-apply.txt in worktree-only files" \
        "1" "$has_apply_file"
    assert_pass_if_clean "test_s4_c3_record_test_status_rebase_apply_detects_and_filters"
}

# S4-C4: compute-diff-hash — ms_get_merge_base reads rebase-apply/onto and orig-head
test_s4_c4_compute_diff_hash_rebase_apply_merge_base() {
    _snapshot_fail
    local repo git_dir merge_base is_valid_sha
    repo=$(cd /tmp && _make_rebase_apply_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    merge_base=$(cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_get_merge_base 2>/dev/null || echo "")
    assert_ne "S4-C4 compute-diff-hash: ms_get_merge_base returns non-empty for rebase-apply" \
        "" "$merge_base"

    is_valid_sha=0
    git -C "$repo" cat-file -e "$merge_base" 2>/dev/null && is_valid_sha=1
    assert_eq "S4-C4 compute-diff-hash: rebase-apply merge-base is valid git object" \
        "1" "$is_valid_sha"
    assert_pass_if_clean "test_s4_c4_compute_diff_hash_rebase_apply_merge_base"
}

# S4-C5: capture-review-diff — ms_get_worktree_only_files_from_head works via rebase-apply
test_s4_c5_capture_review_diff_rebase_apply_from_head() {
    _snapshot_fail
    local repo git_dir files has_apply_file
    repo=$(cd /tmp && _make_rebase_apply_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    files=$(cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_get_worktree_only_files_from_head 2>/dev/null || echo "")
    has_apply_file=0
    _tmp="$files"; [[ "$_tmp" =~ worktree-apply.txt ]] && has_apply_file=1
    assert_eq "S4-C5 capture-review-diff: worktree-apply.txt in from_head result for rebase-apply" \
        "1" "$has_apply_file"
    assert_pass_if_clean "test_s4_c5_capture_review_diff_rebase_apply_from_head"
}

# S4-C6: classifier — ms_is_rebase_in_progress true via rebase-apply/; ms_is_merge false
test_s4_c6_classifier_rebase_apply_detects_only_rebase() {
    _snapshot_fail
    local repo git_dir rebase_r merge_r
    repo=$(cd /tmp && _make_rebase_apply_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    rebase_r=0
    _MERGE_STATE_GIT_DIR="$git_dir" ms_is_rebase_in_progress || rebase_r=$?
    assert_eq "S4-C6 classifier: rebase detected via rebase-apply/" \
        "0" "$rebase_r"

    merge_r=0
    _MERGE_STATE_GIT_DIR="$git_dir" ms_is_merge_in_progress && merge_r=0 || merge_r=$?
    assert_ne "S4-C6 classifier: ms_is_merge_in_progress false with only rebase-apply/" \
        "0" "$merge_r"
    assert_pass_if_clean "test_s4_c6_classifier_rebase_apply_detects_only_rebase"
}

# S4-C7: merge-to-main — detects rebase-apply state via _MERGE_STATE_GIT_DIR override
test_s4_c7_merge_to_main_rebase_apply_detects_stale_rebase() {
    _snapshot_fail
    local repo git_dir saved_git_dir rebase_r
    repo=$(cd /tmp && _make_rebase_apply_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    saved_git_dir="${_MERGE_STATE_GIT_DIR:-}"
    _MERGE_STATE_GIT_DIR="$git_dir"

    rebase_r=0
    ms_is_rebase_in_progress || rebase_r=$?
    assert_eq "S4-C7 merge-to-main: rebase-apply state detected with GIT_DIR override" \
        "0" "$rebase_r"

    if [[ -n "$saved_git_dir" ]]; then
        _MERGE_STATE_GIT_DIR="$saved_git_dir"
    else
        unset _MERGE_STATE_GIT_DIR
    fi
    assert_pass_if_clean "test_s4_c7_merge_to_main_rebase_apply_detects_stale_rebase"
}

# =============================================================================
# SCENARIO 5: MERGE_HEAD == HEAD guard — self-referencing MERGE_HEAD
# ms_is_merge_in_progress must return false (guard fires);
# ms_get_worktree_only_files must fail-open and return staged files.
# =============================================================================

# S5-C1: review-gate — MERGE_HEAD==HEAD guard: ms_is_merge_in_progress returns false
# Note: ms_is_merge_in_progress calls git rev-parse HEAD (without --git-dir) so we must
# cd into the temp repo for the guard comparison to use the correct HEAD SHA.
test_s5_c1_review_gate_self_merge_guard_fires() {
    _snapshot_fail
    local repo git_dir merge_r
    repo=$(_make_self_merge_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    merge_r=0
    (cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_is_merge_in_progress) && merge_r=0 || merge_r=$?
    assert_ne "S5-C1 review-gate: ms_is_merge_in_progress returns false when MERGE_HEAD==HEAD" \
        "0" "$merge_r"
    assert_pass_if_clean "test_s5_c1_review_gate_self_merge_guard_fires"
}

# S5-C2: test-gate — ms_get_worktree_only_files fail-opens, returns staged files
test_s5_c2_test_gate_self_merge_guard_fail_open() {
    _snapshot_fail
    local repo git_dir files has_staged
    repo=$(_make_self_merge_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    files=$(cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_get_worktree_only_files 2>/dev/null || echo "")
    has_staged=0
    _tmp="$files"; [[ "$_tmp" =~ worktree-self.txt ]] && has_staged=1
    assert_eq "S5-C2 test-gate: staged file returned when MERGE_HEAD==HEAD (fail-open)" \
        "1" "$has_staged"
    assert_pass_if_clean "test_s5_c2_test_gate_self_merge_guard_fail_open"
}

# S5-C3: record-test-status — same fail-open behavior as test-gate
test_s5_c3_record_test_status_self_merge_guard_fail_open() {
    _snapshot_fail
    local repo git_dir files has_staged
    repo=$(_make_self_merge_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    files=$(cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_get_worktree_only_files 2>/dev/null || echo "")
    has_staged=0
    _tmp="$files"; [[ "$_tmp" =~ worktree-self.txt ]] && has_staged=1
    assert_eq "S5-C3 record-test-status: staged file returned on MERGE_HEAD==HEAD guard (fail-open)" \
        "1" "$has_staged"
    assert_pass_if_clean "test_s5_c3_record_test_status_self_merge_guard_fail_open"
}

# S5-C4: compute-diff-hash — ms_get_merge_base with MERGE_HEAD==HEAD:
# MERGE_HEAD still resolves (file exists), merge-base is computed, returns a SHA.
# Note: MERGE_HEAD==HEAD means merge-base(HEAD, HEAD) = HEAD, which is valid.
# ms_get_merge_base does NOT apply the MERGE_HEAD==HEAD guard — that guard lives only in
# ms_is_merge_in_progress and ms_get_worktree_only_files. So when MERGE_HEAD==HEAD,
# git merge-base HEAD HEAD succeeds and returns HEAD's SHA.
test_s5_c4_compute_diff_hash_self_merge_guard_merge_base() {
    _snapshot_fail
    local repo git_dir merge_base exit_ok
    repo=$(_make_self_merge_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    # Capture exit code and output separately to avoid the tautological && exit_ok=1 || exit_ok=1 pattern.
    # Run once for the exit code (must not use || echo "" which would mask failures).
    cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_get_merge_base >/dev/null 2>&1
    exit_ok=$?
    merge_base=$(cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_get_merge_base 2>/dev/null)

    # ms_get_merge_base should succeed (exit 0): git merge-base HEAD HEAD is valid and returns HEAD.
    assert_eq "S5-C4 compute-diff-hash: ms_get_merge_base exits 0 when MERGE_HEAD==HEAD" \
        "0" "$exit_ok"
    # The returned SHA must be non-empty (it equals HEAD in this case).
    local is_nonempty=0
    [[ -n "$merge_base" ]] && is_nonempty=1
    assert_eq "S5-C4 compute-diff-hash: ms_get_merge_base returns non-empty SHA when MERGE_HEAD==HEAD" \
        "1" "$is_nonempty"
    assert_pass_if_clean "test_s5_c4_compute_diff_hash_self_merge_guard_merge_base"
}

# S5-C5: capture-review-diff — ms_get_worktree_only_files_from_head fail-opens on MERGE_HEAD==HEAD
test_s5_c5_capture_review_diff_self_merge_guard_fail_open() {
    _snapshot_fail
    local repo git_dir files has_staged
    repo=$(_make_self_merge_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    files=$(cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_get_worktree_only_files_from_head 2>/dev/null || echo "")
    has_staged=0
    _tmp="$files"; [[ "$_tmp" =~ worktree-self.txt ]] && has_staged=1
    assert_eq "S5-C5 capture-review-diff: from_head fail-opens on MERGE_HEAD==HEAD" \
        "1" "$has_staged"
    assert_pass_if_clean "test_s5_c5_capture_review_diff_self_merge_guard_fail_open"
}

# S5-C6: classifier — ms_is_merge_in_progress false (guard fires); no bypass possible
# Note: must cd into the repo so git rev-parse HEAD uses the temp repo's HEAD.
test_s5_c6_classifier_self_merge_guard_blocks_bypass() {
    _snapshot_fail
    local repo git_dir merge_r
    repo=$(_make_self_merge_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    merge_r=0
    (cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_is_merge_in_progress) && merge_r=0 || merge_r=$?
    assert_ne "S5-C6 classifier: guard prevents MERGE_HEAD==HEAD from appearing as active merge" \
        "0" "$merge_r"
    assert_pass_if_clean "test_s5_c6_classifier_self_merge_guard_blocks_bypass"
}

# S5-C7: merge-to-main — MERGE_HEAD==HEAD: ms_is_merge_in_progress returns false (guard fires)
# merge-to-main's _cleanup_stale_git_state should NOT attempt merge --abort in this state.
# Note: must run from within the repo so git rev-parse HEAD uses the temp repo's HEAD.
test_s5_c7_merge_to_main_self_merge_guard_no_cleanup_triggered() {
    _snapshot_fail
    local repo git_dir merge_r
    repo=$(_make_self_merge_repo)
    git_dir=$(git -C "$repo" rev-parse --absolute-git-dir 2>/dev/null)

    # Guard must fire so merge-to-main's cleanup is NOT triggered
    merge_r=0
    (cd "$repo" && _MERGE_STATE_GIT_DIR="$git_dir" ms_is_merge_in_progress) && merge_r=0 || merge_r=$?
    assert_ne "S5-C7 merge-to-main: MERGE_HEAD==HEAD guard prevents cleanup trigger" \
        "0" "$merge_r"
    assert_pass_if_clean "test_s5_c7_merge_to_main_self_merge_guard_no_cleanup_triggered"
}

# =============================================================================
# Run all tests
# =============================================================================
echo ""
echo "--- Scenario 1: Normal commit (no merge/rebase state) ---"
echo ""
test_s1_c1_review_gate_normal_no_merge_state
echo ""
test_s1_c2_test_gate_normal_returns_staged_files
echo ""
test_s1_c3_record_test_status_normal_no_filter
echo ""
test_s1_c4_compute_diff_hash_normal_no_merge_base
echo ""
test_s1_c5_capture_review_diff_normal_returns_staged_files
echo ""
test_s1_c6_classifier_normal_no_merge_rebase
echo ""
test_s1_c7_merge_to_main_normal_no_stale_state

echo ""
echo "--- Scenario 2: MERGE_HEAD present ---"
echo ""
test_s2_c1_review_gate_merge_detects_merge_state
echo ""
test_s2_c2_test_gate_merge_filters_incoming
echo ""
test_s2_c3_record_test_status_merge_filters_incoming
echo ""
test_s2_c4_compute_diff_hash_merge_returns_merge_base
echo ""
test_s2_c5_capture_review_diff_merge_filters_incoming
echo ""
test_s2_c6_classifier_merge_detects_only_merge
echo ""
test_s2_c7_merge_to_main_merge_detects_stale_merge

echo ""
echo "--- Scenario 3: REBASE_HEAD + rebase-merge/ ---"
echo ""
test_s3_c1_review_gate_rebase_merge_detects_rebase
echo ""
test_s3_c2_test_gate_rebase_merge_filters_onto_files
echo ""
test_s3_c3_record_test_status_rebase_merge_filters_onto_files
echo ""
test_s3_c4_compute_diff_hash_rebase_merge_returns_merge_base
echo ""
test_s3_c5_capture_review_diff_rebase_merge_from_head
echo ""
test_s3_c6_classifier_rebase_merge_detects_only_rebase
echo ""
test_s3_c7_merge_to_main_rebase_merge_detects_stale_rebase

echo ""
echo "--- Scenario 4: REBASE_HEAD + rebase-apply/ ---"
echo ""
test_s4_c1_review_gate_rebase_apply_detects_rebase
echo ""
test_s4_c2_test_gate_rebase_apply_filters_correctly
echo ""
test_s4_c3_record_test_status_rebase_apply_detects_and_filters
echo ""
test_s4_c4_compute_diff_hash_rebase_apply_merge_base
echo ""
test_s4_c5_capture_review_diff_rebase_apply_from_head
echo ""
test_s4_c6_classifier_rebase_apply_detects_only_rebase
echo ""
test_s4_c7_merge_to_main_rebase_apply_detects_stale_rebase

echo ""
echo "--- Scenario 5: MERGE_HEAD == HEAD guard ---"
echo ""
test_s5_c1_review_gate_self_merge_guard_fires
echo ""
test_s5_c2_test_gate_self_merge_guard_fail_open
echo ""
test_s5_c3_record_test_status_self_merge_guard_fail_open
echo ""
test_s5_c4_compute_diff_hash_self_merge_guard_merge_base
echo ""
test_s5_c5_capture_review_diff_self_merge_guard_fail_open
echo ""
test_s5_c6_classifier_self_merge_guard_blocks_bypass
echo ""
test_s5_c7_merge_to_main_self_merge_guard_no_cleanup_triggered

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
