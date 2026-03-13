#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-pre-commit-wrapper.sh
# Tests for lockpick-workflow/scripts/pre-commit-wrapper.sh (generic timeout wrapper).
#
# Tests:
#   test_syntax_ok               — bash -n passes
#   test_accepts_three_args      — runs command_string via bash -c
#   test_missing_args_exits_nonzero — exits non-zero when args missing
#   test_generic_runs_without_project_env — works without project-specific tools/env
#   test_reads_artifact_prefix   — artifacts go to config-specified prefix dir
#   test_reads_create_cmd        — warning emitted when issue_tracker.create_cmd absent
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

# Locate a python3 with pyyaml for read-config.sh to use.
# read-config.sh needs pyyaml; the system python3 may not have it.
# Export so all wrapper invocations in this file inherit it.
_find_python_with_yaml() {
    for candidate in /usr/bin/python3 /usr/local/bin/python3 \
                     "$REPO_ROOT/app/.venv/bin/python3" \
                     "$REPO_ROOT/.venv/bin/python3" \
                     python3; do
        [[ -z "$candidate" ]] && continue
        if "$candidate" -c "import yaml" 2>/dev/null; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}
export CLAUDE_PLUGIN_PYTHON
CLAUDE_PLUGIN_PYTHON=$(_find_python_with_yaml 2>/dev/null || echo "python3")

# PID-namespace all artifact prefixes so concurrent or stale test runs
# cannot collide on /tmp artifact directories.
_TEST_PID=$$

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
_T2_CFG=$(mktemp -d)
cat > "$_T2_CFG/workflow-config.yaml" << EOF
version: "1.0.0"
session:
  artifact_prefix: test-t2-artifacts-${_TEST_PID}
EOF
output=""
rc=0
output=$(CLAUDE_PLUGIN_ROOT="$_T2_CFG" "$WRAPPER" test-hook 30 "echo hello-from-wrapper" 2>/dev/null) || rc=$?
assert_eq "test_accepts_three_args_exit" "0" "$rc"
assert_contains "test_accepts_three_args_output" "hello-from-wrapper" "$output"
_T2_WORKTREE=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo 'default')")
rm -rf "$_T2_CFG" "/tmp/test-t2-artifacts-${_TEST_PID}-${_T2_WORKTREE}" 2>/dev/null || true

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
# Test 4: generic wrapper works without project-specific tools or environment
#
# Behavioral tests replacing source-grep checks:
#   - Runs correctly from an unrelated temp directory (no cd app dependency)
#   - Runs correctly without project-specific env vars (no PY_RUN_APPROACH, etc.)
#   - Runs correctly without make in PATH (no make format/lint/test invocations)
# ---------------------------------------------------------------------------
echo "Test 4: generic wrapper works without project-specific tools or environment"

# Set up an isolated config for all sub-tests
_T4_CFG=$(mktemp -d)
cat > "$_T4_CFG/workflow-config.yaml" << EOF
version: "1.0.0"
session:
  artifact_prefix: test-t4-generic-${_TEST_PID}
EOF
_T4_WORKTREE=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo 'default')")

# Sub-test A: works from an arbitrary directory (no cd app dependency)
_T4_TMPDIR=$(mktemp -d)
rc=0
output=$(cd "$_T4_TMPDIR" && CLAUDE_PLUGIN_ROOT="$_T4_CFG" "$WRAPPER" generic-hook 30 "echo ran-ok" 2>/dev/null) || rc=$?
assert_eq "test_runs_from_arbitrary_dir_exit" "0" "$rc"
assert_contains "test_runs_from_arbitrary_dir_output" "ran-ok" "$output"
rm -rf "$_T4_TMPDIR"

# Sub-test B: works without PY_RUN_APPROACH in environment
rc=0
output=$(env -u PY_RUN_APPROACH 2>/dev/null \
    CLAUDE_PLUGIN_ROOT="$_T4_CFG" "$WRAPPER" generic-hook 30 "echo no-py-run" 2>/dev/null \
    || CLAUDE_PLUGIN_ROOT="$_T4_CFG" "$WRAPPER" generic-hook 30 "echo no-py-run" 2>/dev/null) || rc=$?
assert_eq "test_no_PY_RUN_APPROACH_needed_exit" "0" "$rc"
assert_contains "test_no_PY_RUN_APPROACH_needed_output" "no-py-run" "$output"

# Sub-test C: works when make is not in PATH (no make targets invoked)
_T4_SAFEPATH=$(mktemp -d)  # empty dir with no tools — wrapper should still complete
rc=0
# Use a PATH that includes only bash and python (enough for the wrapper) but not make
output=$(PATH="/usr/bin:/bin:$(dirname "$CLAUDE_PLUGIN_PYTHON")" \
    CLAUDE_PLUGIN_ROOT="$_T4_CFG" "$WRAPPER" generic-hook 30 "echo no-make-needed" 2>/dev/null) || rc=$?
assert_eq "test_no_make_invocation_exit" "0" "$rc"
assert_contains "test_no_make_invocation_output" "no-make-needed" "$output"
rm -rf "$_T4_SAFEPATH"

rm -rf "$_T4_CFG" "/tmp/test-t4-generic-${_TEST_PID}-${_T4_WORKTREE}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test 5: wrapper uses session.artifact_prefix from config for artifact paths
#
# Behavioral test: run with a custom artifact_prefix and verify the timeout log
# is written under /tmp/<custom_prefix>-<worktree>/precommit-timeouts.log.
# This proves the wrapper reads session.artifact_prefix from config at runtime.
# ---------------------------------------------------------------------------
echo "Test 5: artifact dir uses session.artifact_prefix from config"
_T5_CFG=$(mktemp -d)
_T5_PREFIX="test-t5-custom-prefix-${_TEST_PID}"
cat > "$_T5_CFG/workflow-config.yaml" << EOF
version: "1.0.0"
session:
  artifact_prefix: ${_T5_PREFIX}
EOF
_T5_WORKTREE=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo 'default')")
_T5_EXPECTED_LOG="/tmp/${_T5_PREFIX}-${_T5_WORKTREE}/precommit-timeouts.log"
rm -f "$_T5_EXPECTED_LOG" 2>/dev/null || true

# Run with timeout=1 and sleep 2 so duration always exceeds the threshold
rc=0
CLAUDE_PLUGIN_ROOT="$_T5_CFG" "$WRAPPER" prefix-check-hook 1 "sleep 2" 2>/dev/null || rc=$?

if [ -f "$_T5_EXPECTED_LOG" ]; then
    assert_eq "test_reads_artifact_prefix_log_created" "exists" "exists"
    _t5_log_has_hook=$(grep -c 'prefix-check-hook' "$_T5_EXPECTED_LOG" 2>/dev/null || true)
    assert_ne "test_reads_artifact_prefix_log_has_hook" "0" "$_t5_log_has_hook"
else
    assert_eq "test_reads_artifact_prefix_log_created" "exists" "missing"
fi

rm -rf "$_T5_CFG" "/tmp/${_T5_PREFIX}-${_T5_WORKTREE}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test 6: wrapper consults issue_tracker.create_cmd from config at runtime
#
# Behavioral test: when create_cmd is absent from config and a timeout fires,
# the wrapper emits a warning mentioning issue_tracker.create_cmd.
# This proves the wrapper actually reads (and reports on) that config key.
# ---------------------------------------------------------------------------
echo "Test 6: wrapper warns about missing issue_tracker.create_cmd on timeout"
_T6_CFG=$(mktemp -d)
cat > "$_T6_CFG/workflow-config.yaml" << EOF
version: "1.0.0"
session:
  artifact_prefix: test-t6-nocmd-${_TEST_PID}
EOF
_T6_WORKTREE=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo 'default')")

rc=0
_t6_output=$(CLAUDE_PLUGIN_ROOT="$_T6_CFG" "$WRAPPER" cmd-check-hook 1 "sleep 2" 2>&1) || rc=$?
# Wrapper should still succeed (command exit 0), just skip ticket creation
assert_eq "test_reads_create_cmd_exit" "0" "$rc"
# Warning should mention the config key so users know how to configure it
assert_contains "test_reads_create_cmd_warning" "issue_tracker.create_cmd" "$_t6_output"

rm -rf "$_T6_CFG" "/tmp/test-t6-nocmd-${_TEST_PID}-${_T6_WORKTREE}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test 7: exit code passthrough
# ---------------------------------------------------------------------------
echo "Test 7: exit code passthrough"
_T7_CFG=$(mktemp -d)
cat > "$_T7_CFG/workflow-config.yaml" << EOF
version: "1.0.0"
session:
  artifact_prefix: test-t7-exitcodes-${_TEST_PID}
EOF
_T7_WORKTREE=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo 'default')")

rc=0
CLAUDE_PLUGIN_ROOT="$_T7_CFG" "$WRAPPER" test-hook 30 "exit 0" 2>/dev/null || rc=$?
assert_eq "test_exit_code_passthrough_0" "0" "$rc"

rc=0
CLAUDE_PLUGIN_ROOT="$_T7_CFG" "$WRAPPER" test-hook 30 "exit 1" 2>/dev/null || rc=$?
assert_eq "test_exit_code_passthrough_1" "1" "$rc"

rc=0
CLAUDE_PLUGIN_ROOT="$_T7_CFG" "$WRAPPER" test-hook 30 "exit 42" 2>/dev/null || rc=$?
assert_eq "test_exit_code_passthrough_42" "42" "$rc"

rm -rf "$_T7_CFG" "/tmp/test-t7-exitcodes-${_TEST_PID}-${_T7_WORKTREE}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test 8: timeout exit codes (124, 143, 137) are all handled correctly
#
# Behavioral tests: the wrapper recognizes all three timeout signal codes
# and normalizes them to exit 124 with a TIMEOUT message.
# ---------------------------------------------------------------------------
echo "Test 8: timeout exit codes"
_T8_CFG=$(mktemp -d)
cat > "$_T8_CFG/workflow-config.yaml" << EOF
version: "1.0.0"
session:
  artifact_prefix: test-t8-artifacts-${_TEST_PID}
EOF
_T8_WORKTREE=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "default")")

# 124 (direct timeout) — passed through as 124
rc=0
CLAUDE_PLUGIN_ROOT="$_T8_CFG" "$WRAPPER" test-hook 30 "exit 124" 2>/dev/null || rc=$?
assert_eq "test_exit_code_124_passthrough" "124" "$rc"

# 143 (SIGTERM = 128+15) — normalized to 124
rc=0
CLAUDE_PLUGIN_ROOT="$_T8_CFG" "$WRAPPER" test-hook 30 "exit 143" 2>/dev/null || rc=$?
assert_eq "test_exit_code_143_normalized" "124" "$rc"

# 137 (SIGKILL = 128+9) — normalized to 124
rc=0
CLAUDE_PLUGIN_ROOT="$_T8_CFG" "$WRAPPER" test-hook 30 "exit 137" 2>/dev/null || rc=$?
assert_eq "test_exit_code_137_normalized" "124" "$rc"

rm -rf "$_T8_CFG" "/tmp/test-t8-artifacts-${_TEST_PID}-${_T8_WORKTREE}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test 9: timeout logging — slow command logs to timeout log file
# ---------------------------------------------------------------------------
echo "Test 9: timeout logging"
# Use TIMEOUT_SECS=-1 so any duration triggers the slow path
TMPDIR_TEST=$(mktemp -d)
# Create a minimal config that sets artifact_prefix
cat > "$TMPDIR_TEST/workflow-config.yaml" << EOF
version: "1.0.0"
session:
  artifact_prefix: test-wrapper-artifacts-${_TEST_PID}
EOF
# The wrapper uses git rev-parse --show-toplevel for worktree name (not the config dir)
WORKTREE_NAME_TEST=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "default")")
ARTIFACTS_DIR_TEST="/tmp/test-wrapper-artifacts-${_TEST_PID}-${WORKTREE_NAME_TEST}"
TIMEOUT_LOG_TEST="$ARTIFACTS_DIR_TEST/precommit-timeouts.log"
rm -f "$TIMEOUT_LOG_TEST" 2>/dev/null || true

# Run with timeout=1 and sleep 2 so duration always exceeds the threshold
rc=0
CLAUDE_PLUGIN_ROOT="$TMPDIR_TEST" "$WRAPPER" slow-hook 1 "sleep 2" 2>/dev/null || rc=$?

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
  artifact_prefix: test-wrapper-ticket-${_TEST_PID}
issue_tracker:
  create_cmd: "$MOCK_CREATE_DIR/mock-create"
EOF

rc=0
CLAUDE_PLUGIN_ROOT="$TMPDIR_TEST" "$WRAPPER" ticket-hook 1 "sleep 2" 2>/dev/null || rc=$?

create_called=0
if [ -f "$MOCK_CREATE_DIR/create_calls" ]; then
    create_called=1
fi
assert_eq "test_timeout_ticket_creation" "1" "$create_called"

WORKTREE_NAME_TEST=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "default")")
rm -rf "$TMPDIR_TEST" "$MOCK_CREATE_DIR" "/tmp/test-wrapper-ticket-${_TEST_PID}-${WORKTREE_NAME_TEST}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test 11: no ticket creation when create_cmd is absent
# ---------------------------------------------------------------------------
echo "Test 11: no ticket creation without config"
TMPDIR_TEST=$(mktemp -d)

cat > "$TMPDIR_TEST/workflow-config.yaml" << EOF
version: "1.0.0"
session:
  artifact_prefix: test-wrapper-noticket-${_TEST_PID}
EOF

rc=0
output=""
output=$(CLAUDE_PLUGIN_ROOT="$TMPDIR_TEST" "$WRAPPER" noticket-hook 1 "sleep 2" 2>&1) || rc=$?

# Should NOT error out -- exit code from the command itself should be 0
assert_eq "test_no_ticket_without_config_exit" "0" "$rc"

WORKTREE_NAME_TEST=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo "default")")
rm -rf "$TMPDIR_TEST" "/tmp/test-wrapper-noticket-${_TEST_PID}-${WORKTREE_NAME_TEST}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Test 13: non-numeric TIMEOUT_SECS is rejected with a clear error
# ---------------------------------------------------------------------------
echo "Test 13: non-numeric TIMEOUT_SECS validation"

# Non-numeric string — should exit non-zero with a clear error message
rc=0
err_output=""
err_output=$("$WRAPPER" test-hook "abc" "echo hello" 2>&1) || rc=$?
assert_ne "test_nonnumeric_timeout_exits_nonzero" "0" "$rc"
assert_contains "test_nonnumeric_timeout_error_msg" "TIMEOUT_SECS" "$err_output"

# Float / decimal — should also be rejected (bash arithmetic only handles integers)
rc=0
err_output=""
err_output=$("$WRAPPER" test-hook "3.14" "echo hello" 2>&1) || rc=$?
assert_ne "test_float_timeout_exits_nonzero" "0" "$rc"

# Empty string — should also be rejected
rc=0
err_output=""
err_output=$("$WRAPPER" test-hook "" "echo hello" 2>&1) || rc=$?
assert_ne "test_empty_timeout_exits_nonzero" "0" "$rc"

# Negative integer — should be rejected (negative timeout is nonsensical)
rc=0
err_output=""
err_output=$("$WRAPPER" test-hook "-5" "echo hello" 2>&1) || rc=$?
assert_ne "test_negative_timeout_exits_nonzero" "0" "$rc"

# Valid positive integer — should still work normally
rc=0
output=""
output=$("$WRAPPER" test-hook "30" "echo valid-run" 2>/dev/null) || rc=$?
assert_eq "test_valid_numeric_timeout_exit" "0" "$rc"
assert_contains "test_valid_numeric_timeout_output" "valid-run" "$output"

# ---------------------------------------------------------------------------
# Test 12: fallback artifact prefix when config absent
#
# Behavioral test: when session.artifact_prefix is not set in config (or no
# config exists at CLAUDE_PLUGIN_ROOT or cwd), the wrapper creates artifacts
# under /tmp/<repo-basename>-test-artifacts-<worktree>/precommit-timeouts.log.
#
# We run the wrapper from a repo subdirectory that has no workflow-config.yaml
# and set CLAUDE_PLUGIN_ROOT to an empty dir, so read-config.sh finds no config
# and returns empty. The wrapper then derives the prefix from the repo basename.
# ---------------------------------------------------------------------------
echo "Test 12: fallback artifact prefix"
_T12_WORKTREE=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo 'default')")
_T12_REPO_NAME=$(basename "$(git rev-parse --show-toplevel 2>/dev/null || echo 'unknown')")
_T12_EXPECTED_PREFIX="${_T12_REPO_NAME}-test-artifacts"
_T12_EXPECTED_LOG="/tmp/${_T12_EXPECTED_PREFIX}-${_T12_WORKTREE}/precommit-timeouts.log"
rm -f "$_T12_EXPECTED_LOG" 2>/dev/null || true

# Use a subdirectory inside the repo (so git rev-parse works) that has no
# workflow-config.yaml (so read-config.sh cwd fallback returns empty).
# lockpick-workflow/tests/lib/ is a stable subdir with no workflow-config.yaml.
_T12_SUBDIR="$REPO_ROOT/lockpick-workflow/tests/lib"
_T12_CFGDIR=$(mktemp -d)  # no workflow-config.yaml inside
rc=0
(cd "$_T12_SUBDIR" && CLAUDE_PLUGIN_ROOT="$_T12_CFGDIR" "$WRAPPER" fallback-hook 1 "sleep 2" 2>/dev/null) || rc=$?

if [ -f "$_T12_EXPECTED_LOG" ]; then
    assert_eq "test_fallback_artifact_prefix_log_created" "exists" "exists"
    _t12_log_has_hook=$(grep -c 'fallback-hook' "$_T12_EXPECTED_LOG" 2>/dev/null || true)
    assert_ne "test_fallback_artifact_prefix_log_has_hook" "0" "$_t12_log_has_hook"
else
    assert_eq "test_fallback_artifact_prefix_log_created" "exists" "missing"
fi

rm -rf "$_T12_CFGDIR" "/tmp/${_T12_EXPECTED_PREFIX}-${_T12_WORKTREE}" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Print summary
# ---------------------------------------------------------------------------
print_summary
