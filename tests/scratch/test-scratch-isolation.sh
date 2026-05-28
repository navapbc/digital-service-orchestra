#!/usr/bin/env bash
# tests/scratch/test-scratch-isolation.sh
# Behavioral test: ticket-init.sh adds a .scratch/ exclude entry so that
# scratch files written under .tickets-tracker/.scratch/ are invisible to
# git status and are never enumerated by the Jira reconciler payload-builder.
#
# Testing Mode: RED (must FAIL until ticket-init.sh and the tickets-branch
# .gitignore gain .scratch/ isolation — task-3 is the GREEN gate).
#
# Assertions:
#   1. After ticket-init.sh, .git/info/exclude contains exactly one
#      .scratch/ entry.
#   2. git ls-files on the tickets-branch fixture returns empty for
#      any path under .scratch/ (scratch is never tracked on the branch).
#   3. git status --porcelain .tickets-tracker/ shows no untracked entries
#      under .scratch/ after writing a scratch file on disk.
#
# Usage: bash tests/scratch/test-scratch-isolation.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_INIT="$REPO_ROOT/plugins/dso/scripts/ticket-init.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-scratch-isolation.sh: .scratch/ git-exclude isolation ==="

# ── Preflight ────────────────────────────────────────────────────────────────
if [ ! -f "$TICKET_INIT" ]; then
    echo "FATAL: ticket-init.sh not found at $TICKET_INIT" >&2
    exit 1
fi

# ── Cleanup tracking ──────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        [ -n "$d" ] && rm -rf "$d"
    done
}
trap _cleanup EXIT

# ── Helper: create a minimal git repo fixture and run ticket-init.sh in it ──
_make_fixture_repo() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/scratch-iso-XXXXXX")
    _CLEANUP_DIRS+=("$tmp")

    # Minimal git repo setup
    git -C "$tmp" init -q
    git -C "$tmp" config user.email "test@test.invalid"
    git -C "$tmp" config user.name "Test"
    git -C "$tmp" config commit.gpgsign false
    # Create an initial commit so worktree add (for git < 2.40) works
    git -C "$tmp" commit --allow-empty -q --no-verify -m "init"

    echo "$tmp"
}

# ══════════════════════════════════════════════════════════════════════════════
# Test 1: ticket-init.sh writes exactly one .scratch/ entry in .git/info/exclude
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 1: ticket-init.sh writes exactly one .scratch/ entry in exclude ──"
test_exclude_has_scratch_entry() {
    local repo
    repo=$(_make_fixture_repo)

    # Run ticket-init.sh
    local init_rc=0
    bash "$TICKET_INIT" --silent 2>/dev/null </dev/null \
        || true
    # Run it in the fixture dir
    (cd "$repo" && bash "$TICKET_INIT" --silent) >/dev/null 2>&1 || init_rc=$?

    # Resolve .git/info/exclude via git rev-parse --git-path
    local exclude_file
    exclude_file=$(git -C "$repo" rev-parse --git-path info/exclude 2>/dev/null || echo "")
    # If --git-path doesn't return the path, fall back
    if [ -z "$exclude_file" ] || [ ! -f "$exclude_file" ]; then
        exclude_file="$repo/.git/info/exclude"
    fi

    # Assert the exclude file exists
    assert_eq "exclude file exists after ticket-init.sh" "0" "$([ -f "$exclude_file" ] && echo 0 || echo 1)"

    # Assert exactly one .scratch/ entry exists
    local scratch_count
    scratch_count=$(grep -cFx '.scratch/' "$exclude_file" 2>/dev/null || echo "0")
    assert_eq "exactly one .scratch/ entry in exclude" "1" "$scratch_count"
}
test_exclude_has_scratch_entry

# ══════════════════════════════════════════════════════════════════════════════
# Test 2: git ls-files returns empty for .scratch/ path on tickets branch
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 2: git ls-files returns empty for .scratch/ on tickets branch ──"
test_git_ls_files_excludes_scratch() {
    local repo
    repo=$(_make_fixture_repo)

    # Run ticket-init.sh to set up the tickets branch
    (cd "$repo" && bash "$TICKET_INIT" --silent) >/dev/null 2>&1 || true

    # Write a scratch file onto the tickets branch worktree if it exists
    local tracker_dir="$repo/.tickets-tracker"
    if [ ! -d "$tracker_dir" ]; then
        # Graceful: if ticket-init.sh couldn't set up tracker, skip with a fail
        assert_eq "tickets-tracker dir must exist" "0" "1"
        return
    fi

    # Write a scratch file on disk (not staged)
    mkdir -p "$tracker_dir/.scratch/test-ticket-1234"
    echo '{"value":"test"}' > "$tracker_dir/.scratch/test-ticket-1234/somekey"

    # git ls-files on the tickets branch for the .scratch path must return empty
    # (scratch entries should never be tracked on the branch)
    local ls_output
    ls_output=$(git -C "$tracker_dir" ls-files ".scratch/" 2>/dev/null || echo "")
    assert_eq "git ls-files .scratch/ returns empty" "" "$ls_output"
}
test_git_ls_files_excludes_scratch

# ══════════════════════════════════════════════════════════════════════════════
# Test 3: git status --porcelain shows no untracked under .scratch/ in tracker
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 3: git status --porcelain shows no untracked under .scratch/ ──"
test_git_status_excludes_scratch() {
    local repo
    repo=$(_make_fixture_repo)

    # Run ticket-init.sh to set up the tickets branch
    (cd "$repo" && bash "$TICKET_INIT" --silent) >/dev/null 2>&1 || true

    local tracker_dir="$repo/.tickets-tracker"
    if [ ! -d "$tracker_dir" ]; then
        assert_eq "tickets-tracker dir must exist" "0" "1"
        return
    fi

    # Write a scratch file on disk under .tickets-tracker/.scratch/
    mkdir -p "$tracker_dir/.scratch/abc1-def2-ghi3-jkl4"
    echo '{"value":"scratch-data"}' > "$tracker_dir/.scratch/abc1-def2-ghi3-jkl4/notes"

    # git status --porcelain on the tracker dir must NOT show any .scratch entries
    local status_output
    status_output=$(git -C "$tracker_dir" status --porcelain ".scratch/" 2>/dev/null || echo "")
    assert_eq "git status --porcelain .scratch/ is empty" "" "$status_output"
}
test_git_status_excludes_scratch

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
echo ""
print_summary
