#!/usr/bin/env bash
# tests/hooks/test-pre-bash-dispatcher.sh
# Unit tests for the pre-bash dispatcher and the hook functions it sources.
#
# Tests:
#   test_pre_bash_dispatcher_exits_0_for_exempt_command
#   test_pre_bash_dispatcher_exits_0_for_plain_commit_no_bypass
#
# Usage: bash tests/hooks/test-pre-bash-dispatcher.sh
# Exit code: 0 if all pass, 1 if any fail

set -uo pipefail
# Note: set -e omitted intentionally — tests call functions that return non-zero
# and we handle failures via assert_eq/assert_contains, not exit-on-error.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

DISPATCHER="$DSO_PLUGIN_DIR/hooks/dispatchers/pre-bash.sh"

# ============================================================
# test_pre_bash_dispatcher_exits_0_for_exempt_command
# The dispatcher must allow a simple read-only command (e.g., `ls`) with no
# blocking conditions — all 7 hooks should pass through with exit 0.
# ============================================================
echo "--- test_pre_bash_dispatcher_exits_0_for_exempt_command ---"
_INPUT='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
_exit_code=0
printf '%s' "$_INPUT" | bash "$DISPATCHER" 2>/dev/null || _exit_code=$?
assert_eq "test_pre_bash_dispatcher_exits_0_for_exempt_command" "0" "$_exit_code"

# ============================================================
# test_pre_bash_dispatcher_exits_0_for_plain_commit_no_bypass
# After Story 1idf, the old hook_review_gate was removed from the PreToolUse dispatcher.
# Review enforcement moved to Layer 1 (git pre-commit hook). The PreToolUse dispatcher
# now exits 0 for a plain `git commit` (no bypass vectors) — the pre-commit hook handles
# the review check at actual commit time.
# The bypass sentinel (Layer 2) only blocks explicit bypass vectors (--no-verify, etc.).
# ============================================================
echo "--- test_pre_bash_dispatcher_exits_0_for_plain_commit_no_bypass ---"

# Set up an isolated temp git repo with a staged non-tracker file
_test_git_repo=$(mktemp -d)
_test_artifacts_dir=$(mktemp -d)
trap 'rm -rf "$_test_git_repo" "$_test_artifacts_dir"' EXIT

git -C "$_test_git_repo" init -q -b main 2>/dev/null || git -C "$_test_git_repo" init -q
git -C "$_test_git_repo" config user.email "test@test.com"
git -C "$_test_git_repo" config user.name "Test"
# Stage a non-tracker file
echo "test content" > "$_test_git_repo/app.py"
git -C "$_test_git_repo" add app.py

_INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test\""}}'
_exit_code=0
_output=""
# Run dispatcher from inside the temp git repo; plain commit should pass through
# (review check happens in pre-commit hook, not PreToolUse)
_output=$(cd "$_test_git_repo" && printf '%s' "$_INPUT" | ARTIFACTS_DIR="$_test_artifacts_dir" bash "$DISPATCHER" 2>&1) || _exit_code=$?
assert_eq "test_pre_bash_dispatcher_exits_0_for_plain_commit_no_bypass: exit 0" "0" "$_exit_code"

# ============================================================
# test_pre_bash_dispatcher_non_exit2_codes_pass_through
# When a hook function returns a non-zero, non-2 exit code (e.g., 1 or 3),
# the dispatcher must NOT block — the fail-open ERR trap inside each hook
# converts non-2 exits to 0.
# ============================================================
echo "--- test_pre_bash_dispatcher_non_exit2_codes_pass_through ---"
_INPUT='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
_exit_code=0
# Source the dispatcher to get hook functions, then override one to return 1
(
    source "$DISPATCHER"
    # Override hook_commit_failure_tracker to simulate a non-2 failure
    hook_commit_failure_tracker() { return 1; }
    printf '%s' "$_INPUT" | _pre_bash_dispatch
) 2>/dev/null || _exit_code=$?
assert_eq "test_pre_bash_dispatcher_non_exit2_codes_pass_through: exit 0 (not blocked)" "0" "$_exit_code"

# Set up a temp repo used by the cat_command and review_integrity_guard tests below.
_bug_test_repo=$(mktemp -d)
_bug_artifacts_dir=$(mktemp -d)
trap 'rm -rf "$_bug_test_repo" "$_bug_artifacts_dir"' EXIT

git -C "$_bug_test_repo" init -q -b main 2>/dev/null || git -C "$_bug_test_repo" init -q
git -C "$_bug_test_repo" config user.email "test@test.com"
git -C "$_bug_test_repo" config user.name "Test"
echo "init" > "$_bug_test_repo/README.md"
git -C "$_bug_test_repo" add README.md
git -C "$_bug_test_repo" commit -q -m "init"

# ============================================================
# test_pre_bash_dispatcher_cat_command_exits_0
# After tool_use_guard removal, `cat` commands should still exit 0 (no warning).
# ============================================================
echo "--- test_pre_bash_dispatcher_cat_command_exits_0 ---"
_INPUT='{"tool_name":"Bash","tool_input":{"command":"cat /tmp/somefile.txt"}}'
_exit_code=0
_output=""
_output=$(cd "$_bug_test_repo" && printf '%s' "$_INPUT" | ARTIFACTS_DIR="$_bug_artifacts_dir" bash "$DISPATCHER" 2>&1) || _exit_code=$?
assert_eq "test_pre_bash_dispatcher_cat_command_exits_0: exit 0" "0" "$_exit_code"

# ============================================================
# test_pre_bash_dispatcher_review_integrity_guard_blocks_direct_write
# The review-integrity-guard must block direct writes to review-status files.
# ============================================================
echo "--- test_pre_bash_dispatcher_review_integrity_guard_blocks_direct_write ---"
_INPUT='{"tool_name":"Bash","tool_input":{"command":"echo passed > /tmp/artifacts/review-status"}}'
_exit_code=0
_output=""
_output=$(cd "$_bug_test_repo" && printf '%s' "$_INPUT" | ARTIFACTS_DIR="$_bug_artifacts_dir" bash "$DISPATCHER" 2>&1) || _exit_code=$?
assert_eq "test_pre_bash_dispatcher_review_integrity_guard_blocks_direct_write: exit 2" "2" "$_exit_code"
assert_contains "test_pre_bash_dispatcher_review_integrity_guard_blocks_direct_write: BLOCKED in output" \
    "BLOCKED" "$_output"

# ============================================================
# test_pre_bash_no_tool_logging_pre
# After tool_logging_pre removal, the pre-bash dispatcher must NOT
# call hook_tool_logging_pre — no JSONL log entry should be created.
# ============================================================
echo "--- test_pre_bash_no_tool_logging_pre ---"

_log_test_dir=$(mktemp -d)
_log_test_logdir="$_log_test_dir/.claude/logs"
mkdir -p "$_log_test_logdir"
mkdir -p "$_log_test_dir/.claude"
# Enable tool logging
touch "$_log_test_dir/.claude/tool-logging-enabled"

_INPUT='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
_exit_code=0
# Run the dispatcher with HOME overridden
_output=$(HOME="$_log_test_dir" printf '%s' "$_INPUT" | HOME="$_log_test_dir" bash "$DISPATCHER" 2>/dev/null) || _exit_code=$?
assert_eq "test_pre_bash_no_tool_logging_pre: exit 0" "0" "$_exit_code"

# Verify NO JSONL log file was created (tool logging removed from dispatchers)
_log_file=$(ls "$_log_test_logdir"/tool-use-*.jsonl 2>/dev/null | head -1)
_log_exists=0
[[ -n "$_log_file" ]] && [[ -f "$_log_file" ]] && _log_exists=1
assert_eq "test_pre_bash_no_tool_logging_pre: no JSONL log file created" "0" "$_log_exists"

rm -rf "$_log_test_dir"

# ============================================================
# test_pre_bash_timing_instrumentation
# When ~/.claude/hook-timing-enabled exists, the pre-bash dispatcher
# must write timing data to /tmp/hook-timing.log.
# ============================================================
echo "--- test_pre_bash_timing_instrumentation ---"

_timing_test_dir=$(mktemp -d)
mkdir -p "$_timing_test_dir/.claude"
# Enable timing instrumentation
touch "$_timing_test_dir/.claude/hook-timing-enabled"
# Also enable tool logging so the timing branch for tool-logging-pre fires
touch "$_timing_test_dir/.claude/tool-logging-enabled"
mkdir -p "$_timing_test_dir/.claude/logs"

# Use HOOK_TIMING_LOG env var to redirect timing to a unique test log
_timing_log="/tmp/hook-timing-test-pre-$$.log"
rm -f "$_timing_log"

# Save/restore /tmp/hook-timing.log to avoid interfering with real timing data
_saved_timing_file="/tmp/hook-timing-saved-pre-$$"
cp /tmp/hook-timing.log "$_saved_timing_file" 2>/dev/null || true

_INPUT='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'
_exit_code=0
# Override HOME so timing-enabled sentinel is found; use HOOK_TIMING_LOG env var
printf '%s' "$_INPUT" | HOME="$_timing_test_dir" HOOK_TIMING_LOG="$_timing_log" bash "$DISPATCHER" 2>/dev/null || _exit_code=$?

# Check if timing log was created with timing entries
_has_timing=0
if [[ -f "$_timing_log" ]]; then
    if grep -qE 'hook_.*[0-9]+ms.*exit=' "$_timing_log" 2>/dev/null; then
        _has_timing=1
    fi
fi
assert_eq "test_pre_bash_timing_instrumentation: timing log entries created" "1" "$_has_timing"

# Restore previous timing log content
if [[ -f "$_saved_timing_file" ]]; then
    cp "$_saved_timing_file" /tmp/hook-timing.log
    rm -f "$_saved_timing_file"
else
    rm -f /tmp/hook-timing.log
fi

# Cleanup
rm -f "$_timing_log"
rm -rf "$_timing_test_dir"

# ============================================================
# test_pre_bash_dispatcher_record_test_status_direct_call_blocked
# The dispatcher must block direct calls to record-test-status.sh that do
# NOT include the --attest flag. Agents calling record-test-status.sh
# directly bypass staged-file context and diff_hash binding, which is a
# security/integrity violation. The hook_record_test_status_guard (entry 8
# in the dispatch loop, before hook_tickets_tracker_bash_guard) must
# intercept these calls and return exit 2.
# ============================================================
echo "--- test_pre_bash_dispatcher_record_test_status_direct_call_blocked ---"
_INPUT='{"tool_name":"Bash","tool_input":{"command":"bash plugins/dso/hooks/record-test-status.sh --source-file=foo.py"}}'
_exit_code=0
_output=""
_output=$(printf '%s' "$_INPUT" | CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" bash "$DISPATCHER" 2>&1) || _exit_code=$?
assert_eq "test_pre_bash_dispatcher_record_test_status_direct_call_blocked: exit 2" "2" "$_exit_code"
assert_contains "test_pre_bash_dispatcher_record_test_status_direct_call_blocked: BLOCKED in output" \
    "BLOCKED" "$_output"

# ============================================================
# test_pre_bash_dispatcher_record_test_status_attest_allowed
# When record-test-status.sh is called WITH the --attest flag, the
# dispatcher must allow the command (return exit 0). The --attest path is
# the legitimate worktree trust-transfer mechanism used by harvest-worktree.sh
# and must not be blocked.
# ============================================================
echo "--- test_pre_bash_dispatcher_record_test_status_attest_allowed ---"
_INPUT='{"tool_name":"Bash","tool_input":{"command":"bash plugins/dso/hooks/record-test-status.sh --attest --source-file=foo.py passed abc123"}}'
_exit_code=0
printf '%s' "$_INPUT" | CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" bash "$DISPATCHER" 2>/dev/null || _exit_code=$?
assert_ne "test_pre_bash_dispatcher_record_test_status_attest_allowed: not exit 2 (should be allowed)" "2" "$_exit_code"

# ============================================================
# Summary
# ============================================================
print_summary
