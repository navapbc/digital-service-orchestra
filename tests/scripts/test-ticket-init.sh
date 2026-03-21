#!/usr/bin/env bash
# tests/scripts/test-ticket-init.sh
# Tests for plugins/dso/scripts/ticket init subcommand
#
# These tests are RED — they test functionality that does not yet exist.
# All test functions must return non-zero until `ticket init` is implemented.
#
# Usage: bash tests/scripts/test-ticket-init.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-init.sh ==="

# ── Helper: create a fresh temp git repo ─────────────────────────────────────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_test_repo "$tmp/repo"
    echo "$tmp/repo"
}

# ── Test 1: test_ticket_init_creates_orphan_branch_and_worktree ──────────────
echo "Test 1: ticket init creates .tickets-tracker/ worktree on orphan branch"
test_ticket_init_creates_orphan_branch_and_worktree() {
    local repo
    repo=$(_make_test_repo)

    # Run from inside the repo; suppress incidental command noise only
    (cd "$repo" && bash "$TICKET_SCRIPT" init 2>/dev/null) || true

    # Assert: .tickets-tracker/ directory exists
    if [ -d "$repo/.tickets-tracker" ]; then
        assert_eq "orphan branch and worktree: .tickets-tracker/ exists" "exists" "exists"
    else
        assert_eq "orphan branch and worktree: .tickets-tracker/ exists" "exists" "missing"
    fi

    # Assert: .tickets-tracker/ is a git worktree (has .git file, not .git dir)
    if [ -f "$repo/.tickets-tracker/.git" ]; then
        assert_eq "orphan branch and worktree: .tickets-tracker/.git is a file" "file" "file"
    else
        assert_eq "orphan branch and worktree: .tickets-tracker/.git is a file" "file" "missing-or-dir"
    fi

    # Assert: the tickets orphan branch exists
    if git -C "$repo/.tickets-tracker" rev-parse --verify tickets &>/dev/null; then
        assert_eq "orphan branch and worktree: branch 'tickets' exists" "exists" "exists"
    else
        assert_eq "orphan branch and worktree: branch 'tickets' exists" "exists" "missing"
    fi
}
test_ticket_init_creates_orphan_branch_and_worktree

# ── Test 2: test_ticket_init_creates_env_id ───────────────────────────────────
echo "Test 2: ticket init creates .env-id with UUID4 content"
test_ticket_init_creates_env_id() {
    local repo
    repo=$(_make_test_repo)

    (cd "$repo" && bash "$TICKET_SCRIPT" init 2>/dev/null) || true

    # Assert: .env-id file exists
    if [ -f "$repo/.tickets-tracker/.env-id" ]; then
        assert_eq "env-id: .env-id exists" "exists" "exists"
    else
        assert_eq "env-id: .env-id exists" "exists" "missing"
        return
    fi

    # Assert: content matches UUID4 pattern (8-4-4-4-12 hex, version 4, variant bits 8/9/a/b)
    local env_id
    env_id=$(cat "$repo/.tickets-tracker/.env-id")
    if echo "$env_id" | grep -qE '^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$'; then
        assert_eq "env-id: content is valid UUID4" "valid" "valid"
    else
        assert_eq "env-id: content is valid UUID4" "valid" "invalid: $env_id"
    fi
}
test_ticket_init_creates_env_id

# ── Test 3: test_ticket_init_is_idempotent ────────────────────────────────────
echo "Test 3: ticket init is idempotent (second run exits 0)"
test_ticket_init_is_idempotent() {
    local repo
    repo=$(_make_test_repo)

    # First run
    (cd "$repo" && bash "$TICKET_SCRIPT" init 2>/dev/null) || true

    # Second run — must not fail
    local exit2=0
    (cd "$repo" && bash "$TICKET_SCRIPT" init 2>/dev/null) || exit2=$?

    assert_eq "idempotent: second run exits 0" "0" "$exit2"
}
test_ticket_init_is_idempotent

# ── Test 4: test_ticket_init_adds_to_gitignore ───────────────────────────────
echo "Test 4: ticket init commits .gitignore on tickets branch excluding .env-id and .state-cache"
test_ticket_init_adds_to_gitignore() {
    local repo
    repo=$(_make_test_repo)

    (cd "$repo" && bash "$TICKET_SCRIPT" init 2>/dev/null) || true

    # Assert: .gitignore exists as a committed file on the tickets branch
    if git -C "$repo/.tickets-tracker" show tickets:.gitignore &>/dev/null; then
        assert_eq "gitignore: committed on tickets branch" "committed" "committed"
    else
        assert_eq "gitignore: committed on tickets branch" "committed" "missing"
        return
    fi

    local gitignore_content
    gitignore_content=$(git -C "$repo/.tickets-tracker" show tickets:.gitignore 2>/dev/null)

    # Assert: .env-id is excluded
    if echo "$gitignore_content" | grep -q '\.env-id'; then
        assert_eq "gitignore: excludes .env-id" "excluded" "excluded"
    else
        assert_eq "gitignore: excludes .env-id" "excluded" "missing"
    fi

    # Assert: .state-cache is excluded
    if echo "$gitignore_content" | grep -q '\.state-cache'; then
        assert_eq "gitignore: excludes .state-cache" "excluded" "excluded"
    else
        assert_eq "gitignore: excludes .state-cache" "excluded" "missing"
    fi
}
test_ticket_init_adds_to_gitignore

# ── Test 5: test_ticket_init_adds_to_git_info_exclude ────────────────────────
echo "Test 5: ticket init adds .tickets-tracker to .git/info/exclude"
test_ticket_init_adds_to_git_info_exclude() {
    local repo
    repo=$(_make_test_repo)

    (cd "$repo" && bash "$TICKET_SCRIPT" init 2>/dev/null) || true

    # Assert: .git/info/exclude exists
    if [ -f "$repo/.git/info/exclude" ]; then
        assert_eq "git-info-exclude: file exists" "exists" "exists"
    else
        assert_eq "git-info-exclude: file exists" "exists" "missing"
        return
    fi

    # Assert: .tickets-tracker is listed
    if grep -q '\.tickets-tracker' "$repo/.git/info/exclude"; then
        assert_eq "git-info-exclude: contains .tickets-tracker" "present" "present"
    else
        assert_eq "git-info-exclude: contains .tickets-tracker" "present" "missing"
    fi
}
test_ticket_init_adds_to_git_info_exclude

print_summary
