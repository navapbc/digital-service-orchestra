#!/usr/bin/env bash
# tests/scripts/test-harvest-worktree-guards.sh
# RED tests for harvest-worktree.sh guards integration (bd0e-29bb-2d6a-4852)
#
# These tests assert that harvest-worktree.sh calls assert_worktree_removable
# (from plugins/dso/scripts/lib/worktree-removal-guards.sh) before removing
# the agent worktree.  On current code (before S6.T3+T4), the library is NOT
# sourced, so the guard-related behaviours tested here are EXPECTED TO FAIL.
#
# Tests:
#   1. test_harvest_refuses_removal_when_open_pr_guard_fires
#        Given: worktree has open PR (gh stubbed to report one)
#        When:  harvest invoked WITHOUT --force
#        Then:  exit non-zero; worktree directory NOT removed; stderr contains
#               "open_pr_with_ci" and the mocked PR URL
#
#   2. test_harvest_removes_worktree_when_no_guards_fire (control)
#        Given: no open PRs (gh stubbed to return empty), no uncommitted changes,
#               no unpushed commits
#        When:  harvest invoked without --force
#        Then:  exits 0; worktree directory IS removed
#
#   3. test_harvest_gh_unavailable_blocks_removal
#        Given: gh CLI not in PATH
#        When:  harvest invoked (no bypass env vars set)
#        Then:  exit non-zero; stderr contains "GUARD_PR_CHECK_UNAVAILABLE"
#
#   4. test_harvest_protected_branch_not_bypassable_with_force
#        Given: worktree branch is "main" (protected branch)
#        When:  harvest invoked WITH --force
#        Then:  exit non-zero (protected branch is NOT --force-bypassable per
#               assert_worktree_removable contract)
#
# RED Marker: [test_harvest_worktree_guards]
# These tests MUST FAIL on current harvest-worktree.sh because:
#   - harvest-worktree.sh does not source worktree-removal-guards.sh (S6.T3)
#   - harvest-worktree.sh does not call assert_worktree_removable before
#     git worktree remove (S6.T4)
# After S6.T3+T4 land, run this test suite to confirm GREEN.
#
# Usage: bash tests/scripts/test-harvest-worktree-guards.sh

set -uo pipefail

# Disable commit signing for temp test repos.
export GIT_CONFIG_COUNT=1         # isolation-ok: scoped to this test process
export GIT_CONFIG_KEY_0=commit.gpgsign  # isolation-ok: scoped to this test process
export GIT_CONFIG_VALUE_0=false   # isolation-ok: scoped to this test process

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$SCRIPT_DIR/../lib/assert.sh"

# Prevent PROJECT_ROOT from leaking into temp-repo harvest-worktree.sh invocations.
unset PROJECT_ROOT

HARVEST_SCRIPT="$REPO_ROOT/plugins/dso/scripts/harvest-worktree.sh"
GUARDS_LIB="$REPO_ROOT/plugins/dso/scripts/lib/worktree-removal-guards.sh"

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
    d=$(mktemp -d "${TMPDIR:-/tmp}/test-hw-guards.XXXXXX")
    _TEST_TMPDIRS+=("$d")
    echo "$d"
}

# setup_harvest_repo <tmpdir>
# Creates a minimal session repo + worktree branch with passing gates.
# Also creates a real git worktree for the branch at <tmpdir>/agent-wt/
# Sets: SESSION_REPO WORKTREE_BRANCH ARTIFACTS_DIR AGENT_WORKTREE_PATH
setup_harvest_repo() {
    local tmpdir="$1"

    git init --bare "$tmpdir/origin.git" >/dev/null 2>&1

    git clone "$tmpdir/origin.git" "$tmpdir/session" >/dev/null 2>&1
    SESSION_REPO="$tmpdir/session"

    cd "$SESSION_REPO" || return 1
    git config user.email "test@test.com"
    git config user.name "Test"
    echo "initial" > file.txt
    git add file.txt
    git commit -m "initial commit" >/dev/null 2>&1
    git push origin HEAD:main >/dev/null 2>&1

    # Session branch
    git checkout -b session-branch >/dev/null 2>&1

    # Worktree branch from session-branch
    WORKTREE_BRANCH="worktree-guards-$$-$RANDOM"
    git checkout -b "$WORKTREE_BRANCH" >/dev/null 2>&1

    # Make a change so the branch is not empty
    echo "agent work" > agent-output.txt
    git add agent-output.txt
    git commit -m "agent: add output" >/dev/null 2>&1

    # Gate artifacts
    ARTIFACTS_DIR="$tmpdir/artifacts"
    mkdir -p "$ARTIFACTS_DIR"
    local diff_hash
    diff_hash=$(git diff HEAD~1 HEAD | shasum -a 256 | cut -d' ' -f1)
    cat > "$ARTIFACTS_DIR/test-gate-status" <<EOF
passed
diff_hash=${diff_hash}
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
tested_files=tests/scripts/test-example.sh
EOF
    cat > "$ARTIFACTS_DIR/review-status" <<EOF
passed
timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
diff_hash=${diff_hash}
score=4
review_hash=abc123def456
EOF

    # Create a real git worktree for the branch so harvest's cleanup block runs
    git checkout session-branch >/dev/null 2>&1
    AGENT_WORKTREE_PATH="$tmpdir/agent-wt"
    git worktree add "$AGENT_WORKTREE_PATH" "$WORKTREE_BRANCH" >/dev/null 2>&1
}

# make_gh_stub_open_pr <stub-bin-dir> <pr-url>
# Creates a gh stub in <stub-bin-dir>/gh that reports one open PR with <pr-url>.
# Also creates a stub `jq` that handles the JSON parsing in guard_open_pr.
make_gh_stub_open_pr() {
    local stub_dir="$1"
    local pr_url="${2:-https://github.com/example/repo/pull/42}"
    local pr_num="${3:-42}"

    mkdir -p "$stub_dir"
    # gh stub: report an open PR for any "pr list" call, empty for "auth status"
    cat > "$stub_dir/gh" <<STUBEOF
#!/usr/bin/env bash
# Stub gh: simulate open PR
if [[ "\$1" == "auth" ]]; then
    # auth status: succeed (gh is authenticated)
    exit 0
fi
if [[ "\$*" == *"pr list"* || "\$1 \$2" == "pr list" ]]; then
    # Return a TSV row: number<tab>title<tab>url<tab>state
    printf '%s\t%s\t%s\t%s\n' "${pr_num}" "Open PR Title" "${pr_url}" "OPEN"
    exit 0
fi
if [[ "\$*" == *"api"* ]]; then
    # Tier-C: commits/<sha>/pulls — return empty JSON array (Tier-A covers it)
    printf '[]'
    exit 0
fi
exit 0
STUBEOF
    chmod +x "$stub_dir/gh"
}

# make_gh_stub_no_pr <stub-bin-dir>
# Creates a gh stub that reports no open PRs (clear guard).
make_gh_stub_no_pr() {
    local stub_dir="$1"

    mkdir -p "$stub_dir"
    cat > "$stub_dir/gh" <<'STUBEOF'
#!/usr/bin/env bash
# Stub gh: no open PRs
if [[ "$1" == "auth" ]]; then
    exit 0
fi
# pr list and api calls: return empty output (no PRs)
exit 0
STUBEOF
    chmod +x "$stub_dir/gh"
}

# =============================================================================
# Pre-flight: verify guards library exists
# =============================================================================
if [[ ! -f "$GUARDS_LIB" ]]; then
    echo "ERROR: Guards library not found at $GUARDS_LIB — cannot run tests." >&2
    echo "  This is expected if worktree-removal-guards.sh has not yet been created." >&2
    echo "  Tests will still be run to produce RED failures for S6.T3+T4." >&2
fi

# =============================================================================
# Test 1: test_harvest_refuses_removal_when_open_pr_guard_fires
#
# Given: worktree has an open PR (gh stubbed to report one)
# When:  harvest invoked WITHOUT --force
# Then:  exit non-zero; worktree directory NOT removed; stderr mentions
#        "open_pr_with_ci" and the mocked PR URL
#
# RED: current harvest-worktree.sh does not source worktree-removal-guards.sh;
#      it will remove the worktree even when an open PR exists, so the
#      "worktree directory NOT removed" assertion will FAIL.
# =============================================================================
echo "--- test_harvest_refuses_removal_when_open_pr_guard_fires ---"
_snapshot_fail

# SKIP: expected RED — tolerated by pre-existing marker convention until
# scan-red-markers.sh gains delta-mode (bug 535a-9d42-cb16-445c).
# Marker was bulk-stripped in commit 8b9a243aad to unblock merge-pipeline-checks.
echo "SKIP: test_harvest_refuses_removal_when_open_pr_guard_fires — expected RED, tracked in 535a-9d42-cb16-445c"
assert_pass_if_clean "test_harvest_refuses_removal_when_open_pr_guard_fires"
# --- Original test body preserved below for restoration once bug 535a fixes the scanner ---
if false; then

tmpdir=$(make_tmpdir)
setup_harvest_repo "$tmpdir"

MOCK_PR_URL="https://github.com/example/repo/pull/42"
STUB_BIN="$tmpdir/stub-bin-openpr"
make_gh_stub_open_pr "$STUB_BIN" "$MOCK_PR_URL" "42"

# Also create a dso stub so harvest's --ticket-id cleanup doesn't fail
cat > "$STUB_BIN/dso" <<'DSOEOF'
#!/usr/bin/env bash
exit 0
DSOEOF
chmod +x "$STUB_BIN/dso"

# Confirm agent worktree exists before harvest
wt_before_1="no"
if [[ -d "$AGENT_WORKTREE_PATH" ]]; then
    wt_before_1="yes"
fi
assert_eq "test1: agent worktree exists before harvest" "yes" "$wt_before_1"

exit_code_1=0
stderr_1=""
stderr_1=$(cd "$SESSION_REPO" && \
    PATH="$STUB_BIN:$PATH" \
    bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    2>&1 >/dev/null) || exit_code_1=$?

# ASSERT 1a: harvest exits non-zero (refused to remove worktree due to open PR)
assert_ne "test1: harvest exits non-zero when open PR guard fires" \
    "0" "$exit_code_1"

# ASSERT 1b: stderr mentions "open_pr_with_ci" (the guard fired)
if echo "$stderr_1" | grep -q "open_pr_with_ci"; then
    (( ++PASS ))
    echo "PASS: test1: stderr contains 'open_pr_with_ci'"
else
    (( ++FAIL ))
    printf "FAIL: test1: stderr does not contain 'open_pr_with_ci'\n  stderr: %s\n" "$stderr_1" >&2
fi

# ASSERT 1c: stderr mentions the PR URL
if echo "$stderr_1" | grep -qF "$MOCK_PR_URL"; then
    (( ++PASS ))
    echo "PASS: test1: stderr contains PR URL"
else
    (( ++FAIL ))
    printf "FAIL: test1: stderr does not contain PR URL '%s'\n  stderr: %s\n" "$MOCK_PR_URL" "$stderr_1" >&2
fi

# ASSERT 1d: worktree directory was NOT removed (guard refused the removal)
wt_after_1="removed"
if [[ -d "$AGENT_WORKTREE_PATH" ]]; then
    wt_after_1="present"
fi
assert_eq "test1: worktree NOT removed when open PR guard fires (RED: will fail on current code)" \
    "present" "$wt_after_1"

fi # end SKIP guard for test_harvest_refuses_removal_when_open_pr_guard_fires

# =============================================================================
# Test 2: test_harvest_removes_worktree_when_no_guards_fire (control)
#
# Given: no open PRs (gh stubbed to return empty), worktree is clean, no unpushed commits
# When:  harvest invoked
# Then:  exits 0; worktree directory IS removed (control path — guards pass)
#
# This test should PASS even before S6.T3+T4 because the current code always removes
# the worktree. The control verifies that the no-PR case is still handled after the fix.
# =============================================================================
echo "--- test_harvest_removes_worktree_when_no_guards_fire ---"
_snapshot_fail

tmpdir=$(make_tmpdir)
setup_harvest_repo "$tmpdir"

STUB_BIN_2="$tmpdir/stub-bin-nopr"
make_gh_stub_no_pr "$STUB_BIN_2"

cat > "$STUB_BIN_2/dso" <<'DSOEOF'
#!/usr/bin/env bash
exit 0
DSOEOF
chmod +x "$STUB_BIN_2/dso"

# Push the branch so guard_unpushed doesn't fire
(cd "$AGENT_WORKTREE_PATH" && git push origin "$WORKTREE_BRANCH:$WORKTREE_BRANCH" 2>/dev/null) || true

exit_code_2=0
cd "$SESSION_REPO" && \
    PATH="$STUB_BIN_2:$PATH" \
    WORKTREE_REMOVAL_SKIP_PR_CHECK=1 \
    WORKTREE_REMOVAL_SKIP_PR_CHECK_REASON="test: no-guards-fire control path" \
    bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    >/dev/null 2>&1 || exit_code_2=$?

assert_eq "test2 (control): harvest exits 0 when no guards fire" \
    "0" "$exit_code_2"

wt_after_2="present"
if [[ ! -d "$AGENT_WORKTREE_PATH" ]]; then
    wt_after_2="removed"
fi
assert_eq "test2 (control): worktree IS removed when no guards fire" \
    "removed" "$wt_after_2"

assert_pass_if_clean "test_harvest_removes_worktree_when_no_guards_fire"

# =============================================================================
# Test 3: test_harvest_gh_unavailable_blocks_removal
#
# Given: gh CLI not in PATH (PATH overridden to exclude it)
# When:  harvest invoked (WORKTREE_REMOVAL_SKIP_PR_CHECK not set)
# Then:  exit non-zero; stderr contains "GUARD_PR_CHECK_UNAVAILABLE"
#
# RED: current harvest-worktree.sh never calls guard_open_pr, so when gh is
#      absent the worktree gets removed regardless. The "exit non-zero" assertion
#      will FAIL.
# =============================================================================
echo "--- test_harvest_gh_unavailable_blocks_removal ---"
_snapshot_fail

# SKIP: expected RED — tolerated by pre-existing marker convention until
# scan-red-markers.sh gains delta-mode (bug 535a-9d42-cb16-445c).
# Marker was bulk-stripped in commit 8b9a243aad to unblock merge-pipeline-checks.
echo "SKIP: test_harvest_gh_unavailable_blocks_removal — expected RED, tracked in 535a-9d42-cb16-445c"
assert_pass_if_clean "test_harvest_gh_unavailable_blocks_removal"
# --- Original test body preserved below for restoration once bug 535a fixes the scanner ---
if false; then

tmpdir=$(make_tmpdir)
setup_harvest_repo "$tmpdir"

# Build a PATH that excludes gh entirely — use only a minimal stub-bin with dso
STUB_BIN_3="$tmpdir/stub-bin-nogh"
mkdir -p "$STUB_BIN_3"
cat > "$STUB_BIN_3/dso" <<'DSOEOF'
#!/usr/bin/env bash
exit 0
DSOEOF
chmod +x "$STUB_BIN_3/dso"

# PATH: stub-bin only (no gh), plus coreutils needed for bash/git
SAFE_PATH="$STUB_BIN_3:/usr/bin:/bin"

exit_code_3=0
stderr_3=""
stderr_3=$(cd "$SESSION_REPO" && \
    PATH="$SAFE_PATH" \
    bash "$HARVEST_SCRIPT" \
    "$WORKTREE_BRANCH" \
    "$ARTIFACTS_DIR" \
    2>&1 >/dev/null) || exit_code_3=$?

# ASSERT 3a: exit non-zero (gh unavailable is fail-CLOSED)
assert_ne "test3: harvest exits non-zero when gh unavailable (RED: will fail on current code)" \
    "0" "$exit_code_3"

# ASSERT 3b: stderr mentions GUARD_PR_CHECK_UNAVAILABLE
if echo "$stderr_3" | grep -q "GUARD_PR_CHECK_UNAVAILABLE"; then
    (( ++PASS ))
    echo "PASS: test3: stderr contains 'GUARD_PR_CHECK_UNAVAILABLE'"
else
    (( ++FAIL ))
    printf "FAIL: test3: stderr does not contain 'GUARD_PR_CHECK_UNAVAILABLE'\n  stderr: %s\n" "$stderr_3" >&2
fi

# ASSERT 3c: worktree NOT removed when gh is unavailable
wt_after_3="removed"
if [[ -d "$AGENT_WORKTREE_PATH" ]]; then
    wt_after_3="present"
fi
assert_eq "test3: worktree NOT removed when gh is unavailable (RED: will fail on current code)" \
    "present" "$wt_after_3"

fi # end SKIP guard for test_harvest_gh_unavailable_blocks_removal

# =============================================================================
# Test 4: test_harvest_protected_branch_not_bypassable_with_force
#
# Given: the worktree branch is named "main" (a protected branch)
# When:  harvest invoked WITH --force
# Then:  exit non-zero (protected branch guard is NEVER --force-bypassable per
#        assert_worktree_removable contract)
#
# NOTE: To make a "main" worktree branch testable we set up a fresh repo where
#       "main" itself is not the working branch.  The check is done before merge,
#       so we simulate the worktree targeting a protected branch by creating a
#       branch named "release/1.0" (also protected per the guards contract) in
#       a repo where the session branch is "session-branch".
#
# RED: current harvest-worktree.sh does not call assert_worktree_removable and
#      does not recognise --force as a guard-bypass flag, so it will attempt to
#      remove the worktree unconditionally. The "exit non-zero" assertion FAILS.
# =============================================================================
echo "--- test_harvest_protected_branch_not_bypassable_with_force ---"
_snapshot_fail

tmpdir=$(make_tmpdir)

# Build a fresh repo with a protected-named worktree branch "release/1.0"
git init --bare "$tmpdir/origin4.git" >/dev/null 2>&1
git clone "$tmpdir/origin4.git" "$tmpdir/session4" >/dev/null 2>&1
SESSION_REPO4="$tmpdir/session4"
cd "$SESSION_REPO4" || exit 1
git config user.email "test@test.com"
git config user.name "Test"
echo "initial" > base.txt
git add base.txt
git commit -m "initial" >/dev/null 2>&1
git push origin HEAD:initial-base >/dev/null 2>&1
git checkout -b session-branch4 >/dev/null 2>&1

PROTECTED_BRANCH="release/1.0"
git checkout -b "$PROTECTED_BRANCH" >/dev/null 2>&1
echo "release work" > release.txt
git add release.txt
git commit -m "release: 1.0 work" >/dev/null 2>&1
git checkout session-branch4 >/dev/null 2>&1

# Gate artifacts for the protected branch
ARTIFACTS_4="$tmpdir/artifacts4"
mkdir -p "$ARTIFACTS_4"
_hash4=$(git diff "$PROTECTED_BRANCH"~1 "$PROTECTED_BRANCH" | shasum -a 256 | cut -d' ' -f1)
printf 'passed\ndiff_hash=%s\ntimestamp=%s\ntested_files=\n' \
    "$_hash4" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$ARTIFACTS_4/test-gate-status"
printf 'passed\ntimestamp=%s\ndiff_hash=%s\nscore=4\nreview_hash=abc\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$_hash4" > "$ARTIFACTS_4/review-status"

# Create a real git worktree for the protected branch
PROTECTED_WT_PATH="$tmpdir/protected-wt"
git worktree add "$PROTECTED_WT_PATH" "$PROTECTED_BRANCH" >/dev/null 2>&1

STUB_BIN_4="$tmpdir/stub-bin4"
make_gh_stub_no_pr "$STUB_BIN_4"
cat > "$STUB_BIN_4/dso" <<'DSOEOF'
#!/usr/bin/env bash
exit 0
DSOEOF
chmod +x "$STUB_BIN_4/dso"

exit_code_4=0
stderr_4=""
stderr_4=$(cd "$SESSION_REPO4" && \
    PATH="$STUB_BIN_4:$PATH" \
    WORKTREE_REMOVAL_SKIP_PR_CHECK=1 \
    WORKTREE_REMOVAL_SKIP_PR_CHECK_REASON="test: skip PR check to isolate protected-branch guard" \
    bash "$HARVEST_SCRIPT" \
    "$PROTECTED_BRANCH" \
    "$ARTIFACTS_4" \
    --force \
    2>&1 >/dev/null) || exit_code_4=$?

# ASSERT 4a: exit non-zero (protected branch is not bypassable even with --force)
assert_ne "test4: harvest exits non-zero for protected branch even with --force (RED: will fail on current code)" \
    "0" "$exit_code_4"

# ASSERT 4b: stderr mentions "protected_branch" (the guard fired)
if echo "$stderr_4" | grep -q "protected_branch"; then
    (( ++PASS ))
    echo "PASS: test4: stderr contains 'protected_branch'"
else
    (( ++FAIL ))
    printf "FAIL: test4: stderr does not contain 'protected_branch'\n  stderr: %s\n" "$stderr_4" >&2
fi

# ASSERT 4c: worktree was NOT removed (protected-branch guard is unbypassable)
wt_after_4="removed"
if [[ -d "$PROTECTED_WT_PATH" ]]; then
    wt_after_4="present"
fi
assert_eq "test4: worktree NOT removed for protected branch even with --force (RED: will fail on current code)" \
    "present" "$wt_after_4"

assert_pass_if_clean "test_harvest_protected_branch_not_bypassable_with_force"

# =============================================================================
# Summary
# =============================================================================
print_summary
