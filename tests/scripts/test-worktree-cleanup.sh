#!/usr/bin/env bash
# tests/scripts/test-worktree-cleanup.sh
# RED tests for the agent-worktree exemption in plugins/dso/scripts/worktree-cleanup.sh
#
# Bug: afdb-8418  Fix: 2
# Behavior under test:
#   A) Agent worktrees (.claude/worktrees/agent-*) are exempt from the 12-hour age gate
#      and are marked removable even when just created.
#   B) Session worktrees NOT under the agent path continue to be blocked by the age gate
#      (regression guard).
#   C) The is_old_enough() function returns 0 for agent paths regardless of mtime
#      (integration proxy via --dry-run since sourcing the script is not feasible).
#   D) git worktree unlock is called before remove, so an un-locked worktree removal
#      does not emit errors about "not locked" state.
#
# Test functions:
#   1. test_agent_worktree_exempt_from_age_gate      — agent path shows "remove" in dry-run
#   2. test_non_agent_worktree_respects_age_gate     — session path shows "too recent" in dry-run
#   3. test_is_old_enough_returns_true_for_agent_path — integration proxy for is_old_enough
#   4. test_explicit_unlock_before_remove_does_not_error — no "not locked" on stderr
#
# Notes:
#   - worktree-cleanup.sh uses `set -euo pipefail` and calls `git rev-parse` at global
#     scope, so it cannot be sourced. All tests invoke it as a subprocess.
#   - Tests build isolated git repos in $TMPDIR to avoid touching any live repo.
#   - AGE_HOURS=0 is NOT used — the fix must make agent paths bypass age checks
#     entirely; AGE_HOURS=0 would mask the regression guard in Test B.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$SCRIPT_DIR/../lib/assert.sh"

CLEANUP_SCRIPT="$REPO_ROOT/plugins/dso/scripts/worktree-cleanup.sh"

# ── Helpers ───────────────────────────────────────────────────────────────────

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

# Set up a minimal git repo with:
#   - an initial commit on 'main'
#   - a worktree at $wt_path on branch $wt_branch
#   - the worktree branch merged into main (so it passes the merged check)
#   - a clean working tree in the worktree
#
# Usage: setup_repo_with_worktree <base_tmpdir> <wt_path> <wt_branch>
# Sets global: MAIN_REPO
setup_repo_with_worktree() {
    local base="$1"
    local wt_path="$2"
    local wt_branch="$3"

    # Create main repo
    git init "$base/repo" >/dev/null 2>&1
    MAIN_REPO="$base/repo"

    git -C "$MAIN_REPO" config user.email "test@test.com"
    git -C "$MAIN_REPO" config user.name "Test"

    # Initial commit
    echo "initial" > "$MAIN_REPO/file.txt"
    git -C "$MAIN_REPO" add file.txt
    git -C "$MAIN_REPO" commit -m "initial commit" >/dev/null 2>&1

    # Create the worktree branch and add a commit
    git -C "$MAIN_REPO" branch "$wt_branch" HEAD

    # Create parent directories for the worktree path
    mkdir -p "$(dirname "$wt_path")"

    git -C "$MAIN_REPO" worktree add "$wt_path" "$wt_branch" >/dev/null 2>&1

    # Add a commit on the worktree branch (something to merge)
    git -C "$wt_path" config user.email "test@test.com"
    git -C "$wt_path" config user.name "Test"
    echo "change" >> "$wt_path/file.txt"
    git -C "$wt_path" add file.txt
    git -C "$wt_path" commit -m "worktree change" >/dev/null 2>&1

    # Merge the worktree branch into main so is_branch_merged returns true
    git -C "$MAIN_REPO" merge --no-ff "$wt_branch" -m "merge $wt_branch" >/dev/null 2>&1
}

# ── Tests ─────────────────────────────────────────────────────────────────────

# Test A: An agent worktree (just created, <1 min old) under .claude/worktrees/agent-*
# should appear as "remove" in --dry-run output, not "too recent".
test_agent_worktree_exempt_from_age_gate() {
    local tmp
    tmp=$(make_tmpdir)

    local agent_path="$tmp/repo/.claude/worktrees/agent-deadbeef"
    local agent_branch="worktree-agent-deadbeef"

    setup_repo_with_worktree "$tmp" "$agent_path" "$agent_branch"

    # Run the cleanup script from inside the main repo (so git rev-parse finds it)
    local output
    output=$(cd "$MAIN_REPO" && bash "$CLEANUP_SCRIPT" --dry-run 2>/dev/null) || true

    # The action column for a removable worktree contains "remove" (from "would remove")
    # The "keep (too recent ...)" string is present only when the age gate blocked it.
    assert_contains \
        "agent worktree dry-run shows 'remove'" \
        "remove" \
        "$output"

    # Must NOT show "too recent" for the agent worktree
    local too_recent_present="no"
    if [[ "$output" == *"too recent"* ]]; then
        too_recent_present="yes"
    fi
    assert_eq \
        "agent worktree NOT blocked by age gate" \
        "no" \
        "$too_recent_present"
}

# Test B: A fresh session worktree NOT under the agent path should be blocked by the
# age gate and show "too recent" in --dry-run output.
test_non_agent_worktree_respects_age_gate() {
    local tmp
    tmp=$(make_tmpdir)

    # Session worktree: top-level path, not under .claude/worktrees/agent-*
    local session_path="$tmp/repo/worktree-20260101-120000"
    local session_branch="worktree-20260101-120000"

    setup_repo_with_worktree "$tmp" "$session_path" "$session_branch"

    local output
    output=$(cd "$MAIN_REPO" && bash "$CLEANUP_SCRIPT" --dry-run 2>/dev/null) || true

    # The session worktree is fresh — it must be blocked by the age gate
    assert_contains \
        "session worktree blocked by age gate (shows 'too recent')" \
        "too recent" \
        "$output"

    # Confirm "remove" does NOT appear for the session worktree entry
    # (No worktree should be marked removable in this test setup)
    local would_remove_present="no"
    if [[ "$output" == *"would remove"* ]]; then
        would_remove_present="yes"
    fi
    assert_eq \
        "session worktree NOT marked for removal" \
        "no" \
        "$would_remove_present"
}

# Test C: Integration proxy for is_old_enough() agent-path exemption.
# We run --dry-run with BOTH an agent worktree and a session worktree in the same
# repo, then verify only the agent one is marked for removal while the session one
# shows "too recent". This is the strongest behavioral proxy short of sourcing the
# function (which is not feasible due to global-scope git calls).
test_is_old_enough_returns_true_for_agent_path() {
    local tmp
    tmp=$(make_tmpdir)

    # Create main repo manually (two worktrees needed)
    git init "$tmp/repo" >/dev/null 2>&1
    MAIN_REPO="$tmp/repo"
    git -C "$MAIN_REPO" config user.email "test@test.com"
    git -C "$MAIN_REPO" config user.name "Test"
    echo "initial" > "$MAIN_REPO/file.txt"
    git -C "$MAIN_REPO" add file.txt
    git -C "$MAIN_REPO" commit -m "initial" >/dev/null 2>&1

    # Create agent branch + worktree
    local agent_path="$MAIN_REPO/.claude/worktrees/agent-c0ffee"
    local agent_branch="worktree-agent-c0ffee"
    git -C "$MAIN_REPO" branch "$agent_branch" HEAD
    mkdir -p "$(dirname "$agent_path")"
    git -C "$MAIN_REPO" worktree add "$agent_path" "$agent_branch" >/dev/null 2>&1
    git -C "$agent_path" config user.email "test@test.com"
    git -C "$agent_path" config user.name "Test"
    echo "agent change" >> "$agent_path/file.txt"
    git -C "$agent_path" add file.txt
    git -C "$agent_path" commit -m "agent work" >/dev/null 2>&1
    git -C "$MAIN_REPO" merge --no-ff "$agent_branch" -m "merge $agent_branch" >/dev/null 2>&1

    # Create session branch + worktree
    local session_path="$MAIN_REPO/worktree-20260101-120000"
    local session_branch="worktree-20260101-120000"
    git -C "$MAIN_REPO" branch "$session_branch" HEAD
    git -C "$MAIN_REPO" worktree add "$session_path" "$session_branch" >/dev/null 2>&1
    git -C "$session_path" config user.email "test@test.com"
    git -C "$session_path" config user.name "Test"
    echo "session change" >> "$session_path/file.txt"
    git -C "$session_path" add file.txt
    git -C "$session_path" commit -m "session work" >/dev/null 2>&1
    git -C "$MAIN_REPO" merge --no-ff "$session_branch" -m "merge $session_branch" >/dev/null 2>&1

    local output
    output=$(cd "$MAIN_REPO" && bash "$CLEANUP_SCRIPT" --dry-run 2>/dev/null) || true

    # Agent worktree should be scheduled for removal (age gate bypassed)
    assert_contains \
        "is_old_enough: agent path classified as old-enough (would remove)" \
        "would remove" \
        "$output"

    # Session worktree should be kept (age gate active)
    assert_contains \
        "is_old_enough: session path still blocked by age gate (too recent)" \
        "too recent" \
        "$output"
}

# Test D: git worktree unlock before remove — unlocking an already-unlocked worktree
# must not produce any error output, and the removal must succeed.
# The fix adds: git worktree unlock "$path" 2>/dev/null || true
# Without the fix, this test still passes (the line is absent, but remove --force works).
# With the fix, we confirm no error text leaks through. We run with an agent worktree
# that is not locked so the "|| true" must silently swallow any non-zero exit.
test_explicit_unlock_before_remove_does_not_error() {
    local tmp
    tmp=$(make_tmpdir)

    local agent_path="$tmp/repo/.claude/worktrees/agent-aabbcc"
    local agent_branch="worktree-agent-aabbcc"

    setup_repo_with_worktree "$tmp" "$agent_path" "$agent_branch"

    # Verify the worktree is NOT locked (no locked file)
    local git_dir_name
    git_dir_name=$(basename "$agent_path")
    local locked_file="$MAIN_REPO/.git/worktrees/$git_dir_name/locked"
    local lock_present="yes"
    [[ ! -f "$locked_file" ]] && lock_present="no"
    assert_eq \
        "worktree is not locked (precondition)" \
        "no" \
        "$lock_present"

    # Run the actual removal (non-interactive, all, force)
    local stderr_out
    stderr_out=$(cd "$MAIN_REPO" && \
        WORKTREE_CLEANUP_ENABLED=1 bash "$CLEANUP_SCRIPT" \
        --non-interactive --all --force --no-branches 2>&1 >/dev/null) || true

    # stderr must not contain any error about the worktree not being locked
    local not_locked_error="no"
    if [[ "$stderr_out" == *"not locked"* ]]; then
        not_locked_error="yes"
    fi
    assert_eq \
        "no 'not locked' error emitted on stderr during removal" \
        "no" \
        "$not_locked_error"

    # The worktree directory should be gone after removal
    local wt_gone="yes"
    [[ -d "$agent_path" ]] && wt_gone="no"
    assert_eq \
        "agent worktree directory removed" \
        "yes" \
        "$wt_gone"
}

# Test E: .tickets-tracker worktree excluded from cleanup (cf6d-54fd).
test_tickets_branch_worktree_excluded_from_cleanup() {
    local tmp; tmp=$(make_tmpdir)
    local tickets_path="$tmp/repo/.tickets-tracker"
    local tickets_branch="tickets"
    setup_repo_with_worktree "$tmp" "$tickets_path" "$tickets_branch"
    local output
    output=$(cd "$MAIN_REPO" && bash "$CLEANUP_SCRIPT" --dry-run 2>/dev/null) || true
    local no_remove_present="yes"
    if [[ "$output" == *"would remove"* ]]; then no_remove_present="no"; fi
    assert_eq "tickets worktree NOT scheduled for removal (cf6d-54fd)" "yes" "$no_remove_present"
    local wt_present="yes"
    [[ ! -d "$tickets_path" ]] && wt_present="no"
    assert_eq "tickets worktree directory still exists after dry-run" "yes" "$wt_present"
}

# Test F: Discarded agent worktree eligible for removal (89fa-8baa, e4a3-2df7).
test_agent_worktree_eligible_when_not_merged() {
    local tmp; tmp=$(make_tmpdir)
    git init "$tmp/repo" >/dev/null 2>&1; MAIN_REPO="$tmp/repo"
    git -C "$MAIN_REPO" config user.email "test@test.com"
    git -C "$MAIN_REPO" config user.name "Test"
    echo "initial" > "$MAIN_REPO/file.txt"
    git -C "$MAIN_REPO" add file.txt
    git -C "$MAIN_REPO" commit -m "initial" >/dev/null 2>&1
    local agent_path="$MAIN_REPO/.claude/worktrees/agent-discarded"
    local agent_branch="worktree-agent-discarded"
    git -C "$MAIN_REPO" branch "$agent_branch" HEAD
    mkdir -p "$(dirname "$agent_path")"
    git -C "$MAIN_REPO" worktree add "$agent_path" "$agent_branch" >/dev/null 2>&1
    git -C "$agent_path" config user.email "test@test.com"
    git -C "$agent_path" config user.name "Test"
    echo "agent work" >> "$agent_path/file.txt"
    git -C "$agent_path" add file.txt
    git -C "$agent_path" commit -m "agent work (discarded)" >/dev/null 2>&1
    local output
    output=$(cd "$MAIN_REPO" && bash "$CLEANUP_SCRIPT" --dry-run 2>/dev/null) || true
    assert_contains "discarded agent worktree eligible for removal (89fa-8baa, e4a3-2df7)" "would remove" "$output"
    local not_merged_present="no"
    if [[ "$output" == *"not merged"* ]]; then not_merged_present="yes"; fi
    assert_eq "discarded agent worktree NOT blocked by merge gate" "no" "$not_merged_present"
}

# ── Run all tests ────────────────────────────────────────────

test_agent_worktree_exempt_from_age_gate
test_non_agent_worktree_respects_age_gate
test_is_old_enough_returns_true_for_agent_path
test_explicit_unlock_before_remove_does_not_error
test_tickets_branch_worktree_excluded_from_cleanup
test_agent_worktree_eligible_when_not_merged

# ── Test G: Agent worktree with uncommitted changes is still removable (3170-8d8a) ──
# Agent worktrees are transient dispatch worktrees — they may have uncommitted residue
# from failed or abandoned agents. They should be removed regardless of dirty state.
test_agent_worktree_exempt_from_dirty_check() {
    local tmp; tmp=$(make_tmpdir)
    local MAIN_REPO="$tmp/repo"
    git init "$MAIN_REPO" >/dev/null 2>&1
    git -C "$MAIN_REPO" config user.email "test@test.com"
    git -C "$MAIN_REPO" config user.name "Test"
    echo "initial" > "$MAIN_REPO/file.txt"
    git -C "$MAIN_REPO" add file.txt
    git -C "$MAIN_REPO" commit -m "initial" >/dev/null 2>&1
    local agent_path="$MAIN_REPO/.claude/worktrees/agent-dirty"
    local agent_branch="worktree-agent-dirty"
    git -C "$MAIN_REPO" branch "$agent_branch" HEAD
    mkdir -p "$(dirname "$agent_path")"
    git -C "$MAIN_REPO" worktree add "$agent_path" "$agent_branch" >/dev/null 2>&1
    git -C "$agent_path" config user.email "test@test.com"
    git -C "$agent_path" config user.name "Test"
    # Commit on the agent branch, then merge into main
    echo "agent work" >> "$agent_path/file.txt"
    git -C "$agent_path" add file.txt
    git -C "$agent_path" commit -m "agent work" >/dev/null 2>&1
    git -C "$MAIN_REPO" merge --no-ff "$agent_branch" -m "merge agent" >/dev/null 2>&1
    # Leave an uncommitted change in the agent worktree (residual dirty state)
    echo "uncommitted residue" >> "$agent_path/file.txt"
    local output
    output=$(cd "$MAIN_REPO" && bash "$CLEANUP_SCRIPT" --dry-run 2>/dev/null) || true
    assert_contains "agent worktree with uncommitted changes shows 'remove'" "would remove" "$output"
    local dirty_present="no"
    if [[ "$output" == *"uncommitted changes"* ]]; then dirty_present="yes"; fi
    assert_eq "agent worktree NOT blocked by uncommitted-changes check" "no" "$dirty_present"
}
test_agent_worktree_exempt_from_dirty_check

print_summary

# TEST MARKER APPENDED
