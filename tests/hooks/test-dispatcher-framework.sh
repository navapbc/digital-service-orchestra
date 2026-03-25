#!/usr/bin/env bash
# tests/hooks/test-dispatcher-framework.sh
# Unit tests for dispatcher.sh and is_worktree()/EXCLUDE_PATTERNS additions to deps.sh.
#
# Usage: bash tests/hooks/test-dispatcher-framework.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail
# Note: set -e omitted intentionally — tests call functions that return non-zero
# and we handle failures via assert_eq/assert_ne/assert_contains, not exit-on-error.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/dispatcher.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# ============================================================
# Helpers
# ============================================================

# make_allow_hook: write a hook function that exits 0 (allow)
make_allow_hook() {
    local tmpfile
    tmpfile=$(mktemp /tmp/test-dispatcher-allow-XXXXXX)
    _CLEANUP_DIRS+=("$tmpfile")
    cat >"$tmpfile" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
    chmod +x "$tmpfile"
    echo "$tmpfile"
}

# make_block_hook: write a hook function that exits 2 (block) with a deny JSON on stdout
make_block_hook() {
    local name="$1"
    local tmpfile
    tmpfile=$(mktemp /tmp/test-dispatcher-block-XXXXXX)
    _CLEANUP_DIRS+=("$tmpfile")
    cat >"$tmpfile" <<EOF
#!/usr/bin/env bash
echo '{"decision":"block","reason":"${name} blocked"}'
exit 2
EOF
    chmod +x "$tmpfile"
    echo "$tmpfile"
}

# make_deny_hook: write a hook that exits 2 and outputs permissionDecision JSON to stdout
make_deny_hook() {
    local tmpfile
    tmpfile=$(mktemp /tmp/test-dispatcher-deny-XXXXXX)
    _CLEANUP_DIRS+=("$tmpfile")
    cat >"$tmpfile" <<'EOF'
#!/usr/bin/env bash
printf '{"decision":"deny","reason":"denied by test hook"}'
exit 2
EOF
    chmod +x "$tmpfile"
    echo "$tmpfile"
}

# ============================================================
# test_run_hooks_exits_0_when_all_hooks_allow
# When every hook in the list exits 0, run_hooks must return 0.
# ============================================================
echo "--- test_run_hooks_exits_0_when_all_hooks_allow ---"
_h1=$(make_allow_hook "h1")
_h2=$(make_allow_hook "h2")
_INPUT='{"tool_name":"Bash","tool_input":{"command":"ls"}}'
_exit_code=0
run_hooks "$_INPUT" "$_h1" "$_h2" || _exit_code=$?
assert_eq "test_run_hooks_exits_0_when_all_hooks_allow" "0" "$_exit_code"
rm -f "$_h1" "$_h2"

# ============================================================
# test_run_hooks_exits_2_when_hook_blocks
# When a hook exits 2, run_hooks must propagate exit code 2.
# ============================================================
echo "--- test_run_hooks_exits_2_when_hook_blocks ---"
_h_allow=$(make_allow_hook "allow")
_h_block=$(make_block_hook "block")
_INPUT='{"tool_name":"Bash","tool_input":{"command":"ls"}}'
_exit_code=0
run_hooks "$_INPUT" "$_h_allow" "$_h_block" || _exit_code=$?
assert_eq "test_run_hooks_exits_2_when_hook_blocks" "2" "$_exit_code"
rm -f "$_h_allow" "$_h_block"

# ============================================================
# test_run_hooks_outputs_permission_decision_json_on_deny
# When a hook exits 2 and writes permissionDecision JSON to stdout,
# run_hooks must echo that JSON on its own stdout.
# ============================================================
echo "--- test_run_hooks_outputs_permission_decision_json_on_deny ---"
_h_deny=$(make_deny_hook)
_INPUT='{"tool_name":"Bash","tool_input":{"command":"ls"}}'
_output=""
_exit_code=0
_output=$(run_hooks "$_INPUT" "$_h_deny" 2>/dev/null) || _exit_code=$?
assert_eq "test_run_hooks_outputs_permission_decision_json_on_deny: exit 2" "2" "$_exit_code"
assert_contains "test_run_hooks_outputs_permission_decision_json_on_deny: json output" \
    "deny" "$_output"
rm -f "$_h_deny"

# ============================================================
# test_run_hooks_stops_at_first_block
# When the first hook blocks, the second hook must NOT run.
# We verify this by having the second hook write a sentinel to a temp file;
# if the file is created, the second hook ran (failure).
# ============================================================
echo "--- test_run_hooks_stops_at_first_block ---"
_sentinel=$(mktemp /tmp/test-dispatcher-sentinel.XXXXXX)
_CLEANUP_DIRS+=("$_sentinel")
rm -f "$_sentinel"   # ensure it doesn't exist yet

_h_block_first=$(make_block_hook "first")
_h_sentinel=$(mktemp /tmp/test-dispatcher-sentinel-hook-XXXXXX)
_CLEANUP_DIRS+=("$_h_sentinel")
cat >"$_h_sentinel" <<EOF
#!/usr/bin/env bash
touch "${_sentinel}"
exit 0
EOF
chmod +x "$_h_sentinel"

_INPUT='{"tool_name":"Bash","tool_input":{"command":"ls"}}'
_exit_code=0
run_hooks "$_INPUT" "$_h_block_first" "$_h_sentinel" 2>/dev/null || _exit_code=$?

if [[ -f "$_sentinel" ]]; then
    assert_eq "test_run_hooks_stops_at_first_block: sentinel must NOT exist" "no" "yes"
else
    assert_eq "test_run_hooks_stops_at_first_block: sentinel must NOT exist" "no" "no"
fi

rm -f "$_h_block_first" "$_h_sentinel" "$_sentinel"

# ============================================================
# test_is_worktree_returns_false_in_main_repo
# In the main repo, .git is a directory → is_worktree returns 1 (false).
# We create a temp main repo and verify.
# ============================================================
echo "--- test_is_worktree_returns_false_in_main_repo ---"
_main_repo=$(mktemp -d)
_CLEANUP_DIRS+=("$_main_repo")
git -C "$_main_repo" init -q -b main 2>/dev/null || git -C "$_main_repo" init -q
git -C "$_main_repo" config user.email "test@test.com"
git -C "$_main_repo" config user.name "Test"
git -C "$_main_repo" commit --allow-empty -q -m "init"

# .git is a directory in a fresh repo → is_worktree should return 1
_is_wt_exit=0
(cd "$_main_repo" && is_worktree) || _is_wt_exit=$?
assert_eq "test_is_worktree_returns_false_in_main_repo" "1" "$_is_wt_exit"
rm -rf "$_main_repo"

# ============================================================
# test_exclude_patterns_contains_tickets_dir
# EXCLUDE_PATTERNS must include a pattern that matches .tickets-tracker/ paths.
# ============================================================
echo "--- test_exclude_patterns_contains_tickets_dir ---"
_matched=0
for _pat in "${EXCLUDE_PATTERNS[@]}"; do
    if [[ ".tickets-tracker/somefile.md" == *"$_pat"* ]] || \
       [[ "path/.tickets-tracker/file.md" == *"$_pat"* ]] || \
       echo ".tickets-tracker/somefile.md" | grep -qE "$_pat" 2>/dev/null || \
       [[ "$_pat" == *".tickets-tracker"* ]]; then
        _matched=1
        break
    fi
done
assert_eq "test_exclude_patterns_contains_tickets_dir" "1" "$_matched"

# ============================================================
# test_no_duplicate_worktree_detection_in_hook_files
# is_worktree() in deps.sh should be the single source of truth.
# Hook files should NOT contain inline worktree detection patterns
# that duplicate the is_worktree() logic (the pattern: -f "$X/.git").
# We verify the dispatcher.sh itself does not inline worktree detection.
# ============================================================
echo "--- test_no_duplicate_worktree_detection_in_hook_files ---"
_dispatcher_path="$DSO_PLUGIN_DIR/hooks/lib/dispatcher.sh"
# Check that dispatcher.sh does NOT contain the old inline pattern
# '[[ -f "$..../\.git" ]]' directly (it should call is_worktree instead).
# We allow the is_worktree function definition in deps.sh.
_found_inline=0
if grep -qE '^\s*\[\[.*-f.*\.git.*\]\]' "$_dispatcher_path" 2>/dev/null; then
    _found_inline=1
fi
assert_eq "test_no_duplicate_worktree_detection_in_hook_files: dispatcher.sh has no inline worktree check" \
    "0" "$_found_inline"

# ============================================================
# Summary
# ============================================================
print_summary
