#!/usr/bin/env bash
# tests/scripts/test-gh-availability-check.sh
# Behavioral tests for plugins/dso/scripts/gh-availability-check.sh
#
# All tests invoke gh-availability-check.sh with stubbed gh binaries to verify
# actual behavior rather than grepping source code.
#
# Usage: bash tests/scripts/test-gh-availability-check.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

GH_AVAIL="$DSO_PLUGIN_DIR/scripts/gh-availability-check.sh"

echo "=== test-gh-availability-check.sh ==="

_TMP=$(mktemp -d)
trap 'rm -rf "$_TMP"' EXIT

# Create a PATH directory containing bash but NOT gh, for not-installed tests.
# Using /usr/bin:/bin doesn't work in CI where gh is at /usr/bin/gh.
_NO_GH_PATH="$_TMP/no-gh-path"
mkdir -p "$_NO_GH_PATH"
ln -s "$(command -v bash)" "$_NO_GH_PATH/bash"

# =============================================================================
# test_gh_authenticated: Mock gh in PATH, mock gh auth status exit 0
# assert output GH_STATUS=authenticated
# =============================================================================
echo ""
echo "--- test_gh_authenticated ---"
_snapshot_fail

FAKE_GH_AUTH_OK="$_TMP/fake-gh-auth-ok"
mkdir -p "$FAKE_GH_AUTH_OK"
cat > "$FAKE_GH_AUTH_OK/gh" <<'FAKEGH'
#!/usr/bin/env bash
if [[ "$1 $2" == "auth status" ]]; then
    echo "Logged in to github.com as testuser" >&2
    exit 0
fi
exit 0
FAKEGH
chmod +x "$FAKE_GH_AUTH_OK/gh"

auth_ok_output=$(PATH="$FAKE_GH_AUTH_OK:$PATH" bash "$GH_AVAIL" 2>&1)
assert_contains "test_gh_authenticated: GH_STATUS=authenticated in output" "GH_STATUS=authenticated" "$auth_ok_output"

assert_pass_if_clean "test_gh_authenticated"

# =============================================================================
# test_gh_not_authenticated: Mock gh in PATH, mock gh auth status exit 1
# assert GH_STATUS=not_authenticated and FALLBACK=commands
# =============================================================================
echo ""
echo "--- test_gh_not_authenticated ---"
_snapshot_fail

FAKE_GH_NOT_AUTH="$_TMP/fake-gh-not-auth"
mkdir -p "$FAKE_GH_NOT_AUTH"
cat > "$FAKE_GH_NOT_AUTH/gh" <<'FAKEGH'
#!/usr/bin/env bash
if [[ "$1 $2" == "auth status" ]]; then
    echo "You are not logged into any GitHub hosts. Run gh auth login to authenticate." >&2
    exit 1
fi
exit 0
FAKEGH
chmod +x "$FAKE_GH_NOT_AUTH/gh"

not_auth_output=$(PATH="$FAKE_GH_NOT_AUTH:$PATH" bash "$GH_AVAIL" 2>&1)
assert_contains "test_gh_not_authenticated: GH_STATUS=not_authenticated in output" "GH_STATUS=not_authenticated" "$not_auth_output"
assert_contains "test_gh_not_authenticated: FALLBACK=commands in output" "FALLBACK=commands" "$not_auth_output"

assert_pass_if_clean "test_gh_not_authenticated"

# =============================================================================
# test_gh_not_installed: Empty PATH (no gh), assert GH_STATUS=not_installed
# and FALLBACK=ui_steps
# =============================================================================
echo ""
echo "--- test_gh_not_installed ---"
_snapshot_fail

not_installed_output=$(PATH="$_NO_GH_PATH" bash "$GH_AVAIL" 2>&1)
assert_contains "test_gh_not_installed: GH_STATUS=not_installed in output" "GH_STATUS=not_installed" "$not_installed_output"
assert_contains "test_gh_not_installed: FALLBACK=ui_steps in output" "FALLBACK=ui_steps" "$not_installed_output"

assert_pass_if_clean "test_gh_not_installed"

# =============================================================================
# test_fallback_commands_format: When not_authenticated, verify output contains
# valid gh variable set commands for bridge variables
# =============================================================================
echo ""
echo "--- test_fallback_commands_format ---"
_snapshot_fail

# Reuse the not-authenticated stub from above
fallback_cmd_output=$(PATH="$FAKE_GH_NOT_AUTH:$PATH" bash "$GH_AVAIL" 2>&1)
assert_contains "test_fallback_commands_format: gh variable set command present" "gh variable set" "$fallback_cmd_output"

assert_pass_if_clean "test_fallback_commands_format"

# =============================================================================
# test_fallback_ui_steps_format: When not_installed, verify output contains
# GitHub.com navigation instructions
# =============================================================================
echo ""
echo "--- test_fallback_ui_steps_format ---"
_snapshot_fail

ui_steps_output=$(PATH="$_NO_GH_PATH" bash "$GH_AVAIL" 2>&1)
assert_contains "test_fallback_ui_steps_format: github.com reference in output" "github.com" "$ui_steps_output"

assert_pass_if_clean "test_fallback_ui_steps_format"

# =============================================================================
# test_accepts_variable_list: Call with --vars=JIRA_URL,JIRA_USER
# --secrets=JIRA_API_TOKEN, verify fallback commands reference these
# specific vars/secrets
# =============================================================================
echo ""
echo "--- test_accepts_variable_list ---"
_snapshot_fail

# Use not-authenticated stub to trigger fallback commands output
vars_output=$(PATH="$FAKE_GH_NOT_AUTH:$PATH" bash "$GH_AVAIL" --vars=JIRA_URL,JIRA_USER --secrets=JIRA_API_TOKEN 2>&1)
assert_contains "test_accepts_variable_list: JIRA_URL in output" "JIRA_URL" "$vars_output"
assert_contains "test_accepts_variable_list: JIRA_USER in output" "JIRA_USER" "$vars_output"
assert_contains "test_accepts_variable_list: JIRA_API_TOKEN in output" "JIRA_API_TOKEN" "$vars_output"

assert_pass_if_clean "test_accepts_variable_list"

# =============================================================================
print_summary
