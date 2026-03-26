#!/usr/bin/env bash
# tests/scripts/test-ticket-benchmark.sh
# RED tests for plugins/dso/scripts/ticket-benchmark.sh — ticket benchmark subcommand.
#
# All test functions MUST FAIL until ticket-benchmark.sh is implemented.
# Covers: exit code under/over threshold, timing output format.
#
# Usage: bash tests/scripts/test-ticket-benchmark.sh
# Returns: exit non-zero (RED) until ticket-benchmark.sh is implemented.

# NOTE: -e is intentionally omitted — test functions return non-zero by design
# (they assert against unimplemented features). -e would abort the runner.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
TICKET_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket"
BENCHMARK_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ticket-benchmark.sh"

source "$REPO_ROOT/tests/lib/assert.sh"
source "$REPO_ROOT/tests/lib/git-fixtures.sh"

echo "=== test-ticket-benchmark.sh ==="

# ── Helper: create a fresh temp git repo with ticket system initialized ────────
_make_test_repo() {
    local tmp
    tmp=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmp")
    clone_test_repo "$tmp/repo"
    (cd "$tmp/repo" && bash "$TICKET_SCRIPT" init >/dev/null 2>/dev/null) || true
    echo "$tmp/repo"
}

# ── Helper: create a ticket and return its ID ─────────────────────────────────
_create_ticket() {
    local repo="$1"
    local ticket_type="${2:-task}"
    local title="${3:-Test ticket}"
    local out
    out=$(cd "$repo" && bash "$TICKET_SCRIPT" create "$ticket_type" "$title" 2>/dev/null) || true
    echo "$out"
}

# ── Helper: seed N tickets into a test repo ───────────────────────────────────
_seed_tickets() {
    local repo="$1"
    local count="${2:-5}"
    local i
    for (( i = 1; i <= count; i++ )); do
        _create_ticket "$repo" task "Benchmark test ticket $i" >/dev/null
    done
}

# ── Test 1: benchmark exits zero when operations are under threshold ──────────
echo "Test 1: benchmark exits 0 when operations complete under generous threshold"
test_benchmark_exits_zero_under_threshold() {
    _snapshot_fail

    # RED: ticket-benchmark.sh must not exist yet
    if [ ! -f "$BENCHMARK_SCRIPT" ]; then
        assert_eq "ticket-benchmark.sh exists" "exists" "missing"
        assert_pass_if_clean "test_benchmark_exits_zero_under_threshold"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Seed 5 tickets so the benchmark has something to measure
    _seed_tickets "$repo" 5

    local exit_code=0
    (cd "$repo" && bash "$BENCHMARK_SCRIPT" --threshold 30 >/dev/null 2>/dev/null) || exit_code=$?

    # Assert: exits 0 with a generous 30s threshold
    assert_eq "benchmark exits 0 under threshold" "0" "$exit_code"

    assert_pass_if_clean "test_benchmark_exits_zero_under_threshold"
}
test_benchmark_exits_zero_under_threshold

# ── Test 2: benchmark exits non-zero when operations exceed threshold ─────────
echo "Test 2: benchmark exits non-zero when threshold is impossibly low"
test_benchmark_exits_nonzero_over_threshold() {
    _snapshot_fail

    # RED: ticket-benchmark.sh must not exist yet
    if [ ! -f "$BENCHMARK_SCRIPT" ]; then
        assert_eq "ticket-benchmark.sh exists" "exists" "missing"
        assert_pass_if_clean "test_benchmark_exits_nonzero_over_threshold"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Seed a few tickets
    _seed_tickets "$repo" 5

    local exit_code=0
    (cd "$repo" && bash "$BENCHMARK_SCRIPT" --threshold 0.001 >/dev/null 2>/dev/null) || exit_code=$?

    # Assert: exits non-zero with an impossibly low 0.001s threshold
    assert_ne "benchmark exits non-zero over threshold" "0" "$exit_code"

    assert_pass_if_clean "test_benchmark_exits_nonzero_over_threshold"
}
test_benchmark_exits_nonzero_over_threshold

# ── Test 3: benchmark outputs numeric timing information ──────────────────────
echo "Test 3: benchmark stdout contains numeric timing value"
test_benchmark_outputs_timing_info() {
    _snapshot_fail

    # RED: ticket-benchmark.sh must not exist yet
    if [ ! -f "$BENCHMARK_SCRIPT" ]; then
        assert_eq "ticket-benchmark.sh exists" "exists" "missing"
        assert_pass_if_clean "test_benchmark_outputs_timing_info"
        return
    fi

    local repo
    repo=$(_make_test_repo)

    # Seed 5 tickets
    _seed_tickets "$repo" 5

    local output
    local exit_code=0
    output=$(cd "$repo" && bash "$BENCHMARK_SCRIPT" --threshold 30 2>/dev/null) || exit_code=$?

    # Assert: stdout contains at least one numeric value (timing in seconds, e.g., "0.123" or "1.45")
    local has_numeric
    has_numeric=$(echo "$output" | grep -cE '[0-9]+\.[0-9]+' || true)

    assert_ne "benchmark output contains numeric timing" "0" "$has_numeric"

    assert_pass_if_clean "test_benchmark_outputs_timing_info"
}
test_benchmark_outputs_timing_info

print_summary
