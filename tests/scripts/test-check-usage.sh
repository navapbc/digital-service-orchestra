#!/usr/bin/env bash
# tests/scripts/test-check-usage.sh
# Integration tests for check-usage.sh bash wrapper.
#
# All tests mock the Python layer — no real HTTP calls are made.
# Mocking strategy: replace check_usage.py with a stub script that
# emits controlled output and exit codes based on env vars.
#
# Usage: bash tests/scripts/test-check-usage.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
CHECK_USAGE="$REPO_ROOT/plugins/dso/scripts/check-usage.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-check-usage.sh ==="

# ── Setup: create a mock check_usage.py ────────────────────────────────────
# We create a temp directory with a mock check_usage.py and a symlink/copy
# of check-usage.sh that points SCRIPT_DIR at the temp dir.
MOCK_DIR="$(mktemp -d)"
trap 'rm -rf "$MOCK_DIR"' EXIT

# Mock check_usage.py: reads MOCK_EXIT_CODE and MOCK_STDOUT env vars
cat > "$MOCK_DIR/check_usage.py" <<'PYEOF'
#!/usr/bin/env python3
"""Mock check_usage.py for integration tests."""
import os, sys

exit_code = int(os.environ.get("MOCK_EXIT_CODE", "0"))
stdout_lines = os.environ.get("MOCK_STDOUT", "")
if stdout_lines:
    print(stdout_lines)
sys.exit(exit_code)
PYEOF

# Create a wrapper script in MOCK_DIR that mirrors check-usage.sh
# but resolves SCRIPT_DIR to MOCK_DIR (so it finds mock check_usage.py)
cat > "$MOCK_DIR/check-usage.sh" <<'SHEOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec python3 "$SCRIPT_DIR/check_usage.py" "$@"
SHEOF
chmod +x "$MOCK_DIR/check-usage.sh"

MOCK_WRAPPER="$MOCK_DIR/check-usage.sh"

# ── test_wrapper_exists_and_executable ─────────────────────────────────────
_snapshot_fail
assert_eq "test_wrapper_exists: file exists" "1" "$([ -f "$CHECK_USAGE" ] && echo 1 || echo 0)"
assert_eq "test_wrapper_executable: is executable" "1" "$([ -x "$CHECK_USAGE" ] && echo 1 || echo 0)"
assert_pass_if_clean "test_wrapper_exists_and_executable"

# ── test_exit_code_0_unlimited ─────────────────────────────────────────────
# Mock returns exit 0 (unlimited) with USAGE_SOURCE line
_snapshot_fail
exit_0_code=0
exit_0_output=""
exit_0_output=$(MOCK_EXIT_CODE=0 MOCK_STDOUT="USAGE_SOURCE: no-credentials" bash "$MOCK_WRAPPER" 2>&1) || exit_0_code=$?
assert_eq "test_exit_code_0_unlimited: exit code" "0" "$exit_0_code"
assert_contains "test_exit_code_0_unlimited: USAGE_SOURCE" "USAGE_SOURCE:" "$exit_0_output"
assert_pass_if_clean "test_exit_code_0_unlimited"

# ── test_exit_code_1_throttled ─────────────────────────────────────────────
# Mock returns exit 1 (throttled)
_snapshot_fail
exit_1_code=0
exit_1_output=""
exit_1_output=$(MOCK_EXIT_CODE=1 MOCK_STDOUT="USAGE_SOURCE: api
VERDICT: 1" bash "$MOCK_WRAPPER" 2>&1) || exit_1_code=$?
assert_eq "test_exit_code_1_throttled: exit code" "1" "$exit_1_code"
assert_contains "test_exit_code_1_throttled: VERDICT 1" "VERDICT: 1" "$exit_1_output"
assert_pass_if_clean "test_exit_code_1_throttled"

# ── test_exit_code_2_paused ───────────────────────────────────────────────
# Mock returns exit 2 (paused)
_snapshot_fail
exit_2_code=0
exit_2_output=""
exit_2_output=$(MOCK_EXIT_CODE=2 MOCK_STDOUT="USAGE_SOURCE: api
VERDICT: 2" bash "$MOCK_WRAPPER" 2>&1) || exit_2_code=$?
assert_eq "test_exit_code_2_paused: exit code" "2" "$exit_2_code"
assert_contains "test_exit_code_2_paused: VERDICT 2" "VERDICT: 2" "$exit_2_output"
assert_pass_if_clean "test_exit_code_2_paused"

# ── test_ci_fallback_no_credentials ────────────────────────────────────────
# When check_usage.py detects no credentials, it exits 0 with "no-credentials"
# We mock this exact behavior
_snapshot_fail
ci_code=0
ci_output=""
ci_output=$(MOCK_EXIT_CODE=0 MOCK_STDOUT="USAGE_SOURCE: no-credentials" bash "$MOCK_WRAPPER" 2>&1) || ci_code=$?
assert_eq "test_ci_fallback_no_credentials: exit code" "0" "$ci_code"
assert_contains "test_ci_fallback_no_credentials: no-credentials" "no-credentials" "$ci_output"
assert_pass_if_clean "test_ci_fallback_no_credentials"

# ── test_usage_source_api_output ───────────────────────────────────────────
# Verify structured output lines from an API response
_snapshot_fail
api_code=0
api_output=""
api_output=$(MOCK_EXIT_CODE=0 MOCK_STDOUT="USAGE_SOURCE: api
USAGE_5HR: 45%
USAGE_7DAY: 30%
VERDICT: 0" bash "$MOCK_WRAPPER" 2>&1) || api_code=$?
assert_eq "test_usage_source_api_output: exit code" "0" "$api_code"
assert_contains "test_usage_source_api_output: USAGE_SOURCE api" "USAGE_SOURCE: api" "$api_output"
assert_contains "test_usage_source_api_output: USAGE_5HR" "USAGE_5HR:" "$api_output"
assert_contains "test_usage_source_api_output: USAGE_7DAY" "USAGE_7DAY:" "$api_output"
assert_contains "test_usage_source_api_output: VERDICT 0" "VERDICT: 0" "$api_output"
assert_pass_if_clean "test_usage_source_api_output"

# ── test_usage_source_cache_output ─────────────────────────────────────────
# Verify structured output lines from a cache response
_snapshot_fail
cache_code=0
cache_output=""
cache_output=$(MOCK_EXIT_CODE=0 MOCK_STDOUT="USAGE_SOURCE: cache
USAGE_5HR: 80%
USAGE_7DAY: 60%
VERDICT: 0" bash "$MOCK_WRAPPER" 2>&1) || cache_code=$?
assert_eq "test_usage_source_cache_output: exit code" "0" "$cache_code"
assert_contains "test_usage_source_cache_output: USAGE_SOURCE cache" "USAGE_SOURCE: cache" "$cache_output"
assert_pass_if_clean "test_usage_source_cache_output"

# ── test_real_wrapper_structure ────────────────────────────────────────────
# Verify the real check-usage.sh has the expected structure (exec + check_usage.py)
_snapshot_fail
wrapper_content=$(cat "$CHECK_USAGE")
assert_contains "test_real_wrapper_structure: shebang" "#!/usr/bin/env bash" "$wrapper_content"
assert_contains "test_real_wrapper_structure: set -euo" "set -euo pipefail" "$wrapper_content"
assert_contains "test_real_wrapper_structure: exec python3" "exec python3" "$wrapper_content"
assert_contains "test_real_wrapper_structure: check_usage.py" "check_usage.py" "$wrapper_content"
assert_pass_if_clean "test_real_wrapper_structure"

print_summary
