#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-validation-gate.sh
# Comprehensive tests for .claude/hooks/validation-gate.sh
#
# Tests the validation gate hook by simulating JSON input and checking exit codes.
# Uses a temporary directory for state files to avoid interfering with real state.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/validation-gate.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# Temporary test directory
TEST_DIR=$(mktemp -d)
# Compute ARTIFACTS_DIR the same way the hook does (via get_artifacts_dir in lib/deps.sh).
# The hook uses a hash of REPO_ROOT to build /tmp/workflow-plugin-<hash>/.
# Writing state to the old /tmp/lockpick-test-artifacts-<worktree>/ path would have
# no effect because the hook only reads from the hash-based path.
# shellcheck source=lockpick-workflow/hooks/lib/deps.sh
source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"
ARTIFACTS_DIR=$(REPO_ROOT="$REPO_ROOT" get_artifacts_dir)
STATE_FILE="$ARTIFACTS_DIR/status"

# Save original state file if it exists
ORIGINAL_STATE=""
if [[ -f "$STATE_FILE" ]]; then
    ORIGINAL_STATE=$(cat "$STATE_FILE")
fi

# Counters
PASSED=0
FAILED=0
TOTAL=0

cleanup() {
    # Restore original state
    if [[ -n "$ORIGINAL_STATE" ]]; then
        mkdir -p "$ARTIFACTS_DIR"
        echo "$ORIGINAL_STATE" > "$STATE_FILE"
    elif [[ -f "$STATE_FILE" ]]; then
        rm -f "$STATE_FILE"
    fi
    rm -rf "$TEST_DIR"
}
trap cleanup EXIT

# Helper: set validation state
set_state() {
    case "$1" in
        not_run)
            rm -f "$STATE_FILE"
            ;;
        passed|failed)
            mkdir -p "$ARTIFACTS_DIR"
            echo "$1" > "$STATE_FILE"
            ;;
    esac
}

# Helper: run hook with simulated input, return exit code
run_hook() {
    local tool_name="$1"
    local tool_input="$2"
    local json

    if [[ "$tool_name" == "Bash" ]]; then
        json=$(jq -n --arg tn "$tool_name" --arg cmd "$tool_input" \
            '{tool_name: $tn, tool_input: {command: $cmd}}')
    elif [[ "$tool_name" == "Edit" ]] || [[ "$tool_name" == "Write" ]]; then
        json=$(jq -n --arg tn "$tool_name" --arg fp "$tool_input" \
            '{tool_name: $tn, tool_input: {file_path: $fp}}')
    else
        json=$(jq -n --arg tn "$tool_name" '{tool_name: $tn, tool_input: {}}')
    fi

    local exit_code=0
    echo "$json" | bash "$HOOK" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# Helper: assert exit code
assert_exit() {
    local description="$1"
    local expected="$2"
    local actual="$3"
    TOTAL=$((TOTAL + 1))

    if [[ "$actual" == "$expected" ]]; then
        PASSED=$((PASSED + 1))
        printf "  ✓ %s\n" "$description"
    else
        FAILED=$((FAILED + 1))
        printf "  ✗ %s (expected exit %s, got %s)\n" "$description" "$expected" "$actual"
    fi
}

# ============================================================
# Group 1: State = not_run
# ============================================================
echo ""
echo "=== Group 1: State = not_run ==="
set_state not_run

# In not_run state, only new-work commands are blocked.
# Non-new-work commands (Edit, Write, curl, etc.) are silently allowed.
result=$(run_hook "Edit" "/some/file.py")
assert_exit "Edit → allowed (not_run is silent allow for non-new-work)" "0" "$result"

result=$(run_hook "Write" "/some/file.py")
assert_exit "Write → allowed (not_run is silent allow for non-new-work)" "0" "$result"

result=$(run_hook "Bash" "curl http://example.com")
assert_exit "curl → allowed (not_run is silent allow for non-new-work)" "0" "$result"

# tk ready is a read-only query, not a new-work command
result=$(run_hook "Bash" "tk ready")
assert_exit "tk ready → allowed (read-only query, not new-work)" "0" "$result"

result=$(run_hook "Bash" "pwd")
assert_exit "pwd → exempt" "0" "$result"

result=$(run_hook "Bash" "git status")
assert_exit "git status → exempt" "0" "$result"

# ============================================================
# Group 2: State = passed
# ============================================================
echo ""
echo "=== Group 2: State = passed ==="
set_state passed

result=$(run_hook "Edit" "/some/file.py")
assert_exit "Edit → allowed" "0" "$result"

result=$(run_hook "Write" "/some/file.py")
assert_exit "Write → allowed" "0" "$result"

result=$(run_hook "Bash" "curl http://example.com")
assert_exit "curl → allowed" "0" "$result"

result=$(run_hook "Bash" "tk ready")
assert_exit "tk ready → allowed (passed state)" "0" "$result"

result=$(run_hook "Bash" "sprint --resume")
assert_exit "sprint → allowed (passed state)" "0" "$result"

result=$(run_hook "Bash" "python3 script.py")
assert_exit "python3 → allowed" "0" "$result"

# ============================================================
# Group 3: State = failed + Edit/Write (warning only)
# ============================================================
echo ""
echo "=== Group 3: State = failed + Edit/Write ==="
set_state failed

result=$(run_hook "Edit" "/some/file.py")
assert_exit "Edit → warning (exit 0)" "0" "$result"

result=$(run_hook "Write" "/some/file.py")
assert_exit "Write → warning (exit 0)" "0" "$result"

# ============================================================
# Group 4: State = failed + new-work commands (BLOCKED)
# ============================================================
echo ""
echo "=== Group 4: State = failed + new-work commands ==="
set_state failed

result=$(run_hook "Bash" "tk ready")
assert_exit "tk ready → allowed (read-only query)" "0" "$result"

result=$(run_hook "Bash" "tk ready --status=open")
assert_exit "tk ready --status=open → allowed (read-only query)" "0" "$result"

result=$(run_hook "Bash" "tk children epic-123")
assert_exit "tk children epic-123 → allowed (read-only query)" "0" "$result"

result=$(run_hook "Bash" "sprint-list-epics")
assert_exit "sprint-list-epics → blocked" "2" "$result"

result=$(run_hook "Bash" "sprint")
assert_exit "sprint (bare) → blocked" "2" "$result"

result=$(run_hook "Bash" "sprint --resume")
assert_exit "sprint --resume → blocked" "2" "$result"

# ============================================================
# Group 5: State = failed + fix/exempt commands (allowed)
# ============================================================
echo ""
echo "=== Group 5: State = failed + fix commands ==="
set_state failed

result=$(run_hook "Bash" "tk create --title=\"Fix bug\" --type=bug --priority=2")
assert_exit "tk create → allowed" "0" "$result"

result=$(run_hook "Bash" "tk update w20-abc1 --status=in_progress")
assert_exit "tk update → allowed" "0" "$result"

result=$(run_hook "Bash" "tk close w20-abc1")
assert_exit "tk close → allowed" "0" "$result"

result=$(run_hook "Bash" "tk show w20-abc1")
assert_exit "tk show → allowed" "0" "$result"

result=$(run_hook "Bash" "tk list --status=open")
assert_exit "tk list --status=open → allowed" "0" "$result"

result=$(run_hook "Bash" "tk list --type=task")
assert_exit "tk list --type=task → allowed" "0" "$result"

result=$(run_hook "Bash" "tk list --type=bug")
assert_exit "tk list --type=bug → allowed" "0" "$result"

result=$(run_hook "Bash" "tk ready --parent=w20-abc1")
assert_exit "tk ready --parent=X → allowed" "0" "$result"

result=$(run_hook "Bash" "make format")
assert_exit "make format → allowed" "0" "$result"

result=$(run_hook "Bash" "make lint")
assert_exit "make lint → allowed" "0" "$result"

result=$(run_hook "Bash" "make test")
assert_exit "make test → allowed" "0" "$result"

result=$(run_hook "Bash" "make db-start")
assert_exit "make db-start → allowed" "0" "$result"

result=$(run_hook "Bash" "git status")
assert_exit "git status → allowed" "0" "$result"

result=$(run_hook "Bash" "git add file.py")
assert_exit "git add → allowed" "0" "$result"

result=$(run_hook "Bash" "poetry lock")
assert_exit "poetry lock → allowed" "0" "$result"

result=$(run_hook "Bash" "pwd")
assert_exit "pwd → allowed" "0" "$result"

result=$(run_hook "Bash" "ls -la")
assert_exit "ls -la → allowed" "0" "$result"

result=$(run_hook "Bash" "grep -r pattern .")
assert_exit "grep → allowed" "0" "$result"

result=$(run_hook "Bash" "/Users/joeoakhart/lockpick-doc-to-logic/lockpick-workflow/scripts/validate.sh --ci")
assert_exit "validate.sh → allowed" "0" "$result"

result=$(run_hook "Bash" "docker ps")
assert_exit "docker ps → allowed" "0" "$result"

result=$(run_hook "Bash" "lsof -i :5433")
assert_exit "lsof → allowed" "0" "$result"

result=$(run_hook "Bash" "echo done > /tmp/test-output")
assert_exit "echo > /tmp/ → allowed" "0" "$result"

# ============================================================
# Group 6: State = failed + non-exempt commands (WARNING ONLY)
# ============================================================
echo ""
echo "=== Group 6: State = failed + non-exempt commands ==="
set_state failed

# In failed state, non-exempt Bash commands get a WARNING but are allowed (exit 0).
# Only new-work commands (sprint/epic discovery) are hard-blocked in failed state.
result=$(run_hook "Bash" "curl http://example.com")
assert_exit "curl → warning allowed (failed state warns but doesn't block non-new-work)" "0" "$result"

result=$(run_hook "Bash" "python3 script.py")
assert_exit "python3 → warning allowed (failed state warns but doesn't block non-new-work)" "0" "$result"

result=$(run_hook "Bash" "npm install")
assert_exit "npm install → warning allowed (failed state warns but doesn't block non-new-work)" "0" "$result"

# ============================================================
# Group 7: State = failed + compound commands
# ============================================================
echo ""
echo "=== Group 7: State = failed + compound commands ==="
set_state failed

result=$(run_hook "Bash" "echo done && tk ready")
assert_exit "echo && tk ready → allowed (tk ready is read-only)" "0" "$result"

result=$(run_hook "Bash" "tk create \"fix\" && make test")
assert_exit "tk create && make test → allowed (all exempt, no new-work)" "0" "$result"

result=$(run_hook "Bash" "git status && tk ready")
assert_exit "git status && tk ready → allowed (tk ready is read-only)" "0" "$result"

result=$(run_hook "Bash" "echo done && sprint --resume")
assert_exit "echo && sprint → blocked (new-work in compound)" "2" "$result"

result=$(run_hook "Bash" "git add . && git commit -m msg")
assert_exit "git add && git commit → allowed (all exempt)" "0" "$result"

result=$(run_hook "Bash" "tk show X || tk update X --status=in_progress")
assert_exit "tk show || tk update → allowed (all exempt)" "0" "$result"

# Compound with validate.sh still exits early
result=$(run_hook "Bash" "validate.sh --ci && tk ready")
assert_exit "validate.sh && tk ready → allowed (validate.sh shortcut)" "0" "$result"

# Pipe-only: tk ready and tk children are read-only queries, allowed
result=$(run_hook "Bash" "tk ready | grep something")
assert_exit "tk ready | grep → allowed (read-only query piped)" "0" "$result"

result=$(run_hook "Bash" "tk children epic-123 | grep something")
assert_exit "tk children | grep → allowed (read-only query piped)" "0" "$result"

# Pipe-only: exempt on left-hand side → allowed
result=$(run_hook "Bash" "tk list --type=task | grep open")
assert_exit "tk list --type=task | grep → allowed (exempt piped)" "0" "$result"

result=$(run_hook "Bash" "tk ready --parent=w20-abc1 | head -5")
assert_exit "tk ready --parent=X | head → allowed (parent exempts pipe)" "0" "$result"

# ============================================================
# Group 8: Edge cases
# ============================================================
echo ""
echo "=== Group 8: Edge cases ==="

# Empty command: in failed state, non-exempt Bash commands get WARNING (exit 0), not hard block
set_state failed
result=$(run_hook "Bash" "")
assert_exit "Empty command (failed state) → warning allowed (not a new-work command)" "0" "$result"

# Non-tool (Read, Glob, etc.) should be allowed
set_state failed
result=$(run_hook "Read" "/some/file.py")
assert_exit "Read tool → always allowed" "0" "$result"

set_state not_run
result=$(run_hook "Glob" "*.py")
assert_exit "Glob tool → always allowed" "0" "$result"

# grep -r sprint . should NOT be blocked (sprint is in args, not first token)
set_state failed
result=$(run_hook "Bash" "grep -r sprint .")
assert_exit "grep -r sprint . → allowed (sprint as arg, not command)" "0" "$result"

# tk list without new-work pattern should be allowed (tk is exempt)
set_state failed
result=$(run_hook "Bash" "tk list --status=in_progress")
assert_exit "tk list --status=in_progress → allowed" "0" "$result"

# tk children without args should be allowed (no match for children + space + non-empty)
set_state failed
result=$(run_hook "Bash" "tk children")
assert_exit "tk children (bare, no args) → allowed" "0" "$result"

# ============================================================
# Group 9: Config-driven validate command in error messages
# ============================================================
# These tests verify that validation-gate.sh uses CLAUDE_PLUGIN_ROOT to read
# workflow-config.conf and reference the configured validate command in its
# BLOCKED error messages (rather than hardcoding "validate.sh --ci").
#
# test_validation_gate_config_driven_blocked_message_uses_config_validate_cmd
#   MUST FAIL in red phase: validation-gate.sh currently outputs a hardcoded
#   message that does not reference workflow-config.conf at all.
# test_validation_gate_backward_compat_no_config
#   MUST PASS in red phase: the gate still blocks new-work commands when no
#   config is present (backward compatibility is already implemented).
echo ""
echo "=== Group 9: Config-driven validate command in error messages ==="

# Helper: run hook and capture stderr separately.
# Echos a two-line result: first line = exit code, remaining = stderr content.
run_hook_with_stderr() {
    local tool_name="$1"
    local tool_input="$2"
    local json
    local exit_code=0
    local stderr_file
    stderr_file=$(mktemp)

    if [[ "$tool_name" == "Bash" ]]; then
        json=$(jq -n --arg tn "$tool_name" --arg cmd "$tool_input" \
            '{tool_name: $tn, tool_input: {command: $cmd}}')
    elif [[ "$tool_name" == "Edit" ]] || [[ "$tool_name" == "Write" ]]; then
        json=$(jq -n --arg tn "$tool_name" --arg fp "$tool_input" \
            '{tool_name: $tn, tool_input: {file_path: $fp}}')
    else
        json=$(jq -n --arg tn "$tool_name" '{tool_name: $tn, tool_input: {}}')
    fi

    echo "$json" | bash "$HOOK" 2>"$stderr_file" || exit_code=$?
    echo "$exit_code"
    cat "$stderr_file"
    rm -f "$stderr_file"
}

# test_validation_gate_config_driven_blocked_message_uses_config_validate_cmd
# Set up CLAUDE_PLUGIN_ROOT with workflow-config.conf: commands.validate = './custom-validate.sh'
# Set validation state to not_run
# Run hook with 'tk ready' (new-work command)
# Capture stderr output
# Assert stderr contains 'custom-validate'
# --- THIS TEST MUST FAIL IN RED PHASE ---
# validation-gate.sh currently outputs a hardcoded message without reading config.
_CONFIG_PLUGIN_ROOT=$(mktemp -d)
<<<<<<< HEAD
printf 'version: "1.0.0"\ncommands:\n  validate: "./custom-validate.sh"\n' > "$_CONFIG_PLUGIN_ROOT/workflow-config.conf"
=======
ln -s "$REPO_ROOT/lockpick-workflow/scripts" "$_CONFIG_PLUGIN_ROOT/scripts"
printf 'version: "1.0.0"\ncommands:\n  validate: "./custom-validate.sh"\n' > "$_CONFIG_PLUGIN_ROOT/workflow-config.yaml"
>>>>>>> origin/main
set_state not_run
_HOOK_OUTPUT=$(CLAUDE_PLUGIN_ROOT="$_CONFIG_PLUGIN_ROOT" run_hook_with_stderr "Bash" "sprint")
_HOOK_STDERR=$(echo "$_HOOK_OUTPUT" | tail -n +2)
assert_contains "test_validation_gate_config_driven_blocked_message_uses_config_validate_cmd" \
    "custom-validate" "$_HOOK_STDERR"
rm -rf "$_CONFIG_PLUGIN_ROOT"

# test_validation_gate_backward_compat_no_config
# No CLAUDE_PLUGIN_ROOT set, no config file.
# Run hook with new-work command while not_run state.
# Assert it still blocks (exit 2) — backward compat preserved.
set_state not_run
_NO_CONFIG_OUTPUT=$(run_hook_with_stderr "Bash" "sprint")
_NO_CONFIG_EXIT=$(echo "$_NO_CONFIG_OUTPUT" | head -n 1)
assert_eq "test_validation_gate_backward_compat_no_config" "2" "$_NO_CONFIG_EXIT"

# ============================================================
# Summary
# ============================================================
echo ""
echo "========================================"
printf "Results: %d/%d passed" "$PASSED" "$TOTAL"
if [[ "$FAILED" -gt 0 ]]; then
    printf ", %d FAILED" "$FAILED"
fi
echo ""
echo "========================================"

# Combine legacy counters with assert.sh counters for final exit decision
_TOTAL_FAILED=$(( FAILED + FAIL ))
if [[ "$_TOTAL_FAILED" -gt 0 ]]; then
    exit 1
fi
exit 0
