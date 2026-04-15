#!/usr/bin/env bash
# tests/hooks/test-commit-tracker.sh
# Tests for .claude/hooks/commit-failure-tracker.sh
#
# commit-failure-tracker.sh is a PreToolUse hook (Bash matcher) that
# warns (but never blocks) if validation failures exist at git commit time
# without corresponding open ticket issues. Always exits 0.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$DSO_PLUGIN_DIR/hooks/commit-failure-tracker.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"
source "$DSO_PLUGIN_DIR/hooks/lib/deps.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

run_hook() {
    local input="$1"
    local exit_code=0
    echo "$input" | bash "$HOOK" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# test_commit_tracker_exits_zero_on_noop_bash_input
# Bash tool with non-commit command → exit 0 immediately
INPUT='{"tool_name":"Bash","tool_input":{"command":"git status"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_commit_tracker_exits_zero_on_noop_bash_input" "0" "$EXIT_CODE"

# test_commit_tracker_exits_zero_on_non_bash_tool
# Non-Bash tool → exit 0
INPUT='{"tool_name":"Edit","tool_input":{"file_path":"/tmp/test.py"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_commit_tracker_exits_zero_on_non_bash_tool" "0" "$EXIT_CODE"

# test_commit_tracker_exits_zero_on_read_tool
# Read tool → exit 0
INPUT='{"tool_name":"Read","tool_input":{"file_path":"/tmp/test.py"}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_commit_tracker_exits_zero_on_read_tool" "0" "$EXIT_CODE"

# test_commit_tracker_exits_zero_on_empty_input
# Empty stdin → exit 0
EXIT_CODE=$(run_hook "")
assert_eq "test_commit_tracker_exits_zero_on_empty_input" "0" "$EXIT_CODE"

# test_commit_tracker_exits_zero_on_malformed_json
# Malformed JSON → exit 0 (fail-open)
EXIT_CODE=$(run_hook "not json")
assert_eq "test_commit_tracker_exits_zero_on_malformed_json" "0" "$EXIT_CODE"

# test_commit_tracker_exits_zero_on_git_commit_no_validation_state
# git commit command but no validation state file → exit 0 (no state to check)
STATE_FILE="$(get_artifacts_dir)/status"
# Save and remove state file if it exists
SAVED_CONTENT=""
if [[ -f "$STATE_FILE" ]]; then
    SAVED_CONTENT=$(cat "$STATE_FILE")
    rm -f "$STATE_FILE"
fi

INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test commit\""}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_commit_tracker_exits_zero_on_git_commit_no_validation_state" "0" "$EXIT_CODE"

# Restore state file if we had one
if [[ -n "$SAVED_CONTENT" ]]; then
    mkdir -p "$(dirname "$STATE_FILE")"
    echo "$SAVED_CONTENT" > "$STATE_FILE"
fi

# test_commit_tracker_never_blocks_even_on_failed_validation
# The hook NEVER blocks (exit 0) even with failed validation state
# Set up a fake "failed" validation state
ARTIFACTS_DIR="$(get_artifacts_dir)"
mkdir -p "$ARTIFACTS_DIR"
ORIG_STATE=""
if [[ -f "$ARTIFACTS_DIR/status" ]]; then
    ORIG_STATE=$(cat "$ARTIFACTS_DIR/status")
fi
printf "failed\nfailed_checks=format,tests\n" > "$ARTIFACTS_DIR/status"

INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test\""}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_commit_tracker_never_blocks_even_on_failed_validation" "0" "$EXIT_CODE"

# Restore original state
if [[ -n "$ORIG_STATE" ]]; then
    echo "$ORIG_STATE" > "$ARTIFACTS_DIR/status"
else
    rm -f "$ARTIFACTS_DIR/status"
fi

# test_commit_tracker_exits_zero_on_wip_commit
# WIP commits are exempt regardless
INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"WIP: work in progress\""}}'
EXIT_CODE=$(run_hook "$INPUT")
assert_eq "test_commit_tracker_exits_zero_on_wip_commit" "0" "$EXIT_CODE"

# ============================================================
# Group: Config-driven issue tracker commands
# ============================================================
# These tests verify that commit-failure-tracker.sh uses CLAUDE_PLUGIN_ROOT to
# read dso-config.conf and uses the configured search command instead of
# hardcoding 'bd search'.
#
# test_commit_tracker_config_driven_issue_tracker_search_cmd
#   MUST FAIL in red phase: commit-failure-tracker.sh currently hardcodes 'bd search'
#   and does not read issue_tracker.search_cmd from dso-config.conf.
# test_commit_tracker_backward_compat_defaults_to_bd
#   MUST PASS in red phase: without CLAUDE_PLUGIN_ROOT, hook still uses bd internally
#   and exits 0 (never blocks).

run_hook_stderr() {
    local input="$1"
    local plugin_root="${2:-}"
    local exit_code=0
    local stderr_file
    stderr_file=$(mktemp)
    _CLEANUP_DIRS+=("$stderr_file")
    if [[ -n "$plugin_root" ]]; then
        CLAUDE_PLUGIN_ROOT="$plugin_root" echo "$input" | bash "$HOOK" 2>"$stderr_file" || exit_code=$?
    else
        echo "$input" | bash "$HOOK" 2>"$stderr_file" || exit_code=$?
    fi
    cat "$stderr_file"
    rm -f "$stderr_file"
    return "$exit_code"
}

# test_commit_tracker_config_driven_issue_tracker_search_cmd
# CLAUDE_PLUGIN_ROOT with dso-config.conf:
#   issue_tracker:
#     search_cmd: 'gh issue list --search'
# Set validation state to 'failed' with failed_checks=lint
# Run git commit command through hook
# Assert stderr does NOT reference 'bd search' (uses configured command instead)
# MUST FAIL — hook currently hardcodes bd search
_CT_PLUGIN_ROOT=$(mktemp -d)
_CLEANUP_DIRS+=("$_CT_PLUGIN_ROOT")
ln -s "$DSO_PLUGIN_DIR/scripts" "$_CT_PLUGIN_ROOT/scripts"
mkdir -p "$_CT_PLUGIN_ROOT/.claude"
cat > "$_CT_PLUGIN_ROOT/.claude/dso-config.conf" << 'CONF_EOF'
issue_tracker.search_cmd=gh issue list --search
CONF_EOF

ARTIFACTS_DIR_CT="$(get_artifacts_dir)"
mkdir -p "$ARTIFACTS_DIR_CT"
ORIG_STATE_CT=""
if [[ -f "$ARTIFACTS_DIR_CT/status" ]]; then
    ORIG_STATE_CT=$(cat "$ARTIFACTS_DIR_CT/status")
fi
printf "failed\nfailed_checks=lint\n" > "$ARTIFACTS_DIR_CT/status"

INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test commit\""}}'
# When config-driven: hook would use 'gh issue list --search' to look up issues.
# In red phase: hook ignores config and uses 'bd search' — it does NOT use 'gh issue list'.
# We assert stderr contains the configured search command prefix 'gh issue list'.
# This MUST FAIL in red phase because the hook ignores CLAUDE_PLUGIN_ROOT entirely.
_CT_STDERR=$(CLAUDE_PLUGIN_ROOT="$_CT_PLUGIN_ROOT" run_hook_stderr "$INPUT" "$_CT_PLUGIN_ROOT" 2>/dev/null || true)
assert_contains "test_commit_tracker_config_driven_issue_tracker_search_cmd" \
    "issue_tracker.search_cmd: gh issue list" "$_CT_STDERR"

# Restore state
if [[ -n "$ORIG_STATE_CT" ]]; then
    echo "$ORIG_STATE_CT" > "$ARTIFACTS_DIR_CT/status"
else
    rm -f "$ARTIFACTS_DIR_CT/status"
fi
rm -rf "$_CT_PLUGIN_ROOT"

# test_commit_tracker_backward_compat_defaults_to_bd
# No CLAUDE_PLUGIN_ROOT set
# Existing behavior unchanged — hook uses 'bd search' and 'bd q' internally
# Assert exit 0 (hook never blocks)
INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test backward compat\""}}'
_CT_BACK_EXIT=0
echo "$INPUT" | bash "$HOOK" > /dev/null 2>/dev/null || _CT_BACK_EXIT=$?
assert_eq "test_commit_tracker_backward_compat_defaults_to_bd" "0" "$_CT_BACK_EXIT"

# test_commit_tracker_uses_config_driven_cmd
# Export SEARCH_CMD and CREATE_CMD as environment variables pointing to a mock.
# Assert hook uses them (records calls to the mock) when a failed validation state exists.
# MUST FAIL if hook ignores env vars and falls back to hardcoded bd defaults.
_CT2_FAKE_BIN=$(mktemp -d)
_CLEANUP_DIRS+=("$_CT2_FAKE_BIN")
_CT2_SEARCH_LOG="$_CT2_FAKE_BIN/search.log"
_CT2_CREATE_LOG="$_CT2_FAKE_BIN/create.log"

cat > "$_CT2_FAKE_BIN/mock-search" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "$@" >> "$SEARCH_LOG"
echo ""
MOCK_EOF
chmod +x "$_CT2_FAKE_BIN/mock-search"

cat > "$_CT2_FAKE_BIN/mock-create" << 'MOCK_EOF'
#!/usr/bin/env bash
echo "$@" >> "$CREATE_LOG"
echo "Created issue: tk-002"
MOCK_EOF
chmod +x "$_CT2_FAKE_BIN/mock-create"

# Set up failed validation state
_CT2_ARTIFACTS_DIR="$(get_artifacts_dir)"
mkdir -p "$_CT2_ARTIFACTS_DIR"
_CT2_ORIG_STATE=""
if [[ -f "$_CT2_ARTIFACTS_DIR/status" ]]; then
    _CT2_ORIG_STATE=$(cat "$_CT2_ARTIFACTS_DIR/status")
fi
printf "failed\nfailed_checks=lint\n" > "$_CT2_ARTIFACTS_DIR/status"

INPUT='{"tool_name":"Bash","tool_input":{"command":"git commit -m \"test config-driven\""}}'
# REVIEW-DEFENSE: SEARCH_LOG, CREATE_LOG, SEARCH_CMD, CREATE_CMD are all prefixed to
# `bash "$HOOK"` (right side of pipe). The multi-line continuation means they apply
# to the final `bash "$HOOK"` command, not to `echo`. The hook inherits all four vars.
echo "$INPUT" | SEARCH_LOG="$_CT2_SEARCH_LOG" CREATE_LOG="$_CT2_CREATE_LOG" \
    SEARCH_CMD="$_CT2_FAKE_BIN/mock-search" \
    CREATE_CMD="$_CT2_FAKE_BIN/mock-create" \
    bash "$HOOK" >/dev/null 2>/dev/null || true

# Check that mock-search was called (hook must use SEARCH_CMD env var)
_CT2_SEARCH_CALLED="no"
if [[ -f "$_CT2_SEARCH_LOG" ]]; then
    _CT2_SEARCH_CALLED="yes"
fi
assert_eq "test_commit_tracker_uses_config_driven_cmd" "yes" "$_CT2_SEARCH_CALLED"

# Restore state
if [[ -n "$_CT2_ORIG_STATE" ]]; then
    echo "$_CT2_ORIG_STATE" > "$_CT2_ARTIFACTS_DIR/status"
else
    rm -f "$_CT2_ARTIFACTS_DIR/status"
fi
rm -rf "$_CT2_FAKE_BIN"

# ============================================================
# Group: _CREATE_CMD dead-code removal (TDD RED phase)
# ============================================================
# These tests assert that dead code reading issue_tracker.create_cmd config
# and setting _CREATE_CMD/_CREATE_CMD_FROM_ENV has been removed from
# hook_commit_failure_tracker() in pre-bash-functions.sh.
# Both tests MUST FAIL in the RED phase (the dead code is still present).
# After the implementation step removes the dead code, both tests will pass.

PRE_BASH_FUNCTIONS="$DSO_PLUGIN_DIR/hooks/lib/pre-bash-functions.sh"

# test_no_issue_tracker_create_cmd_read
# Asserts that pre-bash-functions.sh does NOT read issue_tracker.create_cmd from config.
# MUST FAIL in RED phase: the config read is still present (lines 173-180).
_CREATE_CMD_CONFIG_REF=$(grep 'issue_tracker\.create_cmd' "$PRE_BASH_FUNCTIONS" || true)
assert_eq "test_no_issue_tracker_create_cmd_read" "" "$_CREATE_CMD_CONFIG_REF"

# test_no_create_cmd_variable
# Asserts that pre-bash-functions.sh does NOT reference _CREATE_CMD variable.
# MUST FAIL in RED phase: _CREATE_CMD and _CREATE_CMD_FROM_ENV are still defined (lines 149-151, 173-180).
_CREATE_CMD_VAR_REF=$(grep '_CREATE_CMD' "$PRE_BASH_FUNCTIONS" || true)
assert_eq "test_no_create_cmd_variable" "" "$_CREATE_CMD_VAR_REF"

print_summary
