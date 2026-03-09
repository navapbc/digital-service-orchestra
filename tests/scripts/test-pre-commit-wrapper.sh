#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-pre-commit-wrapper.sh
# Tests for lockpick-workflow/scripts/pre-commit-wrapper.sh (generic timeout wrapper).
#
# Tests:
#   test_syntax_ok               — bash -n passes
#   test_accepts_three_args      — runs command_string via bash -c
#   test_missing_args_exits_nonzero — exits non-zero when args missing
#   test_no_project_specific_refs — no PY_RUN_APPROACH, cd app, make targets
#   test_reads_artifact_prefix   — uses read-config.sh for session.artifact_prefix
#   test_reads_create_cmd        — uses issue_tracker.create_cmd from config
#   test_exit_code_passthrough   — passes through command exit code
#   test_timeout_exit_codes      — handles 124, 143, 137 exit codes
#   test_timeout_logging         — logs timeout events to log file
#   test_timeout_ticket_creation — creates ticket via configured create_cmd
#   test_no_ticket_without_config — skips ticket creation when create_cmd absent
#   test_fallback_artifact_prefix — falls back to repo-name derivation when config absent
#
# Usage:
#   bash lockpick-workflow/tests/scripts/test-pre-commit-wrapper.sh
#
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
ASSERT_LIB="$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"
WRAPPER="$REPO_ROOT/lockpick-workflow/scripts/pre-commit-wrapper.sh"

# Source shared assert helpers
# shellcheck source=../lib/assert.sh
source "$ASSERT_LIB"

echo "=== test-pre-commit-wrapper.sh (generic plugin wrapper) ==="
echo ""

# ---------------------------------------------------------------------------
# Test 1: bash -n syntax check
# ---------------------------------------------------------------------------
echo "Test 1: syntax check"
syntax_exit=0
bash -n "$WRAPPER" 2>&1 || syntax_exit=$?
assert_eq "test_syntax_ok" "0" "$syntax_exit"

# ---------------------------------------------------------------------------
# Test 2: accepts three args and runs command_string
# ---------------------------------------------------------------------------
echo "Test 2: accepts <hook_name> <timeout_secs> <command_string>"
output=""
rc=0
output=$("$WRAPPER" test-hook 30 "echo hello-from-wrapper" 2>/dev/null) || rc=$?
assert_eq "test_accepts_three_args_exit" "0" "$rc"
assert_contains "test_accepts_three_args_output" "hello-from-wrapper" "$output"

# ---------------------------------------------------------------------------
# Test 3: missing arguments exits non-zero
# ---------------------------------------------------------------------------
echo "Test 3: missing args exits non-zero"
rc=0
"$WRAPPER" 2>/dev/null || rc=$?
assert_ne "test_missing_args_exits_nonzero_no_args" "0" "$rc"

rc=0
"$WRAPPER" "hook-only" 2>/dev/null || rc=$?
assert_ne "test_missing_args_exits_nonzero_one_arg" "0" "$rc"

rc=0
"$WRAPPER" "hook-only" "30" 2>/dev/null || rc=$?
assert_ne "test_missing_args_exits_nonzero_two_args" "0" "$rc"

# ---------------------------------------------------------------------------
# Test 4: no project-specific references
# ---------------------------------------------------------------------------
echo "Test 4: no project-specific references"
py_run_count=0
py_run_count=$(grep -c 'PY_RUN_APPROACH' "$WRAPPER" 2>/dev/null || true)
assert_eq "test_no_PY_RUN_APPROACH" "0" "$py_run_count"

# Exclude comment lines (lines starting with optional whitespace + #) from checks
cd_app_count=0
cd_app_count=$(grep -v '^\s*#' "$WRAPPER" | grep -c 'cd app' 2>/dev/null || true)
assert_eq "test_no_cd_app" "0" "$cd_app_count"

make_target_count=0
make_target_count=$(grep -v '^\s*#' "$WRAPPER" | grep -cE 'make (format|lint|test)' 2>/dev/null || true)
assert_eq "test_no_make_targets" "0" "$make_target_count"

# ---------------------------------------------------------------------------
# Test 5: reads artifact prefix from config
# ---------------------------------------------------------------------------
echo "Test 5: reads session.artifact_prefix via read-config.sh"
config_ref=0
config_ref=$(grep -c 'session.artifact_prefix' "$WRAPPER" 2>/dev/null || true)
assert_ne "test_reads_artifact_prefix" "0" "$config_ref"

read_config_ref=0
read_config_ref=$(grep -c 'read-config.sh' "$WRAPPER" 2>/dev/null || true)
assert_ne "test_uses_read_config" "0" "$read_config_ref"

# ---------------------------------------------------------------------------
# Test 6: reads issue_tracker.create_cmd from config
# ---------------------------------------------------------------------------
echo "Test 6: reads issue_tracker.create_cmd"
create_cmd_ref=0
create_cmd_ref=$(grep -c 'issue_tracker.create_cmd' "$WRAPPER" 2>/dev/null || true)
assert_ne "test_reads_create_cmd" "0" "$create_cmd_ref"

# ---------------------------------------------------------------------------
# Test 7: exit code passthrough
# ---------------------------------------------------------------------------
echo "Test 7: exit code passthrough"
rc=0
"$WRAPPER" test-hook 30 "exit 0" 2>/dev/null || rc=$?
assert_eq "test_exit_code_passthrough_0" "0" "$rc"

rc=0
"$WRAPPER" test-hook 30 "exit 1" 2>/dev/null || rc=$?
assert_eq "test_exit_code_passthrough_1" "1" "$rc"

rc=0
"$WRAPPER" test-hook 30 "exit 42" 2>/dev/null || rc=$?
assert_eq "test_exit_code_passthrough_42" "42" "$rc"

# ---------------------------------------------------------------------------
# Test 8: timeout exit codes (124, 143, 137) are recognized
# ---------------------------------------------------------------------------
echo "Test 8: timeout exit codes"
grep_rc=0
grep -qE '124|143|137' "$WRAPPER" || grep_rc=$?
assert_eq "test_timeout_exit_codes_referenced" "0" "$grep_rc"

# Test that 124 is passed through (timeout) — use isolated config to avoid real ticket creation
TMPDIR_T8=$(mktemp -d)
cat > "$TMPDIR_T8/workflow-config.yaml" << 'EOF'
version: "1.0.0"
session:
  artifact_prefix: test-t8-artifacts
EOF
rc=0
CLAUDE_PLUGIN_ROOT="$TMPDIR_T8" "$WRAPPER" test-hook 30 "exit 124" 2>/dev/null || rc=$?
assert_eq "test_exit_code_124_passthrough" "124" "$rc"
WORKTREE_NAME_T8=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "default")")
rm -rf "$TMPDIR_T8" "/tmp/test-t8-artifacts-${WORKTREE_NAME_T8}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test 9: timeout logging — slow command logs to timeout log file
# ---------------------------------------------------------------------------
echo "Test 9: timeout logging"
# Use TIMEOUT_SECS=-1 so any duration triggers the slow path
TMPDIR_TEST=$(mktemp -d)
# Create a minimal config that sets artifact_prefix
cat > "$TMPDIR_TEST/workflow-config.yaml" << 'EOF'
version: "1.0.0"
session:
  artifact_prefix: test-wrapper-artifacts
EOF
# The wrapper uses git rev-parse --show-toplevel for worktree name (not the config dir)
WORKTREE_NAME_TEST=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "default")")
ARTIFACTS_DIR_TEST="/tmp/test-wrapper-artifacts-${WORKTREE_NAME_TEST}"
TIMEOUT_LOG_TEST="$ARTIFACTS_DIR_TEST/precommit-timeouts.log"
rm -f "$TIMEOUT_LOG_TEST" 2>/dev/null || true

# Run with -1 timeout so DURATION(0) > TIMEOUT_SECS(-1) is always true
rc=0
CLAUDE_PLUGIN_ROOT="$TMPDIR_TEST" "$WRAPPER" slow-hook -1 "true" 2>/dev/null || rc=$?

# Check that the log file was created with content about slow-hook
if [ -f "$TIMEOUT_LOG_TEST" ]; then
    log_has_hook=0
    log_has_hook=$(grep -c 'slow-hook' "$TIMEOUT_LOG_TEST" 2>/dev/null || true)
    assert_ne "test_timeout_logging_has_hook_name" "0" "$log_has_hook"
else
    assert_eq "test_timeout_log_created" "exists" "missing"
fi

rm -rf "$TMPDIR_TEST" "$ARTIFACTS_DIR_TEST" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test 10: timeout ticket creation via configured create_cmd
# ---------------------------------------------------------------------------
echo "Test 10: timeout ticket creation"
TMPDIR_TEST=$(mktemp -d)
MOCK_CREATE_DIR=$(mktemp -d)

# Create a mock create command that logs calls
cat > "$MOCK_CREATE_DIR/mock-create" << MOCK_SCRIPT
#!/usr/bin/env bash
echo "\$*" >> "$MOCK_CREATE_DIR/create_calls"
echo "mock-ticket-001"
exit 0
MOCK_SCRIPT
chmod +x "$MOCK_CREATE_DIR/mock-create"

cat > "$TMPDIR_TEST/workflow-config.yaml" << EOF
version: "1.0.0"
session:
  artifact_prefix: test-wrapper-ticket
issue_tracker:
  create_cmd: "$MOCK_CREATE_DIR/mock-create"
EOF

rc=0
CLAUDE_PLUGIN_ROOT="$TMPDIR_TEST" "$WRAPPER" ticket-hook -1 "true" 2>/dev/null || rc=$?

create_called=0
if [ -f "$MOCK_CREATE_DIR/create_calls" ]; then
    create_called=1
fi
assert_eq "test_timeout_ticket_creation" "1" "$create_called"

WORKTREE_NAME_TEST=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "default")")
rm -rf "$TMPDIR_TEST" "$MOCK_CREATE_DIR" "/tmp/test-wrapper-ticket-${WORKTREE_NAME_TEST}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test 11: no ticket creation when create_cmd is absent
# ---------------------------------------------------------------------------
echo "Test 11: no ticket creation without config"
TMPDIR_TEST=$(mktemp -d)

cat > "$TMPDIR_TEST/workflow-config.yaml" << 'EOF'
version: "1.0.0"
session:
  artifact_prefix: test-wrapper-noticket
EOF

rc=0
output=""
output=$(CLAUDE_PLUGIN_ROOT="$TMPDIR_TEST" "$WRAPPER" noticket-hook -1 "true" 2>&1) || rc=$?

# Should NOT error out -- exit code from the command itself should be 0
assert_eq "test_no_ticket_without_config_exit" "0" "$rc"

WORKTREE_NAME_TEST=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "default")")
rm -rf "$TMPDIR_TEST" "/tmp/test-wrapper-noticket-${WORKTREE_NAME_TEST}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test 12: fallback artifact prefix when config absent
# ---------------------------------------------------------------------------
echo "Test 12: fallback artifact prefix"
# The script should derive prefix from repo name when session.artifact_prefix is absent
grep_rc=0
grep -q 'basename' "$WRAPPER" || grep_rc=$?
assert_eq "test_fallback_artifact_prefix_uses_basename" "0" "$grep_rc"

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------
print_summary
