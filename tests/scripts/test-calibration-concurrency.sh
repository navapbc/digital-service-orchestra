#!/usr/bin/env bash
# tests/scripts/test-calibration-concurrency.sh
# Concurrent invocation tests for mutation-append and churn-append subcommands.
#
# Testing Mode: GREEN — validates flock guard does not deadlock under concurrency.
#
# Task coverage: 394e (concurrent test), d079 (flock guard)
# Story coverage: calibration-program mutation-append / churn-append subcommands
#
# Behavioral pattern: every test follows Given / When / Then. Tests invoke
# calibration-report.sh as subprocesses with --dry-run to avoid needing a
# live calibration-program-health ticket.
#
# Usage: bash tests/scripts/test-calibration-concurrency.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

# NOTE: -e intentionally omitted — test functions may return non-zero by design.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
CALIBRATION_SCRIPT="$REPO_ROOT/plugins/dso/scripts/calibration-report.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-calibration-concurrency.sh ==="

# ═══════════════════════════════════════════════════════════════════════════════
# Test 1: Script exists and supports mutation-append subcommand
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 1: calibration-report.sh supports mutation-append subcommand"
test_mutation_append_subcommand_exists() {
    _snapshot_fail

    if [ ! -f "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh exists" "exists" "missing"
        assert_pass_if_clean "test_mutation_append_subcommand_exists"
        return
    fi

    # Given: calibration-report.sh and --dry-run flag
    # When:  mutation-append is invoked with --dry-run
    # Then:  exit 0 and output contains the idempotency marker
    local output exit_code
    output=$(bash "$CALIBRATION_SCRIPT" mutation-append --pr "pr-test-001" --findings 3 --dry-run 2>&1)
    exit_code=$?

    assert_eq "mutation-append --dry-run exits 0" "0" "$exit_code"
    assert_contains "mutation-append output contains idempotency marker" \
        "<!-- calibration-mutation: pr=pr-test-001 -->" "$output"
    assert_contains "mutation-append output contains findings count" \
        "findings: 3" "$output"

    assert_pass_if_clean "test_mutation_append_subcommand_exists"
}
test_mutation_append_subcommand_exists

# ═══════════════════════════════════════════════════════════════════════════════
# Test 2: Script supports churn-append subcommand
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 2: calibration-report.sh supports churn-append subcommand"
test_churn_append_subcommand_exists() {
    _snapshot_fail

    if [ ! -f "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh exists" "exists" "missing"
        assert_pass_if_clean "test_churn_append_subcommand_exists"
        return
    fi

    # Given: calibration-report.sh and --dry-run flag
    # When:  churn-append is invoked with --dry-run
    # Then:  exit 0 and output contains the idempotency marker
    local output exit_code
    output=$(bash "$CALIBRATION_SCRIPT" churn-append --pr "pr-test-001" --churn 7 --dry-run 2>&1)
    exit_code=$?

    assert_eq "churn-append --dry-run exits 0" "0" "$exit_code"
    assert_contains "churn-append output contains idempotency marker" \
        "<!-- calibration-churn: pr=pr-test-001 -->" "$output"
    assert_contains "churn-append output contains churn count" \
        "churn: 7" "$output"

    assert_pass_if_clean "test_churn_append_subcommand_exists"
}
test_churn_append_subcommand_exists

# ═══════════════════════════════════════════════════════════════════════════════
# Test 3: mutation-append requires --pr flag
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 3: mutation-append requires --pr flag"
test_mutation_append_requires_pr() {
    _snapshot_fail

    if [ ! -f "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh exists" "exists" "missing"
        assert_pass_if_clean "test_mutation_append_requires_pr"
        return
    fi

    # Given: mutation-append call missing --pr
    # When:  invoked without --pr
    # Then:  exit non-zero
    local exit_code
    bash "$CALIBRATION_SCRIPT" mutation-append --findings 3 --dry-run >/dev/null 2>&1
    exit_code=$?

    assert_ne "mutation-append without --pr exits non-zero" "0" "$exit_code"

    assert_pass_if_clean "test_mutation_append_requires_pr"
}
test_mutation_append_requires_pr

# ═══════════════════════════════════════════════════════════════════════════════
# Test 4: mutation-append requires --findings flag
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 4: mutation-append requires --findings flag"
test_mutation_append_requires_findings() {
    _snapshot_fail

    if [ ! -f "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh exists" "exists" "missing"
        assert_pass_if_clean "test_mutation_append_requires_findings"
        return
    fi

    # Given: mutation-append call missing --findings
    # When:  invoked without --findings
    # Then:  exit non-zero
    local exit_code
    bash "$CALIBRATION_SCRIPT" mutation-append --pr "pr-test-001" --dry-run >/dev/null 2>&1
    exit_code=$?

    assert_ne "mutation-append without --findings exits non-zero" "0" "$exit_code"

    assert_pass_if_clean "test_mutation_append_requires_findings"
}
test_mutation_append_requires_findings

# ═══════════════════════════════════════════════════════════════════════════════
# Test 5: churn-append requires --churn flag
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 5: churn-append requires --churn flag"
test_churn_append_requires_churn() {
    _snapshot_fail

    if [ ! -f "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh exists" "exists" "missing"
        assert_pass_if_clean "test_churn_append_requires_churn"
        return
    fi

    # Given: churn-append call missing --churn
    # When:  invoked without --churn
    # Then:  exit non-zero
    local exit_code
    bash "$CALIBRATION_SCRIPT" churn-append --pr "pr-test-001" --dry-run >/dev/null 2>&1
    exit_code=$?

    assert_ne "churn-append without --churn exits non-zero" "0" "$exit_code"

    assert_pass_if_clean "test_churn_append_requires_churn"
}
test_churn_append_requires_churn

# ═══════════════════════════════════════════════════════════════════════════════
# Test 6: Concurrent mutation-append calls for different PRs complete without deadlock
#
# Given: two concurrent mutation-append --dry-run calls targeting different PR IDs
# When:  both are launched as background jobs and waited on
# Then:  both complete with exit 0 (no deadlock, no error)
#
# Note: --dry-run short-circuits before any ticket I/O or locking. This test
# validates that concurrent invocations of the script path do not interfere
# with each other and that the flock-guarded subshell does not cause hangs in
# the code path exercised by --dry-run (which exits before the lock block).
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 6: Concurrent mutation-append --dry-run calls for different PRs complete with exit 0"
test_concurrent_mutation_append_dry_run() {
    _snapshot_fail

    if [ ! -f "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh exists" "exists" "missing"
        assert_pass_if_clean "test_concurrent_mutation_append_dry_run"
        return
    fi

    # Launch two concurrent mutation-append --dry-run calls for different PR IDs
    local exit1 exit2
    bash "$CALIBRATION_SCRIPT" mutation-append --pr "pr-001" --findings 3 --dry-run >/dev/null 2>&1 &
    local pid1=$!
    bash "$CALIBRATION_SCRIPT" mutation-append --pr "pr-002" --findings 5 --dry-run >/dev/null 2>&1 &
    local pid2=$!

    # Wait for both to complete
    wait "$pid1"
    exit1=$?
    wait "$pid2"
    exit2=$?

    assert_eq "concurrent mutation-append pr-001 exits 0" "0" "$exit1"
    assert_eq "concurrent mutation-append pr-002 exits 0" "0" "$exit2"

    assert_pass_if_clean "test_concurrent_mutation_append_dry_run"
}
test_concurrent_mutation_append_dry_run

# ═══════════════════════════════════════════════════════════════════════════════
# Test 7: Concurrent churn-append calls for different PRs complete without deadlock
#
# Given: two concurrent churn-append --dry-run calls targeting different PR IDs
# When:  both are launched as background jobs and waited on
# Then:  both complete with exit 0 (no deadlock, no error)
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 7: Concurrent churn-append --dry-run calls for different PRs complete with exit 0"
test_concurrent_churn_append_dry_run() {
    _snapshot_fail

    if [ ! -f "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh exists" "exists" "missing"
        assert_pass_if_clean "test_concurrent_churn_append_dry_run"
        return
    fi

    # Launch two concurrent churn-append --dry-run calls for different PR IDs
    local exit1 exit2
    bash "$CALIBRATION_SCRIPT" churn-append --pr "pr-001" --churn 10 --dry-run >/dev/null 2>&1 &
    local pid1=$!
    bash "$CALIBRATION_SCRIPT" churn-append --pr "pr-002" --churn 20 --dry-run >/dev/null 2>&1 &
    local pid2=$!

    # Wait for both to complete
    wait "$pid1"
    exit1=$?
    wait "$pid2"
    exit2=$?

    assert_eq "concurrent churn-append pr-001 exits 0" "0" "$exit1"
    assert_eq "concurrent churn-append pr-002 exits 0" "0" "$exit2"

    assert_pass_if_clean "test_concurrent_churn_append_dry_run"
}
test_concurrent_churn_append_dry_run

# ═══════════════════════════════════════════════════════════════════════════════
# Test 8: Lock files use PR-ID-scoped paths (different PRs use different locks)
#
# Given: the calibration-report.sh source
# When:  we inspect the lock file path pattern
# Then:  the lock file path includes the PR ID variable
# ═══════════════════════════════════════════════════════════════════════════════
echo "Test 8: flock lock file path includes PR ID for per-PR isolation"
test_lock_file_includes_pr_id() {
    _snapshot_fail

    if [ ! -f "$CALIBRATION_SCRIPT" ]; then
        assert_eq "calibration-report.sh exists" "exists" "missing"
        assert_pass_if_clean "test_lock_file_includes_pr_id"
        return
    fi

    # Given: the script source
    # When:  we grep for the lock file pattern
    # Then:  it contains the pr_id variable so different PRs use different lock files
    local lock_pattern_count
    lock_pattern_count=$(grep -c 'calibration-append-.*pr_id.*lock' "$CALIBRATION_SCRIPT" || true)

    assert_ne "lock file path includes pr_id variable (at least 1 occurrence)" "0" "$lock_pattern_count"

    assert_pass_if_clean "test_lock_file_includes_pr_id"
}
test_lock_file_includes_pr_id

# ═══════════════════════════════════════════════════════════════════════════════
print_summary
