#!/usr/bin/env bash
# tests/scripts/test-verify-gha-runner.sh
# Behavioral tests for plugins/dso/scripts/dso_reconciler/verify-gha-runner.sh
#
# All tests invoke verify-gha-runner.sh with stubbed gh and dso binaries to verify
# actual behavior rather than grepping source code.
#
# Test cases:
#   1. test_auth_success_empty_run_list  — gh auth success + empty run list → exits 0, calls dso ticket comment
#   2. test_auth_failure                 — gh auth failure → exits 1, does NOT call ticket comment
#   3. test_run_list_failure             — gh auth success + run list non-zero exit → exits 1, does NOT call ticket comment
#
# Testing Mode: GREEN — verify-gha-runner.sh exists; tests assert observed behavior.
#
# Usage: bash tests/scripts/test-verify-gha-runner.sh
# Returns: exit 0 on all tests passing, exit 1 on any test failure.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

VERIFY_SCRIPT="$REPO_ROOT/plugins/dso/scripts/dso_reconciler/verify-gha-runner.sh"
TICKET_ID="7705-41e8-9f01-4ebb"

echo "=== test-verify-gha-runner.sh ==="

# Validate the target script exists and is executable.
echo ""
echo "--- test_script_exists ---"
_snapshot_fail
if [[ -x "$VERIFY_SCRIPT" ]]; then
    assert_eq "verify-gha-runner.sh exists and is executable" "exists" "exists"
else
    assert_eq "verify-gha-runner.sh exists and is executable" "exists" "missing"
fi
assert_pass_if_clean "test_script_exists"

# Set up a shared temp directory for all test stubs
_TMP=$(mktemp -d "${TMPDIR:-/tmp}/test-verify-gha-runner.XXXXXX")
trap 'rm -rf "$_TMP"' EXIT

# =============================================================================
# test_auth_success_empty_run_list
# Given: gh auth status exits 0 (authenticated)
#        gh run list exits 0 with empty output (no runs yet on a fresh repo)
# When:  verify-gha-runner.sh is invoked
# Then:  script exits 0
#        dso ticket comment is called with TICKET_ID=7705-41e8-9f01-4ebb
# =============================================================================
echo ""
echo "--- test_auth_success_empty_run_list ---"
_snapshot_fail

_STUB_AUTH_OK="$_TMP/stub-auth-ok"
mkdir -p "$_STUB_AUTH_OK"
_CALL_LOG_AUTH_OK="$_TMP/calls-auth-ok.log"
true > "$_CALL_LOG_AUTH_OK"

# Stub gh: auth status exits 0, run list exits 0 with empty output
cat > "$_STUB_AUTH_OK/gh" <<FAKEGH
#!/usr/bin/env bash
echo "\$*" >> "$_CALL_LOG_AUTH_OK"
case "\$*" in
  "auth status"*)
    echo "Logged in to github.com as testuser" >&2
    exit 0
    ;;
  "run list"*)
    # Empty output simulates a fresh repo with no workflow runs
    exit 0
    ;;
esac
exit 0
FAKEGH
chmod +x "$_STUB_AUTH_OK/gh"

# Stub dso: records all calls to a log file
_STUB_DSO_AUTH_OK="$_TMP/stub-dso-auth-ok"
mkdir -p "$_STUB_DSO_AUTH_OK"
_CALL_LOG_DSO_AUTH_OK="$_TMP/calls-dso-auth-ok.log"
true > "$_CALL_LOG_DSO_AUTH_OK"
cat > "$_STUB_DSO_AUTH_OK/dso" <<FAKEDSO
#!/usr/bin/env bash
echo "\$*" >> "$_CALL_LOG_DSO_AUTH_OK"
exit 0
FAKEDSO
chmod +x "$_STUB_DSO_AUTH_OK/dso"

_auth_ok_exit=0
# DSO_CMD override pins verify-gha-runner.sh to the stub (otherwise it resolves
# to ${REPO_ROOT}/.claude/scripts/dso which would bypass the PATH stub).
PATH="$_STUB_AUTH_OK:$_STUB_DSO_AUTH_OK:$PATH" \
    DSO_CMD="$_STUB_DSO_AUTH_OK/dso" \
    bash "$VERIFY_SCRIPT" 2>/dev/null || _auth_ok_exit=$?

assert_eq "test_auth_success_empty_run_list: script exits 0" "0" "$_auth_ok_exit"

# Verify dso ticket comment was called with the correct ticket ID
_dso_calls_auth_ok=""
_dso_calls_auth_ok=$(cat "$_CALL_LOG_DSO_AUTH_OK" 2>/dev/null || echo "")
assert_contains "test_auth_success_empty_run_list: dso ticket comment called with ticket ID" \
    "$TICKET_ID" "$_dso_calls_auth_ok"

assert_pass_if_clean "test_auth_success_empty_run_list"

# =============================================================================
# test_auth_failure
# Given: gh auth status exits 1 (not authenticated)
# When:  verify-gha-runner.sh is invoked
# Then:  script exits 1
#        dso ticket comment is NOT called
# =============================================================================
echo ""
echo "--- test_auth_failure ---"
_snapshot_fail

_STUB_AUTH_FAIL="$_TMP/stub-auth-fail"
mkdir -p "$_STUB_AUTH_FAIL"
_CALL_LOG_AUTH_FAIL="$_TMP/calls-auth-fail.log"
true > "$_CALL_LOG_AUTH_FAIL"

# Stub gh: auth status exits 1 (not authenticated)
cat > "$_STUB_AUTH_FAIL/gh" <<FAKEGH
#!/usr/bin/env bash
echo "\$*" >> "$_CALL_LOG_AUTH_FAIL"
case "\$*" in
  "auth status"*)
    echo "You are not logged into any GitHub hosts. Run gh auth login to authenticate." >&2
    exit 1
    ;;
esac
exit 0
FAKEGH
chmod +x "$_STUB_AUTH_FAIL/gh"

# Stub dso: records any calls
_STUB_DSO_AUTH_FAIL="$_TMP/stub-dso-auth-fail"
mkdir -p "$_STUB_DSO_AUTH_FAIL"
_CALL_LOG_DSO_AUTH_FAIL="$_TMP/calls-dso-auth-fail.log"
true > "$_CALL_LOG_DSO_AUTH_FAIL"
cat > "$_STUB_DSO_AUTH_FAIL/dso" <<FAKEDSO
#!/usr/bin/env bash
echo "\$*" >> "$_CALL_LOG_DSO_AUTH_FAIL"
exit 0
FAKEDSO
chmod +x "$_STUB_DSO_AUTH_FAIL/dso"

_auth_fail_exit=0
PATH="$_STUB_AUTH_FAIL:$_STUB_DSO_AUTH_FAIL:$PATH" \
    DSO_CMD="$_STUB_DSO_AUTH_FAIL/dso" \
    bash "$VERIFY_SCRIPT" 2>/dev/null || _auth_fail_exit=$?

assert_eq "test_auth_failure: script exits 1 on auth failure" "1" "$_auth_fail_exit"

# Verify dso ticket comment was NOT called (log should be empty or contain no 'ticket comment' entries)
_dso_calls_auth_fail=""
_dso_calls_auth_fail=$(cat "$_CALL_LOG_DSO_AUTH_FAIL" 2>/dev/null || echo "")
assert_not_contains "test_auth_failure: dso ticket comment NOT called on auth failure" \
    "ticket comment" "$_dso_calls_auth_fail"

assert_pass_if_clean "test_auth_failure"

# =============================================================================
# test_run_list_failure
# Given: gh auth status exits 0 (authenticated)
#        gh run list exits non-zero (non-auth failure, e.g. network error)
# When:  verify-gha-runner.sh is invoked
# Then:  script exits 1
# =============================================================================
echo ""
echo "--- test_run_list_failure ---"
_snapshot_fail

_STUB_RUNLIST_FAIL="$_TMP/stub-runlist-fail"
mkdir -p "$_STUB_RUNLIST_FAIL"
_CALL_LOG_RUNLIST_FAIL="$_TMP/calls-runlist-fail.log"
true > "$_CALL_LOG_RUNLIST_FAIL"

# Stub gh: auth status exits 0 (authenticated), run list exits 2 (non-auth error)
cat > "$_STUB_RUNLIST_FAIL/gh" <<FAKEGH
#!/usr/bin/env bash
echo "\$*" >> "$_CALL_LOG_RUNLIST_FAIL"
case "\$*" in
  "auth status"*)
    echo "Logged in to github.com as testuser" >&2
    exit 0
    ;;
  "run list"*)
    echo "could not resolve host: api.github.com" >&2
    exit 2
    ;;
esac
exit 0
FAKEGH
chmod +x "$_STUB_RUNLIST_FAIL/gh"

# Stub dso (should NOT be called in this scenario; record every invocation so we
# can assert no comment was posted after run-list failure).
_STUB_DSO_RUNLIST="$_TMP/stub-dso-runlist-fail"
mkdir -p "$_STUB_DSO_RUNLIST"
_DSO_CALL_LOG_RUNLIST_FAIL="$_TMP/dso-calls-runlist-fail.log"
true > "$_DSO_CALL_LOG_RUNLIST_FAIL"
cat > "$_STUB_DSO_RUNLIST/dso" <<FAKEDSO
#!/usr/bin/env bash
echo "\$*" >> "$_DSO_CALL_LOG_RUNLIST_FAIL"
exit 0
FAKEDSO
chmod +x "$_STUB_DSO_RUNLIST/dso"

# DSO_CMD override pins verify-gha-runner.sh to the stub (it normally resolves
# to ${REPO_ROOT}/.claude/scripts/dso which would bypass the PATH stub).
_runlist_fail_exit=0
PATH="$_STUB_RUNLIST_FAIL:$_STUB_DSO_RUNLIST:$PATH" \
    DSO_CMD="$_STUB_DSO_RUNLIST/dso" \
    bash "$VERIFY_SCRIPT" 2>/dev/null || _runlist_fail_exit=$?

assert_eq "test_run_list_failure: script exits 1 on run list failure" "1" "$_runlist_fail_exit"

# Assert dso ticket comment was NOT called — the script must short-circuit on
# run-list failure before reaching the comment step.
_dso_call_count=$(wc -l < "$_DSO_CALL_LOG_RUNLIST_FAIL" | tr -d ' ')
assert_eq "test_run_list_failure: dso ticket comment must not be invoked on run list failure" "0" "$_dso_call_count"

assert_pass_if_clean "test_run_list_failure"

# =============================================================================
print_summary
