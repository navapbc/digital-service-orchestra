#!/usr/bin/env bash
# tests/scratch/test-scratch-gitignore.sh
#
# RED-only test — asserts that ticket-init.sh registers the scratch directory
# (.tickets-tracker/.scratch/) in the tickets-tracker worktree's
# .git/info/exclude so that:
#   1. git check-ignore confirms the scratch path is excluded
#   2. git ls-files on the scratch path returns empty even when scratch files
#      exist on disk
#   3. Re-running ticket-init.sh does NOT duplicate the exclusion entry (idempotent)
#
# EXPECTED TO FAIL until ticket-init.sh is updated (implementation task is
# separate from this RED task — story beaa-9f9d-d3ae-4a83 / ticket
# 5fb1-8f9f-0d6b-41da).  The implementation will add .scratch/ (or equivalent)
# to .git/info/exclude of the tickets-tracker worktree during initialization.
#
# Testing Mode: RED
# Usage: bash tests/scratch/test-scratch-gitignore.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_INIT="$REPO_ROOT/plugins/dso/scripts/ticket-init.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-scratch-gitignore.sh: .scratch gitignore in tickets-tracker ==="
echo "NOTE: This test is expected to FAIL RED until ticket-init.sh is updated."

# ── Cleanup tracking ──────────────────────────────────────────────────────────
_CLEANUP_DIRS=()
_cleanup() {
    for d in "${_CLEANUP_DIRS[@]:-}"; do
        [ -n "$d" ] && rm -rf "$d"
    done
}
trap _cleanup EXIT

# ── Helper: create an isolated scratch repo and run ticket-init.sh ────────────
# Returns the path to the temp repo root via stdout.
_make_isolated_repo() {
    local tmpdir
    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/test-scratch-gitignore.XXXXXX")
    _CLEANUP_DIRS+=("$tmpdir")

    git -C "$tmpdir" init -q
    git -C "$tmpdir" config user.email "test@test.local"
    git -C "$tmpdir" config user.name "Test"
    git -C "$tmpdir" commit --allow-empty -q --no-verify -m "init"

    echo "$tmpdir"
}

# ── Guard: ticket-init.sh must exist ─────────────────────────────────────────
if [ ! -f "$TICKET_INIT" ]; then
    echo "FATAL: ticket-init.sh not found at $TICKET_INIT" >&2
    exit 1
fi

# ══════════════════════════════════════════════════════════════════════════════
# Test 1: .git/info/exclude of tickets-tracker contains a .scratch/ entry
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 1: .git/info/exclude of tickets-tracker contains .scratch/ exclusion ──"

test_scratch_gitignore_in_exclude() {
    local repo
    repo=$(_make_isolated_repo)

    # Run ticket-init.sh in the temp repo
    local init_exit=0
    ( cd "$repo" && PROJECT_ROOT="$repo" bash "$TICKET_INIT" --silent ) || init_exit=$?

    assert_eq "ticket-init.sh exits 0" "0" "$init_exit"

    local tracker="$repo/.tickets-tracker"
    if [ ! -d "$tracker" ] && [ ! -L "$tracker" ]; then
        assert_eq "tickets-tracker directory exists" "present" "absent"
        return
    fi

    # Resolve the tickets worktree git dir
    local tickets_git_file="$tracker/.git"
    local tickets_git_dir
    if [ -f "$tickets_git_file" ]; then
        tickets_git_dir="$(sed -n 's/^gitdir: //p' "$tickets_git_file")"
        # Resolve relative path
        if [[ "$tickets_git_dir" != /* ]]; then
            tickets_git_dir="$tracker/$tickets_git_dir"
        fi
    else
        tickets_git_dir="$tracker/.git"
    fi

    local exclude_file="$tickets_git_dir/info/exclude"

    # Check that .scratch/ (or .scratch) is present in the exclude file
    local found_scratch=0
    if [ -f "$exclude_file" ] && grep -qE '\.scratch(/?)$' "$exclude_file" 2>/dev/null; then
        found_scratch=1
    fi

    assert_eq ".scratch/ present in tickets-tracker .git/info/exclude" "1" "$found_scratch"
}
test_scratch_gitignore_in_exclude

# ══════════════════════════════════════════════════════════════════════════════
# Test 2: git check-ignore confirms the scratch path is excluded
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 2: git check-ignore confirms .scratch path is excluded ──"

test_git_check_ignore_scratch() {
    local repo
    repo=$(_make_isolated_repo)

    local init_exit=0
    ( cd "$repo" && PROJECT_ROOT="$repo" bash "$TICKET_INIT" --silent ) || init_exit=$?

    assert_eq "ticket-init.sh exits 0 (test 2)" "0" "$init_exit"

    local tracker="$repo/.tickets-tracker"
    if [ ! -d "$tracker" ] && [ ! -L "$tracker" ]; then
        assert_eq "tickets-tracker exists (test 2)" "present" "absent"
        return
    fi

    # Create the scratch directory and a sentinel file on disk
    local scratch_dir="$tracker/.scratch"
    mkdir -p "$scratch_dir"
    echo "sentinel" > "$scratch_dir/sentinel.txt"

    # git check-ignore should exit 0 if the path is ignored, non-zero if not
    local check_exit=0
    git -C "$tracker" check-ignore -q "$scratch_dir/sentinel.txt" 2>/dev/null || check_exit=$?

    assert_eq "git check-ignore reports scratch path as ignored" "0" "$check_exit"
}
test_git_check_ignore_scratch

# ══════════════════════════════════════════════════════════════════════════════
# Test 3: git ls-files on scratch path returns empty even with files on disk
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 3: git ls-files on scratch path returns empty even when files exist on disk ──"

test_git_ls_files_scratch_empty() {
    local repo
    repo=$(_make_isolated_repo)

    local init_exit=0
    ( cd "$repo" && PROJECT_ROOT="$repo" bash "$TICKET_INIT" --silent ) || init_exit=$?

    assert_eq "ticket-init.sh exits 0 (test 3)" "0" "$init_exit"

    local tracker="$repo/.tickets-tracker"
    if [ ! -d "$tracker" ] && [ ! -L "$tracker" ]; then
        assert_eq "tickets-tracker exists (test 3)" "present" "absent"
        return
    fi

    # Create scratch file on disk
    local scratch_dir="$tracker/.scratch"
    mkdir -p "$scratch_dir"
    echo "sentinel content" > "$scratch_dir/sentinel.txt"

    # git ls-files should return empty for the scratch directory
    local ls_output
    ls_output=$(git -C "$tracker" ls-files ".scratch/" 2>/dev/null || true)

    local ls_empty=1
    [ -z "$ls_output" ] && ls_empty=0

    assert_eq "git ls-files .scratch/ returns empty output" "0" "$ls_empty"
}
test_git_ls_files_scratch_empty

# ══════════════════════════════════════════════════════════════════════════════
# Test 4: Re-running ticket-init.sh does NOT duplicate the .scratch exclusion
# ══════════════════════════════════════════════════════════════════════════════
echo ""
echo "── Test 4: Re-running ticket-init.sh is idempotent (no duplicate .scratch/ entry) ──"

test_scratch_gitignore_idempotent() {
    local repo
    repo=$(_make_isolated_repo)

    # First run
    local init1_exit=0
    ( cd "$repo" && PROJECT_ROOT="$repo" bash "$TICKET_INIT" --silent ) || init1_exit=$?
    assert_eq "first ticket-init.sh run exits 0" "0" "$init1_exit"

    # Second run (idempotency check — ticket-init.sh has an early exit path
    # when already initialized, so the guard must be tested differently:
    # we clear the tracker and re-init to simulate the init path being reached twice)
    # Instead: run ticket-init.sh a second time against the SAME repo.
    # The early-exit path will fire but we still verify no duplication occurs.
    local init2_exit=0
    ( cd "$repo" && PROJECT_ROOT="$repo" bash "$TICKET_INIT" --silent ) || init2_exit=$?
    assert_eq "second ticket-init.sh run exits 0" "0" "$init2_exit"

    local tracker="$repo/.tickets-tracker"
    if [ ! -d "$tracker" ] && [ ! -L "$tracker" ]; then
        assert_eq "tickets-tracker exists (test 4)" "present" "absent"
        return
    fi

    # Resolve tickets git dir
    local tickets_git_file="$tracker/.git"
    local tickets_git_dir
    if [ -f "$tickets_git_file" ]; then
        tickets_git_dir="$(sed -n 's/^gitdir: //p' "$tickets_git_file")"
        if [[ "$tickets_git_dir" != /* ]]; then
            tickets_git_dir="$tracker/$tickets_git_dir"
        fi
    else
        tickets_git_dir="$tracker/.git"
    fi

    local exclude_file="$tickets_git_dir/info/exclude"

    # Count occurrences of .scratch in exclude file — must be exactly 1
    local scratch_count=0
    if [ -f "$exclude_file" ]; then
        scratch_count=$(grep -cE '\.scratch(/?)$' "$exclude_file" 2>/dev/null || echo "0")
    fi

    # Normalize BSD grep -c double-output quirk
    scratch_count="${scratch_count%%$'\n'*}"

    assert_eq ".scratch/ appears exactly once in exclude (no duplicates)" "1" "$scratch_count"
}
test_scratch_gitignore_idempotent

# ══════════════════════════════════════════════════════════════════════════════
# Summary
# ══════════════════════════════════════════════════════════════════════════════
echo ""
print_summary
