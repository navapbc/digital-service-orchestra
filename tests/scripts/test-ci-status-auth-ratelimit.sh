#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-ci-status-auth-ratelimit.sh
# Tests for auth pre-flight check, rate-limit detection, and max-iteration ceiling
# in lockpick-workflow/scripts/ci-status.sh.
#
# Ticket: lockpick-doc-to-logic-vphc
#
# Tests:
#   1. test_auth_check_present       — script contains gh auth status call
#   2. test_auth_failure_exits_fast  — unauthenticated gh exits 1 with clear message
#   3. test_rate_limit_detection     — script contains rate-limit/429/backoff detection
#   4. test_max_iterations_present   — script contains MAX_POLL_ITERATIONS or max_iterations
#   5. test_max_iterations_ceiling   — polling loop exits after max iterations (not infinite)
#   6. test_rate_limit_grep_patterns — acceptance criteria grep patterns pass
#
# Usage: bash lockpick-workflow/tests/scripts/test-ci-status-auth-ratelimit.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

CI_STATUS_SH="$PLUGIN_ROOT/scripts/ci-status.sh"

echo "=== test-ci-status-auth-ratelimit.sh ==="

# =============================================================================
# Test 1: auth check present in script
# ci-status.sh must contain a gh auth check before any API calls.
# =============================================================================
echo ""
echo "--- auth check present ---"
_snapshot_fail

AUTH_CHECK_COUNT=$(grep -c "gh auth" "$CI_STATUS_SH" || echo "0")
assert_ne "test_auth_check_present: gh auth appears in ci-status.sh" "0" "$AUTH_CHECK_COUNT"

assert_pass_if_clean "auth check present in ci-status.sh"

# =============================================================================
# Test 2: auth failure causes fast exit with clear message
# When gh auth status returns non-zero, the script should exit 1 with a
# clear error message (not loop forever).
# We test this by stubbing gh to fail auth status and verifying exit code.
# =============================================================================
echo ""
echo "--- auth failure exits fast ---"
_snapshot_fail

_OUTER_TMP=$(mktemp -d)
trap 'rm -rf "$_OUTER_TMP"' EXIT

# Create a fake gh that fails on "auth status" but otherwise does nothing
FAKE_GH_DIR="$_OUTER_TMP/fake-bin"
mkdir -p "$FAKE_GH_DIR"
cat > "$FAKE_GH_DIR/gh" <<'FAKEGH'
#!/usr/bin/env bash
# Fake gh: auth status fails, everything else succeeds vacuously
if [[ "$1 $2" == "auth status" ]]; then
    echo "You are not logged into any GitHub hosts. Run gh auth login to authenticate." >&2
    exit 1
fi
# Any other gh call returns empty JSON to avoid hanging
if [[ "$1" == "run" ]]; then
    echo "[]"
fi
exit 0
FAKEGH
chmod +x "$FAKE_GH_DIR/gh"

# Run ci-status.sh with the fake gh in PATH
result=$(PATH="$FAKE_GH_DIR:$PATH" bash "$CI_STATUS_SH" 2>&1) || auth_exit=$?
auth_exit="${auth_exit:-0}"

assert_ne "test_auth_failure_exits_nonzero: exits non-zero when unauthenticated" "0" "$auth_exit"
assert_contains "test_auth_failure_message: output mentions authentication" "auth" "$result"

assert_pass_if_clean "auth failure exits fast with clear message"

# =============================================================================
# Test 3: rate-limit detection present in script
# ci-status.sh must contain references to rate limiting (429, rate limit, or backoff).
# =============================================================================
echo ""
echo "--- rate-limit detection present ---"
_snapshot_fail

RATELIMIT_COUNT=$(grep -cE "rate.limit|429|backoff" "$CI_STATUS_SH" || echo "0")
assert_ne "test_rate_limit_detection: rate-limit/429/backoff appears in ci-status.sh" "0" "$RATELIMIT_COUNT"

assert_pass_if_clean "rate-limit detection present in ci-status.sh"

# =============================================================================
# Test 4: MAX_POLL_ITERATIONS or max_iterations present
# =============================================================================
echo ""
echo "--- max iterations ceiling present ---"
_snapshot_fail

MAX_ITER_COUNT=$(grep -cE "MAX_POLL_ITERATIONS|max_iterations" "$CI_STATUS_SH" || echo "0")
assert_ne "test_max_iterations_present: MAX_POLL_ITERATIONS appears in ci-status.sh" "0" "$MAX_ITER_COUNT"

assert_pass_if_clean "MAX_POLL_ITERATIONS ceiling defined in ci-status.sh"

# =============================================================================
# Test 5: Polling loop respects max iterations ceiling
# When the CI run stays in_progress for more than MAX_POLL_ITERATIONS iterations,
# the script should exit 1 with a timeout error instead of looping forever.
# We stub gh to always return in_progress and verify the script exits within
# a reasonable number of gh calls.
# =============================================================================
echo ""
echo "--- max iterations causes exit (not infinite loop) ---"
_snapshot_fail

FAKE_GH_DIR2="$_OUTER_TMP/fake-bin2"
mkdir -p "$FAKE_GH_DIR2"
CALL_COUNT_FILE="$_OUTER_TMP/gh_call_count.txt"
echo "0" > "$CALL_COUNT_FILE"

# Create a fake gh that:
#   - passes auth status
#   - returns in_progress for all run list/view calls
# This forces the script into its polling loop, which should eventually exit
# due to the MAX_POLL_ITERATIONS ceiling (not run forever).
cat > "$FAKE_GH_DIR2/gh" <<FAKEGH2
#!/usr/bin/env bash
# Fake gh for max-iterations test
# Count calls to detect infinite loops
_count=\$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")
_count=\$(( _count + 1 ))
echo "\$_count" > "$CALL_COUNT_FILE"

if [[ "\$1 \$2" == "auth status" ]]; then
    echo "Logged in to github.com as testuser" >&2
    exit 0
fi

# For ls-remote (called for SHA resolution), return nothing
if [[ "\$1" == "ls-remote" ]]; then
    exit 0
fi

# run list: return in_progress run (headSha must match fake git ls-remote output)
if [[ "\$1" == "run" && "\$2" == "list" ]]; then
    echo '[{"databaseId":12345,"status":"in_progress","conclusion":null,"name":"CI","startedAt":"2020-01-01T00:00:00Z","createdAt":"2020-01-01T00:00:00Z","headSha":"abc123def456"}]'
    exit 0
fi

# run view: always return in_progress
if [[ "\$1" == "run" && "\$2" == "view" ]]; then
    echo '{"status":"in_progress","conclusion":null,"name":"CI"}'
    exit 0
fi

exit 0
FAKEGH2
chmod +x "$FAKE_GH_DIR2/gh"

# Also stub git ls-remote and git rev-parse to avoid real git calls
FAKE_GIT_DIR="$_OUTER_TMP/fake-git"
mkdir -p "$FAKE_GIT_DIR"
cat > "$FAKE_GIT_DIR/git" <<'FAKEGIT'
#!/usr/bin/env bash
# Fake git for iteration test
if [[ "$1" == "ls-remote" ]]; then
    echo "abc123def456    refs/heads/main"
    exit 0
fi
if [[ "$1" == "rev-parse" ]]; then
    if [[ "$2" == "--show-toplevel" ]]; then
        echo "/tmp/fake-repo"
        exit 0
    fi
    echo "abc123def456"
    exit 0
fi
exit 0
FAKEGIT
chmod +x "$FAKE_GIT_DIR/git"

# Override sleep to be instant so the test runs fast
FAKE_SLEEP_DIR="$_OUTER_TMP/fake-sleep"
mkdir -p "$FAKE_SLEEP_DIR"
cat > "$FAKE_SLEEP_DIR/sleep" <<'FAKESLEEP'
#!/usr/bin/env bash
# Fake sleep: instant
exit 0
FAKESLEEP
chmod +x "$FAKE_SLEEP_DIR/sleep"

# Run with --wait mode and a controlled PATH
# The script should exit non-zero (timeout) rather than loop forever
# We use a generous real timeout as a safety net
iter_result=0
timeout 30 bash -c "
    PATH='$FAKE_SLEEP_DIR:$FAKE_GH_DIR2:$FAKE_GIT_DIR:$PATH'
    export PATH
    bash '$CI_STATUS_SH' --wait --skip-regression-check --branch main 2>&1
" > "$_OUTER_TMP/iter_output.txt" 2>&1 || iter_result=$?

_iter_output=$(cat "$_OUTER_TMP/iter_output.txt" 2>/dev/null || echo "")
_gh_calls=$(cat "$CALL_COUNT_FILE" 2>/dev/null || echo "0")

# The script must have exited (iter_result != 0 means exit 1 or timeout)
# Check it did NOT time out via our 30s watchdog (timeout exits 124)
assert_ne "test_max_iter_exited: script exited non-zero (not infinite loop)" "0" "$iter_result"

# If it timed out via our watchdog (exit 124), that means the ceiling didn't work
_watchdog_timeout=0
if [[ "$iter_result" == "124" ]]; then
    _watchdog_timeout=1
fi
assert_eq "test_max_iter_not_watchdog: script exited before 30s watchdog" "0" "$_watchdog_timeout"

# Output should mention timeout or max iterations
assert_contains "test_max_iter_message: output contains TIMEOUT or iterations" "TIMEOUT" "$_iter_output"

assert_pass_if_clean "max iterations causes exit, not infinite loop"

# =============================================================================
# Test 6: Acceptance criteria grep patterns
# These directly verify the grep patterns from the ticket's acceptance criteria.
# =============================================================================
echo ""
echo "--- acceptance criteria grep patterns ---"
_snapshot_fail

# grep -q "gh auth" lockpick-workflow/scripts/ci-status.sh
GH_AUTH_MATCH=$(grep -c "gh auth" "$CI_STATUS_SH" || echo "0")
assert_ne "acceptance_criteria_gh_auth" "0" "$GH_AUTH_MATCH"

# grep -q "rate.limit\|429\|backoff" lockpick-workflow/scripts/ci-status.sh
RATELIMIT_MATCH=$(grep -cE "rate.limit|429|backoff" "$CI_STATUS_SH" || echo "0")
assert_ne "acceptance_criteria_ratelimit_429_backoff" "0" "$RATELIMIT_MATCH"

# grep -q "MAX_POLL_ITERATIONS\|max_iterations" lockpick-workflow/scripts/ci-status.sh
MAXITER_MATCH=$(grep -cE "MAX_POLL_ITERATIONS|max_iterations" "$CI_STATUS_SH" || echo "0")
assert_ne "acceptance_criteria_max_poll_iterations" "0" "$MAXITER_MATCH"

assert_pass_if_clean "all acceptance criteria grep patterns pass"

# =============================================================================
# Summary
# =============================================================================
print_summary
