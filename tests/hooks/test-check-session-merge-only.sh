#!/usr/bin/env bash
# tests/hooks/test-check-session-merge-only.sh
# Behavioral tests for plugins/dso/scripts/check-session-merge-only.sh
#
# This is a RED test file: all 4 test cases FAIL because the script does not
# exist yet. An exit gate at the top detects the missing script, counts each
# test as a FAIL (rather than skipping), then calls print_summary to exit
# nonzero so the RED condition is clearly surfaced.
#
# Test cases (4 — one per DD from story 53be-becc-af70-4f62):
#   1. non-merge commit + .sprint-active present → script rejects (exit nonzero)
#   2. merge commit + .sprint-active present    → script accepts (exit 0)
#   3. DSO_SPRINT_ACTIVE=0 + .sprint-active present → exit 0 + audit log written
#   4. no .sprint-active marker                → script accepts (exit 0)
#
# RED MARKER:
# tests/hooks/test-check-session-merge-only.sh [test_non_merge_with_sprint_active_rejected]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

_SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/check-session-merge-only.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# ── Cleanup on exit ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
# Track linked worktrees so they can be unregistered before their parent repo
# is removed. Each entry is "MAIN_REPO|WT_DIR".
_TEST_LINKED_WORKTREES=()
_cleanup_test_tmpdirs() {
    # Unregister linked worktrees first so the parent repo's worktree config
    # is cleaned up rather than left with stale entries (per CI review).
    for entry in "${_TEST_LINKED_WORKTREES[@]:-}"; do
        [[ -z "$entry" ]] && continue
        local _main="${entry%%|*}"
        local _wt="${entry##*|}"
        [[ -d "$_main/.git" ]] && git -C "$_main" worktree remove --force "$_wt" 2>/dev/null || true
    done
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# ── Helper: create a temp git repo with one initial commit ────────────────────
# Prints the repo directory path on stdout.
make_git_repo_with_commit() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    git -C "$tmpdir" init -q
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    git -C "$tmpdir" config commit.gpgsign false
    printf '# test repo\n' > "$tmpdir/README.md"
    git -C "$tmpdir" add README.md
    git -C "$tmpdir" commit -q -m "init"
    echo "$tmpdir"
}

# ── Helper: create a temp main repo + a linked worktree off of it ─────────────
# Prints the linked worktree directory path on stdout. The linked worktree
# satisfies the new git-common-dir != git-dir check in the hook, so the
# hook's marker-check / escape-hatch logic exercises end-to-end.
make_linked_worktree() {
    local main_repo
    main_repo=$(make_git_repo_with_commit)

    local wt_dir
    wt_dir=$(mktemp -d)
    rm -rf "$wt_dir"  # `git worktree add` requires a non-existent path
    _TEST_TMPDIRS+=("$wt_dir")

    # Create a linked worktree on a new branch off the existing HEAD.
    # Branch name is randomized so callers can invoke this helper multiple
    # times against the same main_repo (and so multiple concurrent test files
    # never collide on the branch name).
    local branch_name="test-wt-$$-${RANDOM}"
    git -C "$main_repo" worktree add -q -b "$branch_name" "$wt_dir" >/dev/null 2>&1
    _TEST_LINKED_WORKTREES+=("$main_repo|$wt_dir")
    echo "$wt_dir"
}

# ── Exit gate: mark all 4 tests as FAILed if script is missing ───────────────
if [[ ! -f "$_SCRIPT" ]]; then
    printf "FAIL: check-session-merge-only.sh not found — expected at %s\n" "$_SCRIPT" >&2
    printf "  All 4 behavioral cases counted as FAIL (RED phase — script not yet written)\n" >&2
    (( FAIL += 4 ))
    print_summary
fi

# ── Test 1: non-merge commit + .sprint-active present → rejected ──────────────
# Setup: temp git repo with a regular (non-merge) commit; .sprint-active present
# Expected: script exits nonzero (commit rejected)
test_non_merge_with_sprint_active_rejected() {
    local _repo
    _repo=$(make_linked_worktree)

    # Place .sprint-active marker at repo root
    touch "$_repo/.sprint-active"

    # The repo already has a regular (non-merge) HEAD commit from make_git_repo_with_commit.
    # Run the script from inside the repo.
    local exit_code=0
    ( cd "$_repo" && bash "$_SCRIPT" 2>/dev/null ) || exit_code=$?

    assert_ne \
        "test_non_merge_with_sprint_active_rejected: non-merge commit with .sprint-active exits nonzero" \
        "0" "$exit_code"
}

# ── Test 2: merge commit + .sprint-active present → accepted ─────────────────
# Setup: temp git repo; create .git/MERGE_HEAD to simulate a mid-merge state;
#        .sprint-active present
# Expected: script exits 0 (merge commit accepted)
test_merge_commit_with_sprint_active_accepted() {
    local _repo
    _repo=$(make_git_repo_with_commit)

    # Simulate git being mid-merge by writing a MERGE_HEAD file
    printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$_repo/.git/MERGE_HEAD"

    # Place .sprint-active marker
    touch "$_repo/.sprint-active"

    local exit_code=0
    ( cd "$_repo" && bash "$_SCRIPT" 2>/dev/null ) || exit_code=$?

    assert_eq \
        "test_merge_commit_with_sprint_active_accepted: merge commit with .sprint-active exits 0" \
        "0" "$exit_code"
}

# ── Test 3: DSO_SPRINT_ACTIVE=0 bypass → exit 0 + audit log written ──────────
# Setup: temp git repo; .sprint-active present; DSO_SPRINT_ACTIVE=0 env override;
#        DSO_ARTIFACTS_DIR points to a temp dir
# Expected: script exits 0 AND at least one file exists in DSO_ARTIFACTS_DIR
test_dso_sprint_active_override_exits_0_and_writes_audit_log() {
    local _repo _artifacts_dir
    _repo=$(make_linked_worktree)
    _artifacts_dir=$(mktemp -d)
    _TEST_TMPDIRS+=("$_artifacts_dir")

    touch "$_repo/.sprint-active"

    local exit_code=0
    (
        cd "$_repo"
        DSO_SPRINT_ACTIVE=0 \
        DSO_SPRINT_ACTIVE_BYPASS_REASON="audit-log test" \
        DSO_ARTIFACTS_DIR="$_artifacts_dir" bash "$_SCRIPT" 2>/dev/null
    ) || exit_code=$?

    assert_eq \
        "test_dso_sprint_active_override_exits_0_and_writes_audit_log: DSO_SPRINT_ACTIVE=0 exits 0" \
        "0" "$exit_code"

    # Audit log: at least one file must exist in DSO_ARTIFACTS_DIR after the run
    local audit_file_count
    audit_file_count=$(find "$_artifacts_dir" -maxdepth 2 -type f 2>/dev/null | wc -l | tr -d ' ')
    assert_ne \
        "test_dso_sprint_active_override_exits_0_and_writes_audit_log: audit log written to artifacts dir" \
        "0" "$audit_file_count"
}

# ── Test 4: no .sprint-active marker → accepted ───────────────────────────────
# Setup: temp git repo WITHOUT .sprint-active
# Expected: script exits 0 (hook is inactive in non-sprint mode)
test_no_sprint_active_marker_accepted() {
    local _repo
    _repo=$(make_git_repo_with_commit)

    # Explicitly ensure no .sprint-active is present
    rm -f "$_repo/.sprint-active"

    local exit_code=0
    ( cd "$_repo" && bash "$_SCRIPT" 2>/dev/null ) || exit_code=$?

    assert_eq \
        "test_no_sprint_active_marker_accepted: no .sprint-active exits 0" \
        "0" "$exit_code"
}

# ── Test 5: .debug-active alone rejects non-merge commit ──────────────────────
test_debug_active_alone_rejects_non_merge() {
    local _repo
    _repo=$(make_linked_worktree)
    touch "$_repo/.debug-active"
    # No .sprint-active
    local exit_code=0
    ( cd "$_repo" && bash "$_SCRIPT" 2>/dev/null ) || exit_code=$?
    assert_ne \
        "test_debug_active_alone_rejects_non_merge: .debug-active alone rejects non-merge commit" \
        "0" "$exit_code"
}

# ── Test 6: .debug-active + MERGE_HEAD → accepted ─────────────────────────────
test_debug_active_with_merge_commit_accepted() {
    local _repo
    _repo=$(make_git_repo_with_commit)
    touch "$_repo/.debug-active"
    printf 'deadbeefdeadbeefdeadbeefdeadbeefdeadbeef\n' > "$_repo/.git/MERGE_HEAD"
    local exit_code=0
    ( cd "$_repo" && bash "$_SCRIPT" 2>/dev/null ) || exit_code=$?
    assert_eq \
        "test_debug_active_with_merge_commit_accepted: .debug-active + merge commit exits 0" \
        "0" "$exit_code"
}

# ── Test 7: DSO_DEBUG_ACTIVE=0 bypass → exit 0 + audit log ────────────────────
test_dso_debug_active_override_exits_0_and_writes_audit_log() {
    local _repo _artifacts_dir
    _repo=$(make_linked_worktree)
    _artifacts_dir=$(mktemp -d)
    _TEST_TMPDIRS+=("$_artifacts_dir")
    touch "$_repo/.debug-active"
    local exit_code=0
    (
        cd "$_repo"
        DSO_DEBUG_ACTIVE=0 \
        DSO_DEBUG_ACTIVE_BYPASS_REASON="audit-log test" \
        DSO_ARTIFACTS_DIR="$_artifacts_dir" bash "$_SCRIPT" 2>/dev/null
    ) || exit_code=$?
    assert_eq \
        "test_dso_debug_active_override_exits_0_and_writes_audit_log: DSO_DEBUG_ACTIVE=0 exits 0" \
        "0" "$exit_code"
    local audit_file_count
    audit_file_count=$(find "$_artifacts_dir" -maxdepth 2 -type f 2>/dev/null | wc -l | tr -d ' ')
    assert_ne \
        "test_dso_debug_active_override_exits_0_and_writes_audit_log: audit log written" \
        "0" "$audit_file_count"
}

# ── Test 8: both markers, only DSO_SPRINT_ACTIVE=0 → still rejected ───────────
test_both_markers_sprint_escape_only_still_rejects() {
    local _repo
    _repo=$(make_linked_worktree)
    touch "$_repo/.sprint-active"
    touch "$_repo/.debug-active"
    local exit_code=0
    (
        cd "$_repo"
        DSO_SPRINT_ACTIVE=0 bash "$_SCRIPT" 2>/dev/null
    ) || exit_code=$?
    assert_ne \
        "test_both_markers_sprint_escape_only_still_rejects: both markers, sprint escape only still rejects" \
        "0" "$exit_code"
}

# ── Test 9: both markers + both env vars = 0 → accepted ───────────────────────
test_both_markers_both_escapes_accepted() {
    local _repo _artifacts_dir
    _repo=$(make_git_repo_with_commit)
    _artifacts_dir=$(mktemp -d)
    _TEST_TMPDIRS+=("$_artifacts_dir")
    touch "$_repo/.sprint-active"
    touch "$_repo/.debug-active"
    local exit_code=0
    (
        cd "$_repo"
        DSO_SPRINT_ACTIVE=0 DSO_DEBUG_ACTIVE=0 DSO_ARTIFACTS_DIR="$_artifacts_dir" bash "$_SCRIPT" 2>/dev/null
    ) || exit_code=$?
    assert_eq \
        "test_both_markers_both_escapes_accepted: both markers both env vars 0 exits 0" \
        "0" "$exit_code"
}

# ── Test 10: main repo (primary checkout) with .sprint-active → accepted ─────
# Bug 6e96-61bf: when merge-to-main.sh runs the post-merge version-bump commit
# in MAIN_REPO, the hook fires from MAIN_REPO context (shared .git/hooks).
# A stale .sprint-active marker at MAIN_REPO must NOT trigger rejection —
# the hook's enforcement target is linked worktrees, not the primary checkout.
test_main_repo_with_sprint_active_accepted() {
    local _repo
    _repo=$(make_git_repo_with_commit)

    # Primary checkout (no `git worktree add`): git-common-dir == git-dir.
    touch "$_repo/.sprint-active"

    local exit_code=0
    ( cd "$_repo" && bash "$_SCRIPT" 2>/dev/null ) || exit_code=$?

    assert_eq \
        "test_main_repo_with_sprint_active_accepted: primary checkout with .sprint-active exits 0 (hook only enforces in linked worktrees)" \
        "0" "$exit_code"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
echo "=== test-check-session-merge-only ==="
echo ""

echo "--- Test 1: non-merge commit + .sprint-active → rejected ---"
test_non_merge_with_sprint_active_rejected
echo ""

echo "--- Test 2: merge commit + .sprint-active → accepted ---"
test_merge_commit_with_sprint_active_accepted
echo ""

echo "--- Test 3: DSO_SPRINT_ACTIVE=0 + .sprint-active → exit 0 + audit log ---"
test_dso_sprint_active_override_exits_0_and_writes_audit_log
echo ""

echo "--- Test 4: no .sprint-active → accepted ---"
test_no_sprint_active_marker_accepted
echo ""

echo "--- Test 5: .debug-active alone → rejected ---"
test_debug_active_alone_rejects_non_merge
echo ""

echo "--- Test 6: .debug-active + merge commit → accepted ---"
test_debug_active_with_merge_commit_accepted
echo ""

echo "--- Test 7: DSO_DEBUG_ACTIVE=0 + .debug-active → exit 0 + audit log ---"
test_dso_debug_active_override_exits_0_and_writes_audit_log
echo ""

echo "--- Test 8: both markers, sprint escape only → still rejects ---"
test_both_markers_sprint_escape_only_still_rejects
echo ""

echo "--- Test 9: both markers, both escapes → accepted ---"
test_both_markers_both_escapes_accepted
echo ""

echo "--- Test 10: main repo (primary checkout) + .sprint-active → accepted ---"
test_main_repo_with_sprint_active_accepted
echo ""

# ── Test 11 (RED): sprint bypass without reason → refused ────────────────────
# Bug 660e-4317: DSO_SPRINT_ACTIVE=0 without DSO_SPRINT_ACTIVE_BYPASS_REASON
# must be refused (exit non-zero) with an error message naming the missing var.
test_sprint_bypass_without_reason_refused() {
    local _repo
    _repo=$(make_linked_worktree)
    touch "$_repo/.sprint-active"

    local exit_code=0
    local stderr_output
    stderr_output=$(
        cd "$_repo"
        DSO_SPRINT_ACTIVE=0 bash "$_SCRIPT" 2>&1 1>/dev/null
    ) || true
    (
        cd "$_repo"
        DSO_SPRINT_ACTIVE=0 bash "$_SCRIPT" 2>/dev/null
    ) && exit_code=0 || exit_code=$?

    assert_ne \
        "test_sprint_bypass_without_reason_refused: sprint bypass without reason exits nonzero" \
        "0" "$exit_code"

    assert_contains \
        "test_sprint_bypass_without_reason_refused: error message mentions missing reason variable" \
        "DSO_SPRINT_ACTIVE_BYPASS_REASON" "$stderr_output"
}

# ── Test 12 (RED): sprint bypass WITH reason → accepted, reason logged ────────
# Bug 660e-4317: DSO_SPRINT_ACTIVE=0 + DSO_SPRINT_ACTIVE_BYPASS_REASON set
# must exit 0, write REASON= into the log file, and emit a stderr line with the
# reason text.
test_sprint_bypass_with_reason_accepted_and_logged() {
    local _repo _artifacts_dir
    _repo=$(make_linked_worktree)
    _artifacts_dir=$(mktemp -d)
    _TEST_TMPDIRS+=("$_artifacts_dir")
    touch "$_repo/.sprint-active"

    local exit_code=0
    local stderr_output
    stderr_output=$(
        cd "$_repo"
        DSO_SPRINT_ACTIVE=0 \
        DSO_SPRINT_ACTIVE_BYPASS_REASON="test reason text" \
        DSO_ARTIFACTS_DIR="$_artifacts_dir" \
        bash "$_SCRIPT" 2>&1 1>/dev/null
    ) || true
    (
        cd "$_repo"
        DSO_SPRINT_ACTIVE=0 \
        DSO_SPRINT_ACTIVE_BYPASS_REASON="test reason text" \
        DSO_ARTIFACTS_DIR="$_artifacts_dir" \
        bash "$_SCRIPT" 2>/dev/null
    ) && exit_code=0 || exit_code=$?

    assert_eq \
        "test_sprint_bypass_with_reason_accepted_and_logged: sprint bypass with reason exits 0" \
        "0" "$exit_code"

    # Log file must contain REASON=<value>
    local log_content
    log_content=$(find "$_artifacts_dir" -maxdepth 2 -type f -name "sprint-merge-only-bypass-*.log" \
        -exec cat {} \; 2>/dev/null)
    assert_contains \
        "test_sprint_bypass_with_reason_accepted_and_logged: log file contains REASON=test reason text" \
        "REASON=test reason text" "$log_content"

    assert_contains \
        "test_sprint_bypass_with_reason_accepted_and_logged: stderr contains the reason text" \
        "test reason text" "$stderr_output"
}

# ── Test 13 (RED): debug bypass without reason → refused ─────────────────────
# Bug 660e-4317: DSO_DEBUG_ACTIVE=0 without DSO_DEBUG_ACTIVE_BYPASS_REASON
# must be refused (exit non-zero) with an error message naming the missing var.
test_debug_bypass_without_reason_refused() {
    local _repo
    _repo=$(make_linked_worktree)
    touch "$_repo/.debug-active"

    local exit_code=0
    local stderr_output
    stderr_output=$(
        cd "$_repo"
        DSO_DEBUG_ACTIVE=0 bash "$_SCRIPT" 2>&1 1>/dev/null
    ) || true
    (
        cd "$_repo"
        DSO_DEBUG_ACTIVE=0 bash "$_SCRIPT" 2>/dev/null
    ) && exit_code=0 || exit_code=$?

    assert_ne \
        "test_debug_bypass_without_reason_refused: debug bypass without reason exits nonzero" \
        "0" "$exit_code"

    assert_contains \
        "test_debug_bypass_without_reason_refused: error message mentions missing reason variable" \
        "DSO_DEBUG_ACTIVE_BYPASS_REASON" "$stderr_output"
}

# ── Test 14 (RED): debug bypass WITH reason → accepted, reason logged ─────────
# Bug 660e-4317: DSO_DEBUG_ACTIVE=0 + DSO_DEBUG_ACTIVE_BYPASS_REASON set
# must exit 0, write REASON= into the log file, and emit a stderr line with the
# reason text.
test_debug_bypass_with_reason_accepted_and_logged() {
    local _repo _artifacts_dir
    _repo=$(make_linked_worktree)
    _artifacts_dir=$(mktemp -d)
    _TEST_TMPDIRS+=("$_artifacts_dir")
    touch "$_repo/.debug-active"

    local exit_code=0
    local stderr_output
    stderr_output=$(
        cd "$_repo"
        DSO_DEBUG_ACTIVE=0 \
        DSO_DEBUG_ACTIVE_BYPASS_REASON="test reason text" \
        DSO_ARTIFACTS_DIR="$_artifacts_dir" \
        bash "$_SCRIPT" 2>&1 1>/dev/null
    ) || true
    (
        cd "$_repo"
        DSO_DEBUG_ACTIVE=0 \
        DSO_DEBUG_ACTIVE_BYPASS_REASON="test reason text" \
        DSO_ARTIFACTS_DIR="$_artifacts_dir" \
        bash "$_SCRIPT" 2>/dev/null
    ) && exit_code=0 || exit_code=$?

    assert_eq \
        "test_debug_bypass_with_reason_accepted_and_logged: debug bypass with reason exits 0" \
        "0" "$exit_code"

    # Log file must contain REASON=<value>
    local log_content
    log_content=$(find "$_artifacts_dir" -maxdepth 2 -type f -name "debug-merge-only-bypass-*.log" \
        -exec cat {} \; 2>/dev/null)
    assert_contains \
        "test_debug_bypass_with_reason_accepted_and_logged: log file contains REASON=test reason text" \
        "REASON=test reason text" "$log_content"

    assert_contains \
        "test_debug_bypass_with_reason_accepted_and_logged: stderr contains the reason text" \
        "test reason text" "$stderr_output"
}

echo "--- Test 11 (RED): sprint bypass without reason → refused ---"
test_sprint_bypass_without_reason_refused
echo ""

echo "--- Test 12 (RED): sprint bypass with reason → accepted + logged ---"
test_sprint_bypass_with_reason_accepted_and_logged
echo ""

echo "--- Test 13 (RED): debug bypass without reason → refused ---"
test_debug_bypass_without_reason_refused
echo ""

echo "--- Test 14 (RED): debug bypass with reason → accepted + logged ---"
test_debug_bypass_with_reason_accepted_and_logged
echo ""

# ── Test 15: agent worktree with copied .sprint-active rejects non-merge commit ─
# Documents the INVARIANT that check-session-merge-only.sh must respect:
# a linked worktree with .sprint-active present (whether placed by copy or any
# other means) REJECTS non-merge commits. This is exactly why the skills must
# NOT copy .sprint-active into agent sub-branch worktrees. The hook behavior
# itself is tested as-is (unchanged); this test records WHY the copy had to go.
test_agent_worktree_with_copied_sprint_active_rejects_non_merge_commit() {
    local _repo
    _repo=$(make_linked_worktree)

    # Simulate what Step 3.5 / Step 7.5 used to do: copy .sprint-active into
    # the agent worktree. This is the trigger for the mutual-exclusion conflict
    # described in bug 3349-8532-1183-4fc1.
    touch "$_repo/.sprint-active"

    local exit_code=0
    ( cd "$_repo" && bash "$_SCRIPT" 2>/dev/null ) || exit_code=$?

    assert_ne \
        "test_agent_worktree_with_copied_sprint_active_rejects_non_merge_commit: linked worktree + .sprint-active rejects non-merge commit (invariant the skills must respect)" \
        "0" "$exit_code"
}

echo "--- Test 15: agent worktree with copied .sprint-active rejects non-merge commit (invariant) ---"
test_agent_worktree_with_copied_sprint_active_rejects_non_merge_commit
echo ""

# ── Test 16 (RED → GREEN after fix): skill prompts contain no cp-of-.sprint-active ─
# Structural assertion: per-worktree-review-commit.md and single-agent-integrate.md
# must NOT contain any instruction to `cp` `.sprint-active` into a sub-worktree.
# RED before fix (the cp instruction is still present in both files).
# GREEN after fix (the cp instructions are replaced with env-var export).
test_skill_prompts_contain_no_cp_sprint_active_instruction() {
    local _repo_root
    _repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "$PLUGIN_ROOT")

    local _per_worktree="$_repo_root/plugins/dso/skills/sprint/prompts/per-worktree-review-commit.md"
    local _single_agent="$_repo_root/plugins/dso/skills/shared/prompts/single-agent-integrate.md"

    # Look for `cp` commands that copy `.sprint-active` into a worktree path.
    # The pattern is: `cp "$SESSION_ROOT/.sprint-active"` or
    # `cp "$ORCHESTRATOR_ROOT/.sprint-active"` (both variants used in the two files).
    local _per_worktree_violation=0
    local _single_agent_violation=0

    if grep -qE 'cp[[:space:]].*\.sprint-active' "$_per_worktree" 2>/dev/null; then
        _per_worktree_violation=1
    fi
    if grep -qE 'cp[[:space:]].*\.sprint-active' "$_single_agent" 2>/dev/null; then
        _single_agent_violation=1
    fi

    assert_eq \
        "test_skill_prompts_contain_no_cp_sprint_active_instruction: per-worktree-review-commit.md has no cp-of-.sprint-active instruction" \
        "0" "$_per_worktree_violation"

    assert_eq \
        "test_skill_prompts_contain_no_cp_sprint_active_instruction: single-agent-integrate.md has no cp-of-.sprint-active instruction" \
        "0" "$_single_agent_violation"
}

echo "--- Test 16 (RED→GREEN): skill prompts contain no cp-of-.sprint-active instruction ---"
test_skill_prompts_contain_no_cp_sprint_active_instruction
echo ""

print_summary
