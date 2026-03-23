#!/usr/bin/env bash
# tests/hooks/test-hook-optimization.sh
# Tests for hook dispatcher optimization (Story ild8):
#   - REPO_ROOT caching (at most 1 git rev-parse --show-toplevel per dispatcher)
#   - tool_logging removed from all dispatchers
#   - tool_use_guard removed from all dispatchers
#   - early-exit guards in post-bash validation/cascade
#   - validation_gate removed from pre-edit.sh and pre-write.sh
#   - preserved hooks: exit_144_forensic_logger, review_gate, commit_failure_tracker
#
# Usage: bash tests/hooks/test-hook-optimization.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

DISPATCHERS_DIR="$DSO_PLUGIN_DIR/hooks/dispatchers"
PRE_BASH_FUNCTIONS="$DSO_PLUGIN_DIR/hooks/lib/pre-bash-functions.sh"
POST_FUNCTIONS="$DSO_PLUGIN_DIR/hooks/lib/post-functions.sh"

# ============================================================
# AC: Each dispatcher has at most 1 git rev-parse --show-toplevel call
# ============================================================
echo "--- test_repo_root_caching_at_most_one_rev_parse ---"
for f in "$DISPATCHERS_DIR"/*.sh; do
    _count="$(grep -c 'git rev-parse --show-toplevel' "$f" 2>/dev/null)" || _count="0"
    _name=$(basename "$f")
    # At most 1 call per dispatcher file
    _ok=1
    if [ "$_count" -gt 1 ]; then _ok=0; fi
    assert_eq "repo_root_caching: $_name has at most 1 rev-parse ($_count found)" "1" "$_ok"
done

# ============================================================
# AC: tool_logging_pre removed from all dispatchers
# ============================================================
echo "--- test_tool_logging_pre_removed ---"
_found=0
grep -rq 'tool_logging_pre\|hook_tool_logging_pre' "$DISPATCHERS_DIR/" 2>/dev/null && _found=1
assert_eq "tool_logging_pre removed from all dispatchers" "0" "$_found"

# ============================================================
# AC: tool_logging_post removed from all dispatchers
# ============================================================
echo "--- test_tool_logging_post_removed ---"
_found=0
grep -rq 'tool_logging_post\|hook_tool_logging_post' "$DISPATCHERS_DIR/" 2>/dev/null && _found=1
assert_eq "tool_logging_post removed from all dispatchers" "0" "$_found"

# ============================================================
# AC: tool_use_guard removed from all dispatchers
# ============================================================
echo "--- test_tool_use_guard_removed ---"
_found=0
grep -rq 'tool_use_guard\|hook_tool_use_guard' "$DISPATCHERS_DIR/" 2>/dev/null && _found=1
assert_eq "tool_use_guard removed from all dispatchers" "0" "$_found"

# ============================================================
# AC: exit_144_forensic_logger preserved
# ============================================================
echo "--- test_exit_144_forensic_logger_preserved ---"
_found=0
grep -rq 'exit_144_forensic_logger\|hook_exit_144_forensic_logger' "$DISPATCHERS_DIR/" 2>/dev/null && _found=1
assert_eq "exit_144_forensic_logger preserved in dispatchers" "1" "$_found"

# ============================================================
# AC: review_gate preserved
# ============================================================
echo "--- test_review_gate_preserved ---"
_found=0
grep -rq 'review_gate\|hook_review_gate' "$DISPATCHERS_DIR/" 2>/dev/null && _found=1
assert_eq "review_gate preserved in dispatchers" "1" "$_found"

# ============================================================
# AC: commit_failure_tracker preserved
# ============================================================
echo "--- test_commit_failure_tracker_preserved ---"
_found=0
grep -rq 'commit_failure_tracker\|hook_commit_failure_tracker' "$DISPATCHERS_DIR/" 2>/dev/null && _found=1
assert_eq "commit_failure_tracker preserved in dispatchers" "1" "$_found"

# ============================================================
# AC: validation_gate removed from pre-edit.sh and pre-write.sh
# ============================================================
echo "--- test_validation_gate_removed_from_edit_write ---"
_found_edit=0
grep -q 'validation_gate' "$DISPATCHERS_DIR/pre-edit.sh" 2>/dev/null && _found_edit=1
assert_eq "validation_gate removed from pre-edit.sh" "0" "$_found_edit"

_found_write=0
grep -q 'validation_gate' "$DISPATCHERS_DIR/pre-write.sh" 2>/dev/null && _found_write=1
assert_eq "validation_gate removed from pre-write.sh" "0" "$_found_write"

# ============================================================
# Behavioral: post-bash validation/cascade checks still work for test commands
# ============================================================
echo "--- test_post_bash_still_runs_for_test_commands ---"
_INPUT='{"tool_name":"Bash","tool_input":{"command":"make test"},"tool_response":{"stdout":"","stderr":"FAILED","exit_code":1}}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$DISPATCHERS_DIR/post-bash.sh" >/dev/null 2>/dev/null || _exit_code=$?
assert_eq "post-bash exits 0 for test command (non-blocking)" "0" "$_exit_code"

# ============================================================
# Behavioral: pre-edit still works without validation_gate
# ============================================================
echo "--- test_pre_edit_still_allows_normal_edits ---"
_INPUT='{"tool_name":"Edit","tool_input":{"file_path":"'"$REPO_ROOT"'/app/src/some_module.py","old_string":"old","new_string":"new"}}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$DISPATCHERS_DIR/pre-edit.sh" 2>/dev/null || _exit_code=$?
assert_eq "pre-edit allows normal edits without validation_gate" "0" "$_exit_code"

# ============================================================
# Behavioral: pre-write still works without validation_gate
# ============================================================
echo "--- test_pre_write_still_allows_normal_writes ---"
_INPUT='{"tool_name":"Write","tool_input":{"file_path":"'"$REPO_ROOT"'/app/src/output.py","content":"print(\"hello\")"}}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$DISPATCHERS_DIR/pre-write.sh" 2>/dev/null || _exit_code=$?
assert_eq "pre-write allows normal writes without validation_gate" "0" "$_exit_code"

# ============================================================
# Structural: post-functions.sh no longer sources tool-logging in dispatchers
# (tool-logging functions may still be defined in post-functions.sh for
# backward compat, but dispatchers should not call them)
# ============================================================
echo "--- test_no_post_functions_source_for_logging_in_pre_dispatchers ---"
_found_edit=0
grep -q 'post-functions.sh' "$DISPATCHERS_DIR/pre-edit.sh" 2>/dev/null && _found_edit=1
assert_eq "pre-edit.sh no longer sources post-functions.sh" "0" "$_found_edit"

_found_write=0
grep -q 'post-functions.sh' "$DISPATCHERS_DIR/pre-write.sh" 2>/dev/null && _found_write=1
assert_eq "pre-write.sh no longer sources post-functions.sh" "0" "$_found_write"

# ============================================================
# Summary
# ============================================================
print_summary
