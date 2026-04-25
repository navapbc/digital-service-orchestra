#!/usr/bin/env bash
# tests/scripts/test-harvest-worktree.sh
# RED tests for plugins/dso/scripts/harvest-worktree.sh
#
# harvest-worktree.sh merges a worktree branch into the session branch,
# validating gate artifacts (test-gate-status, review-status) before merging.
#
# Usage: bash tests/scripts/test-harvest-worktree.sh
#
# Tests:
#   1. test_clean_merge_produces_commit — happy path merge with passing gates
#   2. test_exit2_when_test_gate_missing — exits 2 when test-gate-status absent
#   3. test_exit2_when_review_status_missing — exits 2 when review-status absent
#   4. test_exit2_when_test_gate_failed — exits 2 when test-gate-status=failed
#   5. test_exit1_on_non_test_index_conflict — exits 1 on non-.test-index conflict
#   6. test_merge_head_cleaned_on_failure — MERGE_HEAD removed after failure
#   7. test_no_merge_head_on_entry — error if MERGE_HEAD already exists
#   8. test_attest_source_in_status_files — attested files include attest_source
#   9. test_trap_cleans_merge_head_on_signal — MERGE_HEAD cleaned on SIGTERM
#  10. test_already_merged_branch_noop — no-op when branch already merged
#  11. test_conflict_diagnostic_printed_to_stderr — conflicted filename in stderr (bug 0fc6-c970)
#  12. test_nonexistent_branch_exits1_with_message — non-conflict git failure exits 1 with message (bug 0fc6-c970)
#  13. test_cleanup_removes_worktree_after_successful_merge — worktree dir gone after merge (afdb-8418)
#  14. test_cleanup_deletes_backing_branch_after_successful_merge — branch deleted after merge (afdb-8418)
#  15. test_cleanup_skipped_on_gate_failure — worktree+branch preserved when merge blocked by gate (afdb-8418)
#  16. test_cleanup_handles_missing_worktree_gracefully — no error when branch has no backing worktree (afdb-8418)
#  17. test_exit0_when_failed_tests_all_have_red_markers — harvest passes when all failed tests have RED markers (6810-8607)
#  20. test_harvest_errors_when_called_from_inside_worktree — exits 1 when CWD is inside the target worktree (d888-632b)
#  21. test_branch_deleted_in_no_worktree_case — branch still deleted when no backing worktree exists (a44a-0f63 regression guard)
#  22. test_empty_branch_exits3_when_expected_base_provided — exits 3 (EMPTY_BRANCH) when branch tip == base commit (1eda-6a0c)
#  23. test_empty_branch_exits3_when_base_commit_file_present — exits 3 via artifacts/base-commit file (1eda-6a0c)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$SCRIPT_DIR/../lib/assert.sh"

# Prevent PROJECT_ROOT from leaking into temp-repo harvest-worktree.sh invocations.
# The dso shim exports PROJECT_ROOT; if inherited, harvest-worktree.sh resolves
# _DSO_SHIM_PATH against the actual project root instead of the stub injected via PATH.
unset PROJECT_ROOT

HARVEST_SCRIPT="$REPO_ROOT/plugins/dso/scripts/harvest-worktree.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

_TEST_TMPDIRS=()
_cleanup_tmpdirs() {
    for d in "${_TEST_TMPDIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_tmpdirs EXIT

make_tmpdir() {
    local d
    d=$(mktemp -d)
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# Create a bare "remote" repo and a working clone with a session branch,
# plus a worktree branch with a committed change and gate artifacts.
# Usage: setup_test_repo <tmpdir>
# Sets: SESSION_REPO, WORKTREE_BRANCH, ARTIFACTS_DIR
setup_test_repo() {
    local tmpdir="$1"
    local gate_status="${2:-passed}"  # test-gate-status value
    local review_status="${3:-passed}"  # review-status value
    local create_test_gate="${4:-yes}"
    local create_review="${5:-yes}"

    # Create a bare "origin"
    git init --bare "$tmpdir/origin.git" >/dev/null 2>&1

    # Clone it as the session repo
    git clone "$tmpdir/origin.git" "$tmpdir/session" >/dev/null 2>&1
    SESSION_REPO="$tmpdir/session"

    # Initial commit on main
    cd "$SESSION_REPO" || exit 1
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial" > file.txt
    git add file.txt
    git commit -m "initial commit" >/dev/null 2>&1
    git push origin HEAD:main >/dev/null 2>&1

    # Create session branch
    git checkout -b session-branch >/dev/null 2>&1

    # Create worktree branch from session-branch
    WORKTREE_BRANCH="worktree-test-$$-$RANDOM"
    git checkout -b "$WORKTREE_BRANCH" >/dev/null 2>&1

    # Make a change on the worktree branch
    echo "worktree change" > worktree-file.txt
    git add worktree-file.txt
    git commit -m "worktree change" >/dev/null 2>&1

    # Create artifacts directory for the worktree
    ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"

    # Write gate artifacts
    local diff_hash
    diff_hash=$(git diff HEAD~1 HEAD | shasum -a 256 | cut -d' ' -f1)

    if [[ "$create_test_gate" == "yes" ]]; then
        cat > "$ARTIFACTS_DIR/test-gate-status" <<EOF
${gate_status}
diff_hash=${diff_hash}
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tested_files=tests/scripts/test-example.sh
EOF
    fi

    if [[ "$create_review" == "yes" ]]; then
        cat > "$ARTIFACTS_DIR/review-status" <<EOF
${review_status}
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
diff_hash=${diff_hash}
score=4
review_hash=abc123def456
EOF
    fi

    # Switch back to session branch
    git checkout session-branch >/dev/null 2>&1
}

# =============================================================================
# Test 1: test_clean_merge_produces_commit
# Given: worktree branch with passing gate artifacts
# When: harvest-worktree.sh is invoked
# Then: merge commit is produced on session branch
# =============================================================================
echo "--- test_clean_merge_produces_commit ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

commit_before=$(cd "$SESSION_REPO" && git rev-parse HEAD)

output=""
exit_code=0
output=$(cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    2>&1) || exit_code=$?

assert_eq "clean merge exits 0" "0" "$exit_code"

# Verify a new commit was created (HEAD moved)
commit_after=$(cd "$SESSION_REPO" && git rev-parse HEAD)
assert_ne "HEAD moved after merge" "$commit_before" "$commit_after"

# Verify the merge brought the worktree file
assert_eq "worktree-file.txt exists after merge" "0" \
    "$(cd "$SESSION_REPO" && test -f worktree-file.txt && echo 0 || echo 1)"

assert_pass_if_clean "test_clean_merge_produces_commit"

# =============================================================================
# Test 2: test_exit2_when_test_gate_missing
# Given: worktree branch with NO test-gate-status artifact
# When: harvest-worktree.sh is invoked
# Then: exits 2
# =============================================================================
echo "--- test_exit2_when_test_gate_missing ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed" "no" "yes"

exit_code=0
cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    >/dev/null 2>&1 || exit_code=$?

assert_eq "missing test-gate-status exits 2" "2" "$exit_code"

assert_pass_if_clean "test_exit2_when_test_gate_missing"

# =============================================================================
# Test 3: test_exit2_when_review_status_missing
# Given: worktree branch with NO review-status artifact
# When: harvest-worktree.sh is invoked
# Then: exits 2
# =============================================================================
echo "--- test_exit2_when_review_status_missing ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed" "yes" "no"

exit_code=0
cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    >/dev/null 2>&1 || exit_code=$?

assert_eq "missing review-status exits 2" "2" "$exit_code"

assert_pass_if_clean "test_exit2_when_review_status_missing"

# =============================================================================
# Test 4: test_exit2_when_test_gate_failed
# Given: worktree branch with test-gate-status=failed
# When: harvest-worktree.sh is invoked
# Then: exits 2
# =============================================================================
echo "--- test_exit2_when_test_gate_failed ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "failed" "passed"

exit_code=0
cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    >/dev/null 2>&1 || exit_code=$?

assert_eq "failed test-gate-status exits 2" "2" "$exit_code"

assert_pass_if_clean "test_exit2_when_test_gate_failed"

# =============================================================================
# Test 5: test_exit1_on_non_test_index_conflict
# Given: session branch and worktree branch both modified same file (not .test-index)
# When: harvest-worktree.sh is invoked
# Then: exits 1 and merge is aborted
# =============================================================================
echo "--- test_exit1_on_non_test_index_conflict ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

# Create a conflict: modify file.txt on session branch too
cd "$SESSION_REPO" || exit 1
echo "session-side conflict content" > file.txt
git add file.txt
git commit -m "session conflict" >/dev/null 2>&1

# Also modify file.txt on worktree branch to create a real conflict
git checkout "$WORKTREE_BRANCH" >/dev/null 2>&1
echo "worktree-side conflict content" > file.txt
git add file.txt
git commit -m "worktree conflict" >/dev/null 2>&1
git checkout session-branch >/dev/null 2>&1

exit_code=0
cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    >/dev/null 2>&1 || exit_code=$?

assert_eq "non-test-index conflict exits 1" "1" "$exit_code"

assert_pass_if_clean "test_exit1_on_non_test_index_conflict"

# =============================================================================
# Test 6: test_merge_head_cleaned_on_failure
# Given: a merge that will fail (missing gate artifact)
# When: harvest-worktree.sh exits with error
# Then: MERGE_HEAD does not exist in the repo
# =============================================================================
echo "--- test_merge_head_cleaned_on_failure ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed" "no" "no"

exit_code=0
cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    >/dev/null 2>&1 || exit_code=$?

# Script must exist and run (not exit 127)
assert_ne "script was found (not 127)" "127" "$exit_code"

merge_head_exists="no"
if [[ -f "$SESSION_REPO/.git/MERGE_HEAD" ]]; then
    merge_head_exists="yes"
fi
assert_eq "MERGE_HEAD cleaned after failure" "no" "$merge_head_exists"

assert_pass_if_clean "test_merge_head_cleaned_on_failure"

# =============================================================================
# Test 7: test_no_merge_head_on_entry
# Given: MERGE_HEAD already exists in the repo
# When: harvest-worktree.sh is invoked
# Then: exits with error (non-zero) without attempting merge
# =============================================================================
echo "--- test_no_merge_head_on_entry ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

# Simulate stale MERGE_HEAD
cd "$SESSION_REPO" || exit 1
git_dir=$(git rev-parse --git-dir)
echo "deadbeef" > "$git_dir/MERGE_HEAD"

exit_code=0
output=$(cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    2>&1) || exit_code=$?

# Script must exist and run (not exit 127)
assert_ne "script was found (not 127)" "127" "$exit_code"
assert_ne "stale MERGE_HEAD causes non-zero exit" "0" "$exit_code"
assert_contains "error message mentions MERGE_HEAD" "MERGE_HEAD" "$output"

# Clean up stale MERGE_HEAD for safety
rm -f "$git_dir/MERGE_HEAD"

assert_pass_if_clean "test_no_merge_head_on_entry"

# =============================================================================
# Test 8: test_attest_source_in_status_files
# Given: worktree branch with passing gates
# When: harvest-worktree.sh completes successfully
# Then: attested status files in session artifacts contain attest_source field
# =============================================================================
echo "--- test_attest_source_in_status_files ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

# Create a session artifacts dir for harvested results
SESSION_ARTIFACTS="$tmpdir/session-artifacts"
mkdir -p "$SESSION_ARTIFACTS"

exit_code=0
cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    --session-artifacts "$SESSION_ARTIFACTS" \
    2>&1 || exit_code=$?

assert_eq "attest merge exits 0" "0" "$exit_code"

# Check that attested status files contain attest_source
test_gate_has_attest="no"
if [[ -f "$SESSION_ARTIFACTS/test-gate-status" ]]; then
    if grep -q "attest_source=" "$SESSION_ARTIFACTS/test-gate-status"; then
        test_gate_has_attest="yes"
    fi
fi
assert_eq "test-gate-status has attest_source" "yes" "$test_gate_has_attest"

review_has_attest="no"
if [[ -f "$SESSION_ARTIFACTS/review-status" ]]; then
    if grep -q "attest_source=" "$SESSION_ARTIFACTS/review-status"; then
        review_has_attest="yes"
    fi
fi
assert_eq "review-status has attest_source" "yes" "$review_has_attest"

assert_pass_if_clean "test_attest_source_in_status_files"

# =============================================================================
# Test 9: test_trap_cleans_merge_head_on_signal
# Given: harvest-worktree.sh is running a merge
# When: the process receives SIGTERM
# Then: MERGE_HEAD is cleaned up and index is restored
# =============================================================================
echo "--- test_trap_cleans_merge_head_on_signal ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

# We create a wrapper that introduces a sleep so we can send SIGTERM
cat > "$tmpdir/slow-harvest.sh" <<'WRAPPER'
#!/usr/bin/env bash
# Source the real script's trap setup, then sleep to allow signal delivery
HARVEST_SCRIPT="$1"; shift
# Run harvest in background, capture PID
bash "$HARVEST_SCRIPT" "$@" &
HARVEST_PID=$!
# Give it a moment to start the merge
sleep 0.5
# Send SIGTERM
kill -TERM $HARVEST_PID 2>/dev/null || true
wait $HARVEST_PID 2>/dev/null || true
WRAPPER
chmod +x "$tmpdir/slow-harvest.sh"

# Pre-check: script must exist to test signal handling
if [[ ! -f "$HARVEST_SCRIPT" ]]; then
    (( ++FAIL ))
    printf "FAIL: %s\n  %s\n" "harvest-worktree.sh must exist for signal test" "script not found at $HARVEST_SCRIPT" >&2
else
    cd "$SESSION_REPO" && bash "$tmpdir/slow-harvest.sh" \
        "$HARVEST_SCRIPT" \
        "$WORKTREE_BRANCH" \
        "$ARTIFACTS_DIR" \
        >/dev/null 2>&1 || true

    merge_head_after_signal="no"
    if [[ -f "$SESSION_REPO/.git/MERGE_HEAD" ]]; then
        merge_head_after_signal="yes"
    fi
    assert_eq "MERGE_HEAD cleaned after SIGTERM" "no" "$merge_head_after_signal"
fi

assert_pass_if_clean "test_trap_cleans_merge_head_on_signal"

# =============================================================================
# Test 10: test_already_merged_branch_noop
# Given: worktree branch is already merged into session branch
# When: harvest-worktree.sh is invoked
# Then: exits 0 gracefully (no-op)
# =============================================================================
echo "--- test_already_merged_branch_noop ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

# Merge the worktree branch manually first
cd "$SESSION_REPO" || exit 1
git merge "$WORKTREE_BRANCH" --no-edit >/dev/null 2>&1

# Now invoke harvest — branch is already merged
exit_code=0
output=$(cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    2>&1) || exit_code=$?

assert_eq "already-merged branch exits 0" "0" "$exit_code"

assert_pass_if_clean "test_already_merged_branch_noop"

# =============================================================================
# Test 11: test_conflict_diagnostic_printed_to_stderr (bug 0fc6-c970)
# Given: session branch and worktree branch both modified same file (not .test-index)
# When: harvest-worktree.sh exits 1 on conflict
# Then: stderr includes the conflicted filename so the operator knows what to fix
# =============================================================================
echo "--- test_conflict_diagnostic_printed_to_stderr ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

# Create a conflict: modify file.txt on session branch
cd "$SESSION_REPO" || exit 1
echo "session-side conflict content" > file.txt
git add file.txt
git commit -m "session conflict" >/dev/null 2>&1

# Also modify file.txt on worktree branch to create a real conflict
git checkout "$WORKTREE_BRANCH" >/dev/null 2>&1
echo "worktree-side conflict content" > file.txt
git add file.txt
git commit -m "worktree conflict" >/dev/null 2>&1
git checkout session-branch >/dev/null 2>&1

# Capture stderr to check diagnostic output
stderr_output=""
exit_code=0
stderr_output=$(cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    2>&1 >/dev/null) || exit_code=$?

assert_eq "conflict exits 1" "1" "$exit_code"

# Verify that the conflicted filename appears in the diagnostic output
if echo "$stderr_output" | grep -q "file.txt"; then
    (( ++PASS ))
    echo "PASS: conflict diagnostic includes conflicted filename"
else
    (( ++FAIL ))
    echo "FAIL: conflict diagnostic missing conflicted filename in stderr" >&2
    echo "  stderr was: $stderr_output" >&2
fi

assert_pass_if_clean "test_conflict_diagnostic_printed_to_stderr"

# =============================================================================
# Test 12: test_nonexistent_branch_exits1_with_message (bug 0fc6-c970)
# Given: worktree branch name that does not exist (non-conflict git failure)
# When: harvest-worktree.sh is invoked
# Then: exits 1 and stderr includes "git merge failed" (not silent exit 0)
# =============================================================================
echo "--- test_nonexistent_branch_exits1_with_message ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

# Use a branch name guaranteed not to exist
MISSING_BRANCH="nonexistent-branch-$$"

stderr_output=""
exit_code=0
stderr_output=$(cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$MISSING_BRANCH" \
    "$ARTIFACTS_DIR" \
    2>&1 >/dev/null) || exit_code=$?

assert_eq "nonexistent branch exits 1" "1" "$exit_code"

if echo "$stderr_output" | grep -q "git merge failed"; then
    (( ++PASS ))
    echo "PASS: nonexistent branch produces git merge failed message"
else
    (( ++FAIL ))
    echo "FAIL: nonexistent branch did not produce git merge failed message" >&2
    echo "  stderr was: $stderr_output" >&2
fi

assert_pass_if_clean "test_nonexistent_branch_exits1_with_message"

# =============================================================================
# Test 13: test_cleanup_removes_worktree_after_successful_merge (afdb-8418)
# Given: agent branch checked out as a real git worktree at a known path
# When: harvest-worktree.sh merges it successfully
# Then: exit code is 0, the worktree directory no longer exists on disk,
#       and `git worktree list --porcelain` no longer contains the removed path
# =============================================================================
echo "--- test_cleanup_removes_worktree_after_successful_merge ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

# Add the worktree branch as an actual git worktree at a known path
AGENT_WORKTREE_PATH="$tmpdir/session/.claude/worktrees/$WORKTREE_BRANCH"
mkdir -p "$(dirname "$AGENT_WORKTREE_PATH")"
(cd "$tmpdir/session" && git worktree add "$AGENT_WORKTREE_PATH" "$WORKTREE_BRANCH" >/dev/null 2>&1)

# Confirm the worktree exists before harvest
worktree_before="no"
if [[ -d "$AGENT_WORKTREE_PATH" ]]; then
    worktree_before="yes"
fi
assert_eq "worktree directory exists before harvest" "yes" "$worktree_before"

exit_code=0
output=$(cd "$tmpdir/session" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    2>&1) || exit_code=$?

assert_eq "cleanup merge exits 0" "0" "$exit_code"

# Assert: worktree directory removed from disk
worktree_after="no"
if [[ -d "$AGENT_WORKTREE_PATH" ]]; then
    worktree_after="yes"
fi
assert_eq "worktree directory removed after merge" "no" "$worktree_after"

# Assert: git worktree list no longer contains the path
worktree_in_list="no"
if (cd "$tmpdir/session" && git worktree list --porcelain 2>/dev/null) | grep -qF "worktree $AGENT_WORKTREE_PATH"; then
    worktree_in_list="yes"
fi
assert_eq "git worktree list excludes removed path" "no" "$worktree_in_list"

assert_pass_if_clean "test_cleanup_removes_worktree_after_successful_merge"

# =============================================================================
# Test 14: test_cleanup_deletes_backing_branch_after_successful_merge (afdb-8418)
# Given: agent branch checked out as a real git worktree
# When: harvest-worktree.sh merges it successfully
# Then: exit code is 0 AND `git branch --list <branch>` returns empty
# =============================================================================
echo "--- test_cleanup_deletes_backing_branch_after_successful_merge ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

AGENT_WORKTREE_PATH="$tmpdir/session/.claude/worktrees/$WORKTREE_BRANCH"
mkdir -p "$(dirname "$AGENT_WORKTREE_PATH")"
(cd "$tmpdir/session" && git worktree add "$AGENT_WORKTREE_PATH" "$WORKTREE_BRANCH" >/dev/null 2>&1)

# Confirm branch exists before harvest
branch_before=$(cd "$tmpdir/session" && git branch --list "$WORKTREE_BRANCH")
assert_ne "branch exists before harvest" "" "$branch_before"

exit_code=0
cd "$tmpdir/session" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    >/dev/null 2>&1 || exit_code=$?

assert_eq "cleanup merge exits 0" "0" "$exit_code"

# Assert: backing branch deleted
branch_after=$(cd "$tmpdir/session" && git branch --list "$WORKTREE_BRANCH")
assert_eq "backing branch deleted after merge" "" "$branch_after"

assert_pass_if_clean "test_cleanup_deletes_backing_branch_after_successful_merge"

# =============================================================================
# Test 15: test_cleanup_skipped_on_gate_failure (afdb-8418)
# Given: agent branch checked out as a real git worktree, but test-gate-status=failed
# When: harvest-worktree.sh is invoked (exits 2 due to gate failure)
# Then: exit code is 2, the worktree directory still exists, the branch still exists
# =============================================================================
echo "--- test_cleanup_skipped_on_gate_failure ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "failed" "passed"

AGENT_WORKTREE_PATH="$tmpdir/session/.claude/worktrees/$WORKTREE_BRANCH"
mkdir -p "$(dirname "$AGENT_WORKTREE_PATH")"
(cd "$tmpdir/session" && git worktree add "$AGENT_WORKTREE_PATH" "$WORKTREE_BRANCH" >/dev/null 2>&1)

exit_code=0
cd "$tmpdir/session" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    >/dev/null 2>&1 || exit_code=$?

assert_eq "gate failure exits 2" "2" "$exit_code"

# Assert: worktree directory preserved
worktree_still_there="no"
if [[ -d "$AGENT_WORKTREE_PATH" ]]; then
    worktree_still_there="yes"
fi
assert_eq "worktree directory preserved on gate failure" "yes" "$worktree_still_there"

# Assert: branch preserved
branch_still_there=$(cd "$tmpdir/session" && git branch --list "$WORKTREE_BRANCH")
assert_ne "branch preserved on gate failure" "" "$branch_still_there"

assert_pass_if_clean "test_cleanup_skipped_on_gate_failure"

# =============================================================================
# Test 16: test_cleanup_handles_missing_worktree_gracefully (afdb-8418)
# Given: a branch that passes gates but has NO backing git worktree directory
#        (plain branch in session repo, no `git worktree add` was performed)
# When: harvest-worktree.sh is invoked
# Then: exit code is 0 (merge succeeds), script does not error on missing worktree path
# =============================================================================
echo "--- test_cleanup_handles_missing_worktree_gracefully ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

# Intentionally do NOT add a git worktree for WORKTREE_BRANCH —
# the branch exists but there is no worktree directory backing it.

# Confirm no worktree path exists for the branch
worktree_path_for_branch=""
worktree_path_for_branch=$(cd "$tmpdir/session" && git worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{path=$2} /^branch /{if ($2 ~ /'"$WORKTREE_BRANCH"'$/) print path}' \
    || true)

assert_eq "no worktree path for branch before harvest" "" "$worktree_path_for_branch"

exit_code=0
output=$(cd "$tmpdir/session" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    2>&1) || exit_code=$?

assert_eq "no-worktree branch merge exits 0" "0" "$exit_code"

assert_pass_if_clean "test_cleanup_handles_missing_worktree_gracefully"

# =============================================================================
# Test 17: test_exit0_when_failed_tests_all_have_red_markers (6810-8607)
# Given: worktree branch with test-gate-status=failed, but all failed_tests
#        have RED markers in the worktree's .test-index
# When: harvest-worktree.sh is invoked
# Then: exits 0 — RED-marker-only failures are exempt from the harvest gate
# =============================================================================
echo "--- test_exit0_when_failed_tests_all_have_red_markers ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

# Add .test-index with RED marker to the worktree branch
git -C "$SESSION_REPO" checkout "$WORKTREE_BRANCH" >/dev/null 2>&1
printf '%s\n' "src/newfeature.py: tests/test_newfeature.sh [test_new_behavior]" \
    > "$SESSION_REPO/.test-index"
git -C "$SESSION_REPO" add .test-index
git -C "$SESSION_REPO" commit -m "add test-index red marker" >/dev/null 2>&1
git -C "$SESSION_REPO" checkout session-branch >/dev/null 2>&1

# Compute a valid-format diff_hash from the worktree branch's last commit
_wt_diff_hash=$(git -C "$SESSION_REPO" show "$WORKTREE_BRANCH" --format='' | shasum -a 256 | cut -d' ' -f1)

# Override test-gate-status: failed with failed_tests matching the RED-marked test
# (diff_hash must be a valid 64-char SHA-256 hex string for --attest to accept it)
cat > "$ARTIFACTS_DIR/test-gate-status" <<EOF
failed
diff_hash=${_wt_diff_hash}
timestamp=2026-01-01T00:00:00Z
tested_files=tests/test_newfeature.sh
failed_tests=tests/test_newfeature.sh
EOF

exit_code=0
cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    >/dev/null 2>&1 || exit_code=$?

assert_eq "red-marker failed tests: harvest exits 0" "0" "$exit_code"

assert_pass_if_clean "test_exit0_when_failed_tests_all_have_red_markers"

# =============================================================================
# Test 18: test_complete_comment_written_on_success (ed2b-9e72 / WORKTREE_TRACKING)
# Given: harvest-worktree.sh called with --ticket-id test-ticket-123 and a
#        valid worktree branch with passing gates
# When: the merge completes successfully (exit 0)
# Then: the ticket comment command was invoked with "WORKTREE_TRACKING:complete"
#       and "outcome=merged"
# =============================================================================
echo "--- test_complete_comment_written_on_success ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

# Create a stub .claude/scripts/dso that logs all calls to a file
STUB_BIN_DIR="$tmpdir/stub-bin"
mkdir -p "$STUB_BIN_DIR"
STUB_CALL_LOG="$tmpdir/dso-calls.log"
cat > "$STUB_BIN_DIR/dso" <<STUBEOF
#!/usr/bin/env bash
# Stub: log all arguments to call log, then exit 0
echo "\$@" >> "$STUB_CALL_LOG"
exit 0
STUBEOF
chmod +x "$STUB_BIN_DIR/dso"

exit_code=0
output=$(cd "$SESSION_REPO" && PATH="$STUB_BIN_DIR:$PATH" bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    --ticket-id "test-ticket-123" \
    2>&1) || exit_code=$?

assert_eq "complete-on-success: harvest exits 0" "0" "$exit_code"

# Assert: stub was called with WORKTREE_TRACKING:complete and outcome=merged
stub_invoked="no"
if [[ -f "$STUB_CALL_LOG" ]]; then
    stub_invoked="yes"
fi
assert_eq "complete-on-success: ticket CLI was invoked" "yes" "$stub_invoked"

tracking_comment_found="no"
if [[ -f "$STUB_CALL_LOG" ]] && grep -q "WORKTREE_TRACKING:complete" "$STUB_CALL_LOG" && grep -q "outcome=merged" "$STUB_CALL_LOG"; then
    tracking_comment_found="yes"
fi
assert_eq "complete-on-success: comment contains WORKTREE_TRACKING:complete and outcome=merged" "yes" "$tracking_comment_found"

assert_pass_if_clean "test_complete_comment_written_on_success"

# =============================================================================
# Test 19: test_complete_comment_written_on_failure (ed2b-9e72 / WORKTREE_TRACKING)
# Given: harvest-worktree.sh called with --ticket-id test-ticket-123 and a
#        branch that causes a gate failure (test-gate-status=failed)
# When: the script exits non-zero (gate failure)
# Then: WORKTREE_TRACKING:complete written with outcome=discarded
# =============================================================================
echo "--- test_complete_comment_written_on_failure ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "failed" "passed"

# Create a stub .claude/scripts/dso that logs all calls to a file
STUB_BIN_DIR="$tmpdir/stub-bin"
mkdir -p "$STUB_BIN_DIR"
STUB_CALL_LOG="$tmpdir/dso-calls.log"
cat > "$STUB_BIN_DIR/dso" <<STUBEOF
#!/usr/bin/env bash
# Stub: log all arguments to call log, then exit 0
echo "\$@" >> "$STUB_CALL_LOG"
exit 0
STUBEOF
chmod +x "$STUB_BIN_DIR/dso"

cd "$SESSION_REPO" && PATH="$STUB_BIN_DIR:$PATH" bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    --ticket-id "test-ticket-123" \
    >/dev/null 2>&1 || true

# Assert: stub was called with WORKTREE_TRACKING:complete and outcome=discarded
stub_invoked="no"
if [[ -f "$STUB_CALL_LOG" ]]; then
    stub_invoked="yes"
fi
assert_eq "complete-on-failure: ticket CLI was invoked" "yes" "$stub_invoked"

tracking_discard_found="no"
if [[ -f "$STUB_CALL_LOG" ]] && grep -q "WORKTREE_TRACKING:complete" "$STUB_CALL_LOG" && grep -q "outcome=discarded" "$STUB_CALL_LOG"; then
    tracking_discard_found="yes"
fi
assert_eq "complete-on-failure: comment contains WORKTREE_TRACKING:complete and outcome=discarded" "yes" "$tracking_discard_found"

assert_pass_if_clean "test_complete_comment_written_on_failure"

# =============================================================================
# Test 20: test_harvest_errors_when_called_from_inside_worktree (d888-632b)
# Given: a real git worktree exists for WORKTREE_BRANCH at $tmpdir/agent-wt/
# When: harvest-worktree.sh is invoked with CWD inside that worktree
# Then: exits non-zero (error) — NOT 0 / "already merged" — because HEAD
#       inside the agent worktree resolves to WORKTREE_BRANCH itself, making
#       the --is-ancestor check trivially true (false "already merged")
#       unless a CWD-guard detects and rejects the invocation.
# =============================================================================
echo "--- test_harvest_errors_when_called_from_inside_worktree ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

# Create a real git worktree for WORKTREE_BRANCH at $tmpdir/agent-wt/
AGENT_WORKTREE_PATH="$tmpdir/agent-wt"
(cd "$SESSION_REPO" && git worktree add "$AGENT_WORKTREE_PATH" "$WORKTREE_BRANCH" >/dev/null 2>&1)

# Call harvest from WITHIN the agent worktree (CWD = AGENT_WORKTREE_PATH)
exit_code=0
output=$(cd "$AGENT_WORKTREE_PATH" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    2>&1) || exit_code=$?

# Assert: harvest must exit non-zero — calling from inside the worktree is an error
assert_ne "harvest exits non-zero when called from inside the worktree (d888-632b)" \
    "0" "$exit_code"

# Assert: error message must NOT say "already merged" (that would be the false-negative)
already_merged_in_output="no"
if echo "$output" | grep -qi "already merged"; then
    already_merged_in_output="yes"
fi
assert_eq "harvest must NOT report false 'already merged' when called from inside worktree (d888-632b)" \
    "no" "$already_merged_in_output"

assert_pass_if_clean "test_harvest_errors_when_called_from_inside_worktree"

# =============================================================================
# Test 21: test_branch_deleted_in_no_worktree_case (a44a-0f63 regression guard)
# Given: WORKTREE_BRANCH has passing gates but NO backing git worktree
#        (plain branch in session repo — no `git worktree add` was performed)
# When: harvest-worktree.sh merges it successfully
# Then: exit code is 0 AND the branch no longer exists in `git branch --list`
# This guards against a naive fix that moves `git branch -D` inside the
# worktree-guard `if` block without an `else` — which would silently skip
# branch deletion in the no-worktree case.
# =============================================================================
echo "--- test_branch_deleted_in_no_worktree_case ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

# Confirm no backing worktree for the branch
wt_path_before=""
wt_path_before=$(cd "$SESSION_REPO" && git worktree list --porcelain 2>/dev/null \
    | awk '/^worktree /{p=$2}/branch refs\/heads\/'"$WORKTREE_BRANCH"'/{print p}' || true)
assert_eq "no backing worktree before harvest" "" "$wt_path_before"

exit_code=0
cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    >/dev/null 2>&1 || exit_code=$?

assert_eq "no-worktree harvest exits 0" "0" "$exit_code"

branch_after=$(cd "$SESSION_REPO" && git branch --list "$WORKTREE_BRANCH")
assert_eq "branch deleted after harvest in no-worktree case (a44a-0f63)" "" "$branch_after"

assert_pass_if_clean "test_branch_deleted_in_no_worktree_case"

# =============================================================================
# Test 22: test_empty_branch_exits3_when_expected_base_provided (1eda-6a0c)
# Given: a worktree branch whose tip == the base commit (no new commits made,
#        e.g. because the pre-commit hook blocked the agent's commit)
# When: harvest-worktree.sh is called with --expected-base <base-sha>
# Then: exits 3 with EMPTY_BRANCH in stderr (NOT exit 0 "already merged")
# This is a RED test — it documents the desired behavior BEFORE the fix.
# =============================================================================
echo "--- test_empty_branch_exits3_when_expected_base_provided ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
# Set up a repo with a session branch and a worktree branch that has NO commits
# beyond the session-branch base (simulates a pre-commit-blocked agent).
git init --bare "$tmpdir/origin22.git" >/dev/null 2>&1
git clone "$tmpdir/origin22.git" "$tmpdir/session22" >/dev/null 2>&1
SESSION_REPO22="$tmpdir/session22"
cd "$SESSION_REPO22" || exit 1
git config user.email "test@test.com"
git config user.name "Test"
echo "initial" > file.txt
git add file.txt
git commit -m "initial" >/dev/null 2>&1
git checkout -b session-branch22 >/dev/null 2>&1

# Record the base commit BEFORE creating the worktree branch
BASE_SHA22=$(git rev-parse HEAD)

# Create a worktree branch with NO new commits (tip == base — agent commit was blocked)
WORKTREE_BRANCH22="worktree-empty-$$-$RANDOM"
git checkout -b "$WORKTREE_BRANCH22" >/dev/null 2>&1
git checkout session-branch22 >/dev/null 2>&1

# Create artifacts dir with passing gates (review and tests "passed" in the worktree)
ARTIFACTS22="$tmpdir/artifacts22"
mkdir -p "$ARTIFACTS22"
echo "passed" > "$ARTIFACTS22/test-gate-status"
echo "passed" > "$ARTIFACTS22/review-status"

# harvest with --expected-base: should emit EMPTY_BRANCH and exit 3
exit_code22=0
output22=$(cd "$SESSION_REPO22" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH22" \
    "$ARTIFACTS22" \
    --expected-base "$BASE_SHA22" \
    2>&1) || exit_code22=$?

assert_eq "empty branch with --expected-base exits 3 (1eda-6a0c)" "3" "$exit_code22"

empty_branch_in_output22="no"
if echo "$output22" | grep -q "EMPTY_BRANCH"; then
    empty_branch_in_output22="yes"
fi
assert_eq "EMPTY_BRANCH in stderr when tip == base (1eda-6a0c)" "yes" "$empty_branch_in_output22"

assert_pass_if_clean "test_empty_branch_exits3_when_expected_base_provided"

# =============================================================================
# Test 23: test_empty_branch_exits3_when_base_commit_file_present (1eda-6a0c)
# Given: same empty-branch scenario, but base commit recorded in artifacts/base-commit
#        (not passed via --expected-base flag)
# When: harvest-worktree.sh is called WITHOUT --expected-base
# Then: exits 3 with EMPTY_BRANCH (reads base from artifacts/base-commit file)
# =============================================================================
echo "--- test_empty_branch_exits3_when_base_commit_file_present ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
git init --bare "$tmpdir/origin23.git" >/dev/null 2>&1
git clone "$tmpdir/origin23.git" "$tmpdir/session23" >/dev/null 2>&1
SESSION_REPO23="$tmpdir/session23"
cd "$SESSION_REPO23" || exit 1
git config user.email "test@test.com"
git config user.name "Test"
echo "initial" > file.txt
git add file.txt
git commit -m "initial" >/dev/null 2>&1
git checkout -b session-branch23 >/dev/null 2>&1

BASE_SHA23=$(git rev-parse HEAD)
WORKTREE_BRANCH23="worktree-empty2-$$-$RANDOM"
git checkout -b "$WORKTREE_BRANCH23" >/dev/null 2>&1
git checkout session-branch23 >/dev/null 2>&1

ARTIFACTS23="$tmpdir/artifacts23"
mkdir -p "$ARTIFACTS23"
echo "passed" > "$ARTIFACTS23/test-gate-status"
echo "passed" > "$ARTIFACTS23/review-status"
echo "$BASE_SHA23" > "$ARTIFACTS23/base-commit"

exit_code23=0
output23=$(cd "$SESSION_REPO23" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH23" \
    "$ARTIFACTS23" \
    2>&1) || exit_code23=$?

assert_eq "empty branch via base-commit file exits 3 (1eda-6a0c)" "3" "$exit_code23"

empty_branch_in_output23="no"
if echo "$output23" | grep -q "EMPTY_BRANCH"; then
    empty_branch_in_output23="yes"
fi
assert_eq "EMPTY_BRANCH in stderr via artifacts/base-commit (1eda-6a0c)" "yes" "$empty_branch_in_output23"

assert_pass_if_clean "test_empty_branch_exits3_when_base_commit_file_present"

# =============================================================================
echo "--- test_harvest_reads_preconditions_summary ---"
# After a successful merge, harvest-worktree.sh must read PRECONDITIONS context
# via _read_latest_preconditions (sourced from ticket-lib.sh) and log it to stderr.
# RED: harvest-worktree.sh does not yet source ticket-lib.sh or call _read_latest_preconditions.
_harvest_has_preconditions=0
if grep -qE "_read_latest_preconditions|ticket-lib\.sh" "$HARVEST_SCRIPT" 2>/dev/null; then
    _harvest_has_preconditions=1
fi
assert_eq "test_harvest_reads_preconditions_summary: harvest-worktree.sh references _read_latest_preconditions" \
    "1" "$_harvest_has_preconditions"
assert_pass_if_clean "test_harvest_reads_preconditions_summary"

# =============================================================================
echo "--- test_harvest_preconditions_zero_events_no_regression ---"
# harvest-worktree.sh must guard _read_latest_preconditions with || true so that
# tickets with zero PRECONDITIONS events (pre-manifest / legacy) do not break harvest.
# RED: harvest-worktree.sh has no such guard because the call doesn't exist yet.
_harvest_has_guard=0
if grep -qE "_read_latest_preconditions.*\|\|" "$HARVEST_SCRIPT" 2>/dev/null || \
   grep -A2 "_read_latest_preconditions" "$HARVEST_SCRIPT" 2>/dev/null | grep -qE "\|\| true|\|\| :"; then
    _harvest_has_guard=1
fi
assert_eq "test_harvest_preconditions_zero_events_no_regression: harvest guards _read_latest_preconditions with || true" \
    "1" "$_harvest_has_guard"
assert_pass_if_clean "test_harvest_preconditions_zero_events_no_regression"

# =============================================================================
# Test: harvest-worktree.sh copies reviewer-findings*.json from worktree to session
# =============================================================================
# When deep-tier review runs inside a sub-agent worktree, the per-specialist findings
# files (reviewer-findings-{a,b,c}.json) and the canonical reviewer-findings.json sit
# in the worktree's artifacts dir. Harvest must bring them back to session artifacts
# alongside the attested review-status, so the orchestrator can read individual
# specialist findings for remediation and the chain of evidence is preserved.
echo "--- test_harvest_copies_reviewer_findings_files ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_test_repo "$tmpdir" "passed" "passed"

# Pre-populate the worktree artifacts dir with reviewer-findings files
echo '{"scores":{"correctness":4},"findings":[],"summary":"slot a","review_tier":"deep"}' \
    > "$ARTIFACTS_DIR/reviewer-findings-a.json"
echo '{"scores":{"verification":4},"findings":[],"summary":"slot b","review_tier":"deep"}' \
    > "$ARTIFACTS_DIR/reviewer-findings-b.json"
echo '{"scores":{"hygiene":4},"findings":[],"summary":"slot c","review_tier":"deep"}' \
    > "$ARTIFACTS_DIR/reviewer-findings-c.json"
echo '{"scores":{"correctness":4,"verification":4,"hygiene":4},"findings":[],"summary":"arch","review_tier":"deep"}' \
    > "$ARTIFACTS_DIR/reviewer-findings.json"

SESSION_ARTIFACTS_DIR="$tmpdir/session-artifacts"
mkdir -p "$SESSION_ARTIFACTS_DIR"

cd "$SESSION_REPO" && bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    --session-artifacts "$SESSION_ARTIFACTS_DIR" \
    >/dev/null 2>&1 || true

# All four files (3 slots + canonical) must be present in session artifacts after harvest.
_slot_a_present=$(test -f "$SESSION_ARTIFACTS_DIR/reviewer-findings-a.json" && echo found || echo missing)
_slot_b_present=$(test -f "$SESSION_ARTIFACTS_DIR/reviewer-findings-b.json" && echo found || echo missing)
_slot_c_present=$(test -f "$SESSION_ARTIFACTS_DIR/reviewer-findings-c.json" && echo found || echo missing)
_canonical_present=$(test -f "$SESSION_ARTIFACTS_DIR/reviewer-findings.json" && echo found || echo missing)

assert_eq "test_harvest_copies_reviewer_findings_files: slot a copied" "found" "$_slot_a_present"
assert_eq "test_harvest_copies_reviewer_findings_files: slot b copied" "found" "$_slot_b_present"
assert_eq "test_harvest_copies_reviewer_findings_files: slot c copied" "found" "$_slot_c_present"
assert_eq "test_harvest_copies_reviewer_findings_files: canonical copied" "found" "$_canonical_present"

assert_pass_if_clean "test_harvest_copies_reviewer_findings_files"

# =============================================================================
print_summary
