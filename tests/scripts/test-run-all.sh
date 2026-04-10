#!/usr/bin/env bash
# tests/scripts/test-run-all.sh
# TDD tests for per-suite timeout and orphan cleanup in run-all.sh.
#
# Tests:
#   test_suite_timeout_produces_clean_exit  — mock slow suite, assert non-144 exit
#   test_orphan_cleanup_on_exit             — sentinel process killed on EXIT via pgrep
#
# Usage: bash tests/scripts/test-run-all.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
RUN_ALL="$PLUGIN_ROOT/tests/scripts/run-all.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-run-all.sh ==="

# ── test_suite_timeout_produces_clean_exit ────────────────────────────────────
# Verify that a slow suite (sleeps longer than timeout) is killed cleanly
# and run-all.sh exits with a non-144 (non-SIGURG) code.
# Exit 124 = timeout killed the suite; that propagates as suite failure (exit 1).
# The important property is: NOT exit 144 (SIGURG from Claude Code tool timeout).
_snapshot_fail
_TMPDIR=$(mktemp -d)
_slow_runner="$_TMPDIR/slow-suite.sh"
_fast_runner="$_TMPDIR/fast-suite.sh"
cat >"$_slow_runner" <<'RUNNER'
#!/usr/bin/env bash
sleep 300
RUNNER
chmod +x "$_slow_runner"
cat >"$_fast_runner" <<'RUNNER'
#!/usr/bin/env bash
exit 0
RUNNER
chmod +x "$_fast_runner"

# Run with a 2s per-suite timeout (overrides the default 120s for speed)
timeout 30 bash "$RUN_ALL" \
    --hooks-runner "$_slow_runner" \
    --scripts-runner "$_fast_runner" \
    --evals-runner "$_fast_runner" \
    --suite-timeout 2 \
    >/dev/null 2>&1
_actual_exit=$?

# Must NOT be 144 (SIGURG). Should be 1 (suite failure) or 124 (timeout killed).
assert_ne "test_suite_timeout_produces_clean_exit" "144" "$_actual_exit"
assert_pass_if_clean "test_suite_timeout_produces_clean_exit"
rm -rf "$_TMPDIR"

# ── test_orphan_cleanup_on_exit ───────────────────────────────────────────────
# Verify that child processes are cleaned up when run-all.sh exits.
# We launch a sentinel background process; run-all.sh's EXIT trap should kill it.
_snapshot_fail
_TMPDIR2=$(mktemp -d)
_sentinel_tag="run-all-test-sentinel-$$"

# Create a suite runner that launches a long-running sentinel and records its PID
_sentinel_runner="$_TMPDIR2/sentinel-suite.sh"
_sentinel_pid_file="$_TMPDIR2/sentinel.pid"
cat >"$_sentinel_runner" <<RUNNER
#!/usr/bin/env bash
# Start sentinel in same process group as this suite
bash -c "exec -a $_sentinel_tag sleep 300" &
echo \$! > "$_sentinel_pid_file"
wait
exit 0
RUNNER
chmod +x "$_sentinel_runner"

_noop_runner="$_TMPDIR2/noop-suite.sh"
cat >"$_noop_runner" <<'RUNNER'
#!/usr/bin/env bash
exit 0
RUNNER
chmod +x "$_noop_runner"

# Run run-all.sh with a short suite timeout so it completes quickly
timeout 30 bash "$RUN_ALL" \
    --hooks-runner "$_sentinel_runner" \
    --scripts-runner "$_noop_runner" \
    --evals-runner "$_noop_runner" \
    --suite-timeout 5 \
    >/dev/null 2>&1
_run_exit=$?

# Give cleanup a moment to propagate (2s for slow CI environments)
sleep 2

# Check: sentinel process should no longer exist
# Primary check: PID file (authoritative — process created the PID)
_sentinel_alive=0
if [ -f "$_sentinel_pid_file" ]; then
    _spid=$(cat "$_sentinel_pid_file" 2>/dev/null || echo "")
    if [ -n "$_spid" ] && kill -0 "$_spid" 2>/dev/null; then
        _sentinel_alive=1
    fi
fi

# Secondary check by name — only if PID check says alive (avoids pgrep race on CI)
if [ "$_sentinel_alive" -eq 1 ] && pgrep -f "$_sentinel_tag" >/dev/null 2>&1; then
    _sentinel_alive=1
elif [ "$_sentinel_alive" -eq 1 ]; then
    # PID exists but pgrep doesn't find it — process is dying, treat as dead
    _sentinel_alive=0
fi

assert_eq "test_orphan_cleanup_on_exit" "0" "$_sentinel_alive"
assert_pass_if_clean "test_orphan_cleanup_on_exit"
rm -rf "$_TMPDIR2"

print_summary
