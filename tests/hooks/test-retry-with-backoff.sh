#!/usr/bin/env bash
# Test retry_with_backoff function from deps.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/../lib/assert.sh"

# Source deps.sh to get retry_with_backoff
REPO_ROOT="$(cd "$SCRIPT_DIR/../../../" && pwd)"
# Reset the loaded guard so we can re-source
unset _DEPS_LOADED
source "$REPO_ROOT/lockpick-workflow/hooks/lib/deps.sh"

# ── Test 1: Successful command on first try ──
output=$(retry_with_backoff 3 0.01 echo "hello" 2>&1)
assert_eq "success_first_try" "hello" "$output"

# ── Test 2: Command that always fails exhausts retries ──
exit_code=0
retry_with_backoff 2 0.01 false 2>/dev/null || exit_code=$?
assert_ne "fail_exhausts_retries" "0" "$exit_code"

# ── Test 3: Command that fails then succeeds ──
COUNTER_FILE=$(mktemp)
echo "0" > "$COUNTER_FILE"
cat > /tmp/test-retry-flaky.sh << 'FLAKY'
#!/usr/bin/env bash
COUNTER_FILE="$1"
count=$(cat "$COUNTER_FILE")
count=$((count + 1))
echo "$count" > "$COUNTER_FILE"
if [ "$count" -lt 3 ]; then
    exit 1
fi
echo "succeeded on attempt $count"
exit 0
FLAKY
chmod +x /tmp/test-retry-flaky.sh

output=$(retry_with_backoff 4 0.01 /tmp/test-retry-flaky.sh "$COUNTER_FILE" 2>/dev/null)
assert_eq "flaky_succeeds_on_retry" "succeeded on attempt 3" "$output"
rm -f "$COUNTER_FILE" /tmp/test-retry-flaky.sh

# ── Test 4: Retries count matches max_retries ──
ATTEMPT_FILE=$(mktemp)
echo "0" > "$ATTEMPT_FILE"
cat > /tmp/test-retry-count.sh << 'COUNT'
#!/usr/bin/env bash
count=$(cat "$1")
count=$((count + 1))
echo "$count" > "$1"
exit 1
COUNT
chmod +x /tmp/test-retry-count.sh

retry_with_backoff 3 0.01 /tmp/test-retry-count.sh "$ATTEMPT_FILE" 2>/dev/null || true
attempts=$(cat "$ATTEMPT_FILE")
# 1 initial + 3 retries = 4 total attempts
assert_eq "retry_count_correct" "4" "$attempts"
rm -f "$ATTEMPT_FILE" /tmp/test-retry-count.sh

# ── Test 5: Zero retries means run once ──
exit_code=0
retry_with_backoff 0 0.01 false 2>/dev/null || exit_code=$?
assert_ne "zero_retries_runs_once" "0" "$exit_code"

print_summary
