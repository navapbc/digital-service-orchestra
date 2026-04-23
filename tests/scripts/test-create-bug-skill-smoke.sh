#!/usr/bin/env bash
# tests/scripts/test-create-bug-skill-smoke.sh
# Smoke tests for the /dso:create-bug skill guidance document.
#
# The /dso:create-bug skill is a GUIDANCE doc, not executable code.
# These tests validate that:
#   1. The skill file exists and references the bug-report-template.md
#   2. Creating a bug ticket following the template format produces a ticket
#      whose description contains Expected Behavior and Actual Behavior headers
#
# Usage: bash tests/scripts/test-create-bug-skill-smoke.sh

set -uo pipefail

# Unset git hook env vars so git -C commands target the correct repo.
# When run via record-test-status.sh from a pre-commit hook, GIT_DIR is
# inherited and causes git rev-parse --show-toplevel to return CWD instead
# of the repo root, breaking all subsequent path resolution.
unset GIT_DIR GIT_INDEX_FILE GIT_WORK_TREE GIT_COMMON_DIR 2>/dev/null || true

# Unset PROJECT_ROOT exported by the .claude/scripts/dso shim. Without this,
# ticket-create.sh and ticket-lib.sh both resolve REPO_ROOT to the host repo
# (via the shim-exported PROJECT_ROOT) instead of the isolated temp repo this
# test creates — leaking test tickets into the host tracker (bug bb42-1291).
unset PROJECT_ROOT 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
TICKET_CREATE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-create.sh"
TICKET_SHOW_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-show.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-create-bug-skill-smoke.sh ==="

# ── Helper: create a fresh temp git repo with ticket system initialized ───────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_test_repo "$tmp/repo"
    # GIT_CONFIG_NOSYSTEM + GIT_CONFIG_GLOBAL=/dev/null: prevent system/global git
    # config (e.g., SSH commit signing) from interfering with test repo git commits.
    # The test repo's .git/config has commit.gpgsign=false which is sufficient.
    local _init_stderr
    _init_stderr=$(mktemp)
    if ! (cd "$tmp/repo" && GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null bash "$TICKET_SCRIPT" init >/dev/null 2>"$_init_stderr"); then
        echo "DIAGNOSTIC: ticket init failed: $(cat "$_init_stderr")" >&2
    fi
    rm -f "$_init_stderr"
    echo "$tmp/repo"
}

# ── Test 1: Skill file exists and references bug-report-template.md ──────────
echo ""
echo "Test 1: Skill file exists and references bug-report-template.md"
test_skill_file_references_template() {
    local skill_file="$REPO_ROOT/plugins/dso/skills/create-bug/SKILL.md"
    local template_file="$REPO_ROOT/plugins/dso/skills/shared/prompts/bug-report-template.md"

    # Skill file must exist
    if [ -f "$skill_file" ]; then
        assert_eq "skill file exists" "exists" "exists"
    else
        assert_eq "skill file exists" "exists" "missing"
        return
    fi

    # Template file must exist
    if [ -f "$template_file" ]; then
        assert_eq "template file exists" "exists" "exists"
    else
        assert_eq "template file exists" "exists" "missing"
        return
    fi

    # Skill file must reference the template
    local skill_content
    skill_content=$(cat "$skill_file")
    assert_contains "skill references bug-report-template.md" "bug-report-template.md" "$skill_content"
}
test_skill_file_references_template

# ── Test 2: Bug ticket with template format preserves Expected/Actual headers ─
echo ""
echo "Test 2: Bug ticket created with template format contains Expected/Actual Behavior headers"
test_template_format_roundtrip() {
    local repo
    repo=$(_make_test_repo)

    local description
    description="### 2. Incident Overview

* **Scenario Type:** Sub-Agent Blocker

#### Expected Behavior

The system should process input without errors when given valid JSON.

#### Actual Behavior

The system exits with code 1 and prints 'Unexpected token' to stderr."

    # Create a bug ticket with a description following the template structure.
    # GIT_CONFIG_NOSYSTEM + GIT_CONFIG_GLOBAL=/dev/null: prevent system/global git
    # config (e.g., SSH commit signing) from causing git commits to fail in test repo.
    local ticket_id
    local _ticket_stderr
    _ticket_stderr=$(mktemp)
    ticket_id=$(cd "$repo" && GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null bash "$TICKET_CREATE_SCRIPT" bug "Parser: valid JSON input -> Unexpected token (exit 1)" -d "$description" 2>"$_ticket_stderr") || true
    if [ -z "$ticket_id" ] && [ -s "$_ticket_stderr" ]; then
        echo "DIAGNOSTIC: ticket-create stderr: $(cat "$_ticket_stderr")" >&2
    fi
    rm -f "$_ticket_stderr"

    if [ -z "$ticket_id" ]; then
        assert_eq "ticket created" "non-empty" "empty"
        return
    fi

    # Use ticket show to retrieve the ticket and check the description
    local show_output
    show_output=$(cd "$repo" && bash "$TICKET_SHOW_SCRIPT" "$ticket_id" 2>/dev/null) || true

    if [ -z "$show_output" ]; then
        assert_eq "ticket show output" "non-empty" "empty"
        return
    fi

    # Assert the show output contains Expected Behavior and Actual Behavior
    assert_contains "show output contains Expected Behavior" "Expected Behavior" "$show_output"
    assert_contains "show output contains Actual Behavior" "Actual Behavior" "$show_output"
}
test_template_format_roundtrip

print_summary
