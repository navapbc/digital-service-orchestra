#!/usr/bin/env bash
# tests/scripts/test-claude-safe-tickets-dir.sh
# Tests for _offer_worktree_cleanup behavior in scripts/claude-safe.
#
# Verifies:
# - _read_cfg correctly reads tickets.directory from workflow-config.conf
# - _offer_worktree_cleanup blocks auto-removal when .tickets/ files are dirty
#   (any uncommitted changes, including .tickets/, prevent auto-removal)
#
# Usage: bash tests/scripts/test-claude-safe-tickets-dir.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
CLAUDE_SAFE="$DSO_PLUGIN_DIR/scripts/claude-safe"
PLUGIN_SCRIPTS="$DSO_PLUGIN_DIR/scripts"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-claude-safe-tickets-dir.sh ==="

# ── Setup: shared tmpdir, cleaned on EXIT ─────────────────────────────────────
TMPDIR_BASE=$(mktemp -d /tmp/test-claude-safe-tickets-dir.XXXXXX)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ── Resolve Python with pyyaml for read-config.sh ────────────────────────────
# read-config.sh probes $REPO_ROOT/app/.venv/bin/python3 but only when run from
# inside a git repo. Sub-shells in /tmp have no REPO_ROOT, so we resolve it
# explicitly and inject via CLAUDE_PLUGIN_PYTHON.
PLUGIN_PYTHON=""
for _candidate in \
    "$REPO_ROOT/app/.venv/bin/python3" \
    "$REPO_ROOT/.venv/bin/python3" \
    "python3"; do
    [[ -z "$_candidate" ]] && continue
    [[ "$_candidate" != "python3" ]] && [[ ! -f "$_candidate" ]] && continue
    if "$_candidate" -c "import yaml" 2>/dev/null; then
        PLUGIN_PYTHON="$_candidate"
        break
    fi
done
if [[ -z "$PLUGIN_PYTHON" ]]; then
    echo "SKIP: no python3 with pyyaml found — cannot run config-reading tests" >&2
    exit 0
fi

# ── Helper: source claude-safe in source-only mode and call _read_cfg ─────────
# Args: $1 = config file path, $2 = key to read
_read_cfg_from_config() {
    local config_file="$1"
    local key="$2"
    WORKFLOW_CONFIG="$config_file" \
    _CLAUDE_SAFE_SOURCE_ONLY=1 \
    PLUGIN_SCRIPTS="$PLUGIN_SCRIPTS" \
    CLAUDE_PLUGIN_PYTHON="$PLUGIN_PYTHON" \
    bash -c "
        source \"$CLAUDE_SAFE\"
        _read_cfg \"$key\"
    " 2>/dev/null
}

# ── Create fixture config dirs ─────────────────────────────────────────────────
# custom-tickets config (used by _read_cfg tests)
cfg_custom_dir="$TMPDIR_BASE/custom-dir"
mkdir -p "$cfg_custom_dir"
cat > "$cfg_custom_dir/workflow-config.conf" <<CONF
tickets.directory=custom-tickets
CONF

# absent tickets.directory config (fallback tests)
cfg_absent_dir="$TMPDIR_BASE/absent"
mkdir -p "$cfg_absent_dir"
cat > "$cfg_absent_dir/workflow-config.conf" <<CONF

CONF

# ── test_tickets_directory_read_from_config ───────────────────────────────────
# When tickets.directory is set in workflow-config.conf, _read_cfg must
# return the configured value.
echo ""
echo "--- test_tickets_directory_read_from_config ---"
_snapshot_fail

read_result=""
read_result=$(_read_cfg_from_config "$cfg_custom_dir/workflow-config.conf" "tickets.directory") || true

assert_eq "test_tickets_directory_read_from_config: returns configured value" \
    "custom-tickets" "$read_result"
assert_pass_if_clean "test_tickets_directory_read_from_config"

# ── test_tickets_directory_absent_returns_empty ───────────────────────────────
# When tickets.directory is absent from config, _read_cfg returns empty
# (the caller applies the ':-.tickets' fallback inline).
echo ""
echo "--- test_tickets_directory_absent_returns_empty ---"
_snapshot_fail

absent_result=""
absent_result=$(_read_cfg_from_config "$cfg_absent_dir/workflow-config.conf" "tickets.directory") || true

assert_eq "test_tickets_directory_absent_returns_empty: empty string when key absent" \
    "" "$absent_result"
assert_pass_if_clean "test_tickets_directory_absent_returns_empty"

# ── test_tickets_directory_fallback_applied ───────────────────────────────────
# Verify the fallback logic: when _read_cfg returns empty, the ':-.tickets'
# expansion produces '.tickets'.  This mirrors the in-function logic exactly:
#   tickets_dir=$(_read_cfg tickets.directory 2>/dev/null) || true
#   tickets_dir="${tickets_dir:-.tickets}"
echo ""
echo "--- test_tickets_directory_fallback_applied ---"
_snapshot_fail

# Write a helper script to avoid quoting complexity
_fallback_helper="$TMPDIR_BASE/fallback-helper.sh"
cat > "$_fallback_helper" << HELPER
#!/usr/bin/env bash
source "$CLAUDE_SAFE"
tickets_dir=\$(_read_cfg tickets.directory 2>/dev/null) || true
tickets_dir="\${tickets_dir:-.tickets}"
echo "\$tickets_dir"
HELPER

fallback_result=""
fallback_result=$(
    WORKFLOW_CONFIG="$cfg_absent_dir/workflow-config.conf" \
    _CLAUDE_SAFE_SOURCE_ONLY=1 \
    PLUGIN_SCRIPTS="$PLUGIN_SCRIPTS" \
    CLAUDE_PLUGIN_PYTHON="$PLUGIN_PYTHON" \
    bash "$_fallback_helper"
) || true

assert_eq "test_tickets_directory_fallback_applied: defaults to .tickets" \
    ".tickets" "$fallback_result"
assert_pass_if_clean "test_tickets_directory_fallback_applied"

# ── test_tickets_directory_custom_value_passed_through ───────────────────────
# When tickets.directory is set, the same ':-.tickets' expansion must pass
# the configured value through unchanged.
echo ""
echo "--- test_tickets_directory_custom_value_passed_through ---"
_snapshot_fail

_passthrough_helper="$TMPDIR_BASE/passthrough-helper.sh"
cat > "$_passthrough_helper" << HELPER
#!/usr/bin/env bash
source "$CLAUDE_SAFE"
tickets_dir=\$(_read_cfg tickets.directory 2>/dev/null) || true
tickets_dir="\${tickets_dir:-.tickets}"
echo "\$tickets_dir"
HELPER

passthrough_result=""
passthrough_result=$(
    WORKFLOW_CONFIG="$cfg_custom_dir/workflow-config.conf" \
    _CLAUDE_SAFE_SOURCE_ONLY=1 \
    PLUGIN_SCRIPTS="$PLUGIN_SCRIPTS" \
    CLAUDE_PLUGIN_PYTHON="$PLUGIN_PYTHON" \
    bash "$_passthrough_helper"
) || true

assert_eq "test_tickets_directory_custom_value_passed_through: custom value survives fallback" \
    "custom-tickets" "$passthrough_result"
assert_pass_if_clean "test_tickets_directory_custom_value_passed_through"

# ── test_tickets_dir_dirty_blocks_auto_removal ───────────────────────────────
# When a worktree has only .tickets/ files dirty (untracked), and the branch IS
# merged to main, _offer_worktree_cleanup must still output 'cannot be auto-removed'
# because git status --porcelain is non-empty.
#
# Uses a real temp git repo (not PATH stubs) because _offer_worktree_cleanup
# calls git -C $wt_path and git -C $main_root in subshells where function
# overrides do not intercept.
echo ""
echo "--- test_tickets_dir_dirty_blocks_auto_removal ---"
_snapshot_fail

_main_repo="$TMPDIR_BASE/main-repo"
_wt_path="$TMPDIR_BASE/wt-dirty-tickets"
_test_branch="test-branch-tickets-dirty"

mkdir -p "$_main_repo"
(
    set -e
    cd "$_main_repo"
    git init -q -b main
    git config user.email "test@test.com"
    git config user.name "Test"
    git commit --allow-empty -q -m "init"
    git checkout -q -b "$_test_branch"
    git checkout -q main 2>/dev/null || git checkout -q -b main HEAD
)

# Ensure we have a 'main' branch
(
    cd "$_main_repo"
    git branch 2>/dev/null | grep -q 'main' || git branch -m master main 2>/dev/null || true
) 2>/dev/null || true

# Add worktree on test branch
(
    cd "$_main_repo"
    git worktree add -q "$_wt_path" "$_test_branch" 2>/dev/null || true
)

# Make the test branch an ancestor of main (already is since it branched from init)
# merge-base --is-ancestor should return 0 since test-branch has no new commits yet

# Create an untracked .tickets/ file in the worktree (makes porcelain non-empty)
mkdir -p "$_wt_path/.tickets"
touch "$_wt_path/.tickets/new-ticket.md"

# Capture output of _offer_worktree_cleanup. The function guards with [ ! -t 0 ]
# (stdin must be a terminal). We set _CLAUDE_SAFE_TEST_INTERACTIVE=1 to bypass
# the terminal check so the function runs in non-interactive test contexts.
# (This env var is honoured by the production function — see claude-safe source.)
_cleanup_output=""
_cleanup_output=$(
    _CLAUDE_SAFE_SOURCE_ONLY=1 \
    _CLAUDE_SAFE_TEST_INTERACTIVE=1 \
    PLUGIN_SCRIPTS="$PLUGIN_SCRIPTS" \
    CLAUDE_PLUGIN_PYTHON="$PLUGIN_PYTHON" \
    bash -c "source \"$CLAUDE_SAFE\"; _offer_worktree_cleanup 'test-wt' '$_wt_path'"
) 2>&1 || true

assert_contains "test_tickets_dir_dirty_blocks_auto_removal: output contains 'cannot be auto-removed'" \
    "cannot be auto-removed" "$_cleanup_output"
assert_pass_if_clean "test_tickets_dir_dirty_blocks_auto_removal"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
