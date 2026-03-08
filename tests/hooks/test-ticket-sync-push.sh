#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-ticket-sync-push.sh
# Tests for lockpick-workflow/hooks/ticket-sync-push.sh
#
# PostToolUse hook that fires when any file in .tickets/ is created or edited.
# Commits ONLY the changed .tickets/ files to main using git plumbing
# (detached-index via temporary GIT_INDEX_FILE).
#
# Usage: bash lockpick-workflow/tests/hooks/test-ticket-sync-push.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/ticket-sync-push.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

run_hook() {
    local input="$1"
    local exit_code=0
    echo "$input" | bash "$HOOK" >/dev/null 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# --------------------------------------------------------------------------
# test_ticket_sync_push_exits_zero_on_non_tickets_edit
# The hook should exit 0 when it receives a Bash tool call (not Edit/Write)
INPUT='{"tool_name":"Bash","tool_input":{"command":"make test"},"tool_response":{"exit_code":0}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_ticket_sync_push_exits_zero_on_non_tickets_edit" "0" "$EXIT_CODE"

# --------------------------------------------------------------------------
# test_ticket_sync_push_exits_zero_on_empty_input
# Empty stdin should exit 0 (no-op)
EXIT_CODE=$(run_hook "")
assert_eq "test_ticket_sync_push_exits_zero_on_empty_input" "0" "$EXIT_CODE"

# --------------------------------------------------------------------------
# test_ticket_sync_push_exits_zero_on_malformed_json
# Malformed JSON should not crash the hook
EXIT_CODE=$(run_hook "not json {{")
assert_eq "test_ticket_sync_push_exits_zero_on_malformed_json" "0" "$EXIT_CODE"

# --------------------------------------------------------------------------
# test_ticket_sync_push_exits_zero_on_edit_outside_tickets
# Edit of a non-.tickets/ file should be a no-op (exit 0)
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/app.py"},"tool_response":{"success":true}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_ticket_sync_push_exits_zero_on_edit_outside_tickets" "0" "$EXIT_CODE"

# --------------------------------------------------------------------------
# test_ticket_sync_push_exits_zero_on_tickets_edit
# Edit of a .tickets/*.md file should exit 0 (even if push fails in tests)
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$REPO_ROOT"'/.tickets/w21-1j46.md"},"tool_response":{"success":true}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_ticket_sync_push_exits_zero_on_tickets_edit" "0" "$EXIT_CODE"

# --------------------------------------------------------------------------
# test_ticket_sync_push_exits_zero_on_write_to_tickets
# Write to a .tickets/*.md file should exit 0 (even if push fails in tests)
INPUT='{"tool_name":"Write","tool_input":{"file_path":"'"$REPO_ROOT"'/.tickets/w22-dcjr.md"},"tool_response":{"success":true}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_ticket_sync_push_exits_zero_on_write_to_tickets" "0" "$EXIT_CODE"

# --------------------------------------------------------------------------
# test_ticket_sync_push_skips_when_not_in_worktree
# When .git is a directory (main repo), hook should skip gracefully and exit 0.
# We simulate this by running the hook in a temporary directory with a .git dir.
TMPDIR_MAIN=$(mktemp -d)
mkdir -p "$TMPDIR_MAIN/.git"  # Simulate main repo: .git is a directory
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$TMPDIR_MAIN"'/.tickets/test.md"},"tool_response":{"success":true}}'
SKIP_EXIT=$(echo "$INPUT" | GIT_DIR="$TMPDIR_MAIN/.git" GIT_WORK_TREE="$TMPDIR_MAIN" bash "$HOOK" >/dev/null 2>/dev/null; echo $?)
assert_eq "test_ticket_sync_push_skips_when_not_in_worktree" "0" "$SKIP_EXIT"
rm -rf "$TMPDIR_MAIN"

# --------------------------------------------------------------------------
# test_ticket_sync_push_exits_zero_on_missing_file_path
# Edit with no file_path should exit 0 (no-op)
INPUT='{"tool_name":"Edit","tool_input":{},"tool_response":{"success":true}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_ticket_sync_push_exits_zero_on_missing_file_path" "0" "$EXIT_CODE"

# --------------------------------------------------------------------------
# test_ticket_sync_push_exits_zero_when_push_fails
# Even when there is no remote or push fails, the hook must exit 0.
# Use a temp git repo with a .git FILE (simulating worktree) but no remote.
TMPDIR_PUSH=$(mktemp -d)
TMPDIR_MAIN_REPO=$(mktemp -d)
# Create a minimal main repo
git -C "$TMPDIR_MAIN_REPO" init -q -b main
git -C "$TMPDIR_MAIN_REPO" config user.email "test@test.com"
git -C "$TMPDIR_MAIN_REPO" config user.name "Test"
git -C "$TMPDIR_MAIN_REPO" commit --allow-empty -q -m "init"
# Create a worktree (.git is a FILE pointing to main repo)
git -C "$TMPDIR_MAIN_REPO" worktree add -q "$TMPDIR_PUSH" HEAD 2>/dev/null
PUSH_INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$TMPDIR_PUSH"'/.tickets/test.md"},"tool_response":{"success":true}}'
PUSH_EXIT=$(echo "$PUSH_INPUT" | bash "$HOOK" >/dev/null 2>/dev/null; echo $?)
assert_eq "test_ticket_sync_push_exits_zero_when_push_fails" "0" "$PUSH_EXIT"
git -C "$TMPDIR_MAIN_REPO" worktree remove --force "$TMPDIR_PUSH" 2>/dev/null || true
rm -rf "$TMPDIR_MAIN_REPO" "$TMPDIR_PUSH"

# --------------------------------------------------------------------------
# test_ticket_sync_push_registered_in_settings
# ticket-sync-push.sh must be registered in .claude/settings.json PostToolUse section
SETTINGS_FILE="$REPO_ROOT/.claude/settings.json"
REGISTERED=$(python3 -c "
import json, sys
try:
    with open('$SETTINGS_FILE') as f:
        d = json.load(f)
    hooks = d.get('hooks', {}).get('PostToolUse', [])
    for h in hooks:
        for cmd in h.get('hooks', []):
            if 'ticket-sync-push' in cmd.get('command', ''):
                print('FOUND')
                sys.exit(0)
    print('NOT_FOUND')
except Exception as e:
    print('ERROR: ' + str(e))
" 2>/dev/null || echo "ERROR")
assert_eq "test_ticket_sync_push_registered_in_settings" "FOUND" "$REGISTERED"

# --------------------------------------------------------------------------
print_summary
