#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-worktree-post-create-cmd-config.sh
# Tests that workflow-config.conf contains the worktree.post_create_cmd key
# readable by read-config.sh.
#
# Usage: bash lockpick-workflow/tests/scripts/test-worktree-post-create-cmd-config.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/read-config.sh"
CONFIG="$REPO_ROOT/workflow-config.conf"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-worktree-post-create-cmd-config.sh ==="

# ── test_worktree_post_create_cmd_config_readable ────────────────────────────
# worktree.post_create_cmd must return "./scripts/worktree-setup-env.sh"
_snapshot_fail
wt_exit=0
wt_output=""
wt_output=$(bash "$SCRIPT" "$CONFIG" "worktree.post_create_cmd" 2>&1) || wt_exit=$?
assert_eq "test_worktree_post_create_cmd_config_readable: exit 0" "0" "$wt_exit"
assert_eq "test_worktree_post_create_cmd_config_readable: value is ./scripts/worktree-setup-env.sh" "./scripts/worktree-setup-env.sh" "$wt_output"
assert_pass_if_clean "test_worktree_post_create_cmd_config_readable"

print_summary
