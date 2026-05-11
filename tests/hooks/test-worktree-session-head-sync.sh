#!/usr/bin/env bash
# Tests that worktree-session-head-sync.sh brings a sub-agent worktree
# up to SESSION_HEAD when initialized from main HEAD (behind session).
#
# Tests:
#   test_sync_brings_subagent_to_session_head
#
# Usage: bash tests/hooks/test-worktree-session-head-sync.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail
# Note: set -e omitted intentionally — tests call functions that return non-zero
# and we handle failures via assert_eq/assert_contains, not exit-on-error.

REPO_ROOT=$(git rev-parse --show-toplevel)
source "$REPO_ROOT/tests/lib/assert.sh"

# ---------------------------------------------------------------------------
# Temp dir registry and cleanup
# ---------------------------------------------------------------------------
_TEMP_DIRS=()

register_temp() {
    _TEMP_DIRS+=("$1")
}

cleanup_all() {
    for d in "${_TEMP_DIRS[@]+"${_TEMP_DIRS[@]}"}"; do
        rm -rf "$d"
    done
}

trap cleanup_all EXIT

# ---------------------------------------------------------------------------
# test_sync_brings_subagent_to_session_head
#
# Setup:
#   - bare remote git repo
#   - "main repo" clone with one commit on main
#   - session branch in main repo with 1 extra commit (simulates orchestrator)
#   - session branch pushed to bare remote
#   - sub-agent worktree checked out from main HEAD (behind session)
#
# When: worktree-session-head-sync.sh runs with SESSION_BRANCH/SESSION_HEAD set
# Then: sub-agent worktree HEAD == SESSION_HEAD SHA
# ---------------------------------------------------------------------------
echo "--- test_sync_brings_subagent_to_session_head ---"

# 1. Verify the target script exists (RED gate)
_SYNC_SCRIPT="$REPO_ROOT/plugins/dso/scripts/worktree-session-head-sync.sh"
if [[ ! -f "$_SYNC_SCRIPT" ]]; then
    printf "FAIL: test_sync_brings_subagent_to_session_head\n" >&2
    printf "  worktree-session-head-sync.sh does not exist at: %s\n" "$_SYNC_SCRIPT" >&2
    (( ++FAIL ))
    print_summary
fi

# 2. Create bare remote
_BARE_REMOTE=$(mktemp -d)
register_temp "$_BARE_REMOTE"
git init --bare "$_BARE_REMOTE" -q

# 3. Create main-repo clone from bare remote
_MAIN_REPO=$(mktemp -d)
register_temp "$_MAIN_REPO"
git clone "$_BARE_REMOTE" "$_MAIN_REPO" -q

# Configure git identity inside test repos
git -C "$_MAIN_REPO" config user.email "test@example.com"
git -C "$_MAIN_REPO" config user.name "Test"

# Make an initial commit so main branch exists
echo "initial" > "$_MAIN_REPO/initial.txt"
git -C "$_MAIN_REPO" add initial.txt
git -C "$_MAIN_REPO" commit -m "initial commit" -q

# Push main to remote so sub-agent can fetch it
git -C "$_MAIN_REPO" push -u origin main -q

# Capture main HEAD (where sub-agent worktree will start)
_MAIN_HEAD=$(git -C "$_MAIN_REPO" rev-parse HEAD)

# 4. Create session branch with 1 extra commit (simulates orchestrator session)
_SESSION_BRANCH="session-worktree-test-$$"
git -C "$_MAIN_REPO" checkout -b "$_SESSION_BRANCH" -q
echo "session work" > "$_MAIN_REPO/session.txt"
git -C "$_MAIN_REPO" add session.txt
git -C "$_MAIN_REPO" commit -m "session commit" -q
_SESSION_HEAD=$(git -C "$_MAIN_REPO" rev-parse HEAD)

# Push session branch to bare remote
git -C "$_MAIN_REPO" push -u origin "$_SESSION_BRANCH" -q

# 5. Create sub-agent worktree from a fresh clone of the bare remote, at main HEAD
#    This simulates Claude Code `isolation: "worktree"` behavior — it initializes
#    from main HEAD, NOT the orchestrator's session HEAD.
_SUBAGENT_CLONE=$(mktemp -d)
register_temp "$_SUBAGENT_CLONE"
git clone "$_BARE_REMOTE" "$_SUBAGENT_CLONE" -q
git -C "$_SUBAGENT_CLONE" config user.email "test@example.com"
git -C "$_SUBAGENT_CLONE" config user.name "Test"

# Fetch session branch so the clone knows about it
git -C "$_SUBAGENT_CLONE" fetch origin "$_SESSION_BRANCH" -q

_SUBAGENT_WORKTREE=$(mktemp -d)
# Remove the mktemp-created dir so git worktree add can create it fresh
rmdir "$_SUBAGENT_WORKTREE"
register_temp "$_SUBAGENT_WORKTREE"

git -C "$_SUBAGENT_CLONE" worktree add --detach "$_SUBAGENT_WORKTREE" "$_MAIN_HEAD" -q

# Verify sub-agent worktree starts at main HEAD (not session HEAD)
_SUBAGENT_INITIAL_HEAD=$(git -C "$_SUBAGENT_WORKTREE" rev-parse HEAD)
assert_eq "test_sync_brings_subagent_to_session_head: subagent starts at main HEAD" \
    "$_MAIN_HEAD" "$_SUBAGENT_INITIAL_HEAD"

assert_ne "test_sync_brings_subagent_to_session_head: subagent is behind session" \
    "$_SESSION_HEAD" "$_SUBAGENT_INITIAL_HEAD"

# 6. Run worktree-session-head-sync.sh from inside the sub-agent worktree
_sync_exit=0
(
    cd "$_SUBAGENT_WORKTREE"
    SESSION_BRANCH="$_SESSION_BRANCH" SESSION_HEAD="$_SESSION_HEAD" \
        bash "$_SYNC_SCRIPT"
) || _sync_exit=$?

assert_eq "test_sync_brings_subagent_to_session_head: sync script exits 0" \
    "0" "$_sync_exit"

# 7. Assert sub-agent worktree HEAD now equals SESSION_HEAD
_SUBAGENT_FINAL_HEAD=$(git -C "$_SUBAGENT_WORKTREE" rev-parse HEAD)
assert_eq "test_sync_brings_subagent_to_session_head: subagent HEAD == SESSION_HEAD after sync" \
    "$_SESSION_HEAD" "$_SUBAGENT_FINAL_HEAD"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary
