#!/usr/bin/env bash
# tests/scripts/test-worktree-post-create-cmd-config.sh
# Tests that dso-config.conf contains the worktree.post_create_cmd key
# readable by read-config.sh.
#
# Usage: bash tests/scripts/test-worktree-post-create-cmd-config.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SCRIPT="$DSO_PLUGIN_DIR/scripts/read-config.sh"

# Create an inline fixture config instead of depending on project config
CONFIG="$(mktemp)"
trap 'rm -f "$CONFIG"' EXIT
cat > "$CONFIG" <<'FIXTURE'
worktree.post_create_cmd=./scripts/setup-worktree.sh
FIXTURE

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-worktree-post-create-cmd-config.sh ==="

# ── test_worktree_post_create_cmd_config_readable ────────────────────────────
# worktree.post_create_cmd must return the configured value
_snapshot_fail
wt_exit=0
wt_output=""
wt_output=$(bash "$SCRIPT" "$CONFIG" "worktree.post_create_cmd" 2>&1) || wt_exit=$?
assert_eq "test_worktree_post_create_cmd_config_readable: exit 0" "0" "$wt_exit"
assert_eq "test_worktree_post_create_cmd_config_readable: value is ./scripts/setup-worktree.sh" "./scripts/setup-worktree.sh" "$wt_output"
assert_pass_if_clean "test_worktree_post_create_cmd_config_readable"

print_summary
