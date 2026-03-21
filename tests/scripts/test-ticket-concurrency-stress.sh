#!/usr/bin/env bash
# tests/scripts/test-ticket-concurrency-stress.sh
# RED stub: concurrency stress test skeleton for ticket system.
#
# This is a placeholder that always fails (RED). The full harness
# (5 sessions x 10 ops) is implemented in dso-ltwr.
#
# NOTE: This test is intentionally excluded from the suite runner
# (run-script-tests.sh auto-discovers test-*.sh files). When run from
# the suite (_RUN_ALL_ACTIVE=1), it exits 0 with a SKIP message to
# avoid breaking `bash tests/run-all.sh`. Run it directly to see RED:
#   bash tests/scripts/test-ticket-concurrency-stress.sh
#
# Usage: bash tests/scripts/test-ticket-concurrency-stress.sh
# Returns: exit non-zero (RED) when run directly; exit 0 when run from suite.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-concurrency-stress.sh ==="

# ── Suite-runner guard: skip when run from run-all.sh ────────────────────────
# The stub always fails by design (RED). If auto-discovered by
# run-script-tests.sh, it would break `bash tests/run-all.sh`.
# Skip with exit 0 when _RUN_ALL_ACTIVE=1 (set by tests/run-all.sh).
if [ "${_RUN_ALL_ACTIVE:-0}" = "1" ]; then
    echo "SKIP: stress test stub (RED) — deferred to dso-ltwr"
    echo ""
    printf "PASSED: 0  FAILED: 0\n"
    exit 0
fi

# ── Stub test: always fails (RED) ───────────────────────────────────────────

# test_concurrent_stress_5_sessions_10_ops
# STUB: harness not yet implemented.
# The full test will spawn 5 concurrent sessions each performing 10
# ticket operations (create, transition, comment) against a shared
# .tickets-tracker store and verify zero data loss via reducer replay.
test_concurrent_stress_5_sessions_10_ops() {
    _snapshot_fail
    # STUB: harness not yet implemented
    assert_eq "stress test: harness implemented" "yes" "no"
    assert_pass_if_clean "test_concurrent_stress_5_sessions_10_ops"
}
test_concurrent_stress_5_sessions_10_ops

print_summary
