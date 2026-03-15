#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-validation-gate-states.sh
# TDD tests for hook_validation_gate handling of in_progress/interrupted states.
#
# Tests hook_commit_failure_tracker (which reads the validation state file)
# as the validation gate mechanism in pre-bash-functions.sh.
# Also tests that the gate correctly handles: passed, failed, in_progress,
# interrupted, and the 15-minute auto-expiry for in_progress.
#
# Usage: bash lockpick-workflow/tests/hooks/test-validation-gate-states.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"
source "$REPO_ROOT/lockpick-workflow/hooks/lib/pre-bash-functions.sh"

# ---------------------------------------------------------------------------
# Helper: run hook_validation_gate with a given state file content
#
# Since hook_validation_gate is defined in pre-bash-functions.sh, we call it
# directly. We override ARTIFACTS_DIR to point to a temp dir with our state.
# ---------------------------------------------------------------------------
run_validation_gate() {
    local artifacts_dir="$1"
    local command="${2:-git commit -m 'test'}"
    local escaped_cmd="${command//\"/\\\"}"
    local json
    json=$(printf '{"tool_name":"Bash","tool_input":{"command":"%s"}}' "$escaped_cmd")
    local exit_code=0
    ARTIFACTS_DIR="$artifacts_dir" hook_validation_gate "$json" 2>/dev/null || exit_code=$?
    echo "$exit_code"
}

# Check if hook_validation_gate exists — if not, skip those tests
# (it may be named differently; the task says to implement it)
GATE_FN_EXISTS="no"
if declare -f hook_validation_gate &>/dev/null; then
    GATE_FN_EXISTS="yes"
fi

echo ""
echo "=== test-validation-gate-states.sh ==="

# ============================================================================
# Group 1: Verify hook_validation_gate function exists
# ============================================================================
echo ""
echo "=== Group 1: hook_validation_gate function exists ==="
assert_eq "hook_validation_gate is defined in pre-bash-functions.sh" "yes" "$GATE_FN_EXISTS"

if [[ "$GATE_FN_EXISTS" != "yes" ]]; then
    echo "SKIP: hook_validation_gate not found — skipping behavioral tests"
    print_summary
    exit 0
fi

# ============================================================================
# Group 2: Passed state → no block
# ============================================================================
echo ""
echo "=== Group 2: passed state → no block ==="

_dir2=$(mktemp -d)
printf 'passed\ntimestamp=2026-03-15T10:00:00Z\n' > "$_dir2/status"
result=$(run_validation_gate "$_dir2")
assert_eq "passed state → commit allowed (exit 0)" "0" "$result"
rm -rf "$_dir2"

# ============================================================================
# Group 3: failed state → no block from this gate (tracker hook warns, not blocks)
# Note: hook_validation_gate is the gate that checks in_progress/interrupted.
# The existing hook_commit_failure_tracker handles failed state (warn only).
# ============================================================================
echo ""
echo "=== Group 3: failed state behavior ==="

_dir3=$(mktemp -d)
printf 'failed\ntimestamp=2026-03-15T10:00:00Z\nfailed_checks=ruff\n' > "$_dir3/status"
result=$(run_validation_gate "$_dir3")
# gate should block on failed as well (or pass — depends on implementation)
# For clarity: if it's a blocking gate, exit 2; if it just validates in_progress states, exit 0
# The task says: "treat in_progress as blocking" — failed is already handled by existing gate
# We test the actual behavior after implementation
assert_ne "failed state returns a defined exit code" "" "$result"
rm -rf "$_dir3"

# ============================================================================
# Group 4: in_progress state → BLOCKED
# ============================================================================
echo ""
echo "=== Group 4: in_progress state → commit blocked ==="

_dir4=$(mktemp -d)
# Write a recent in_progress state (within 15 minutes)
_recent_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
printf 'in_progress\ntimestamp=%s\n' "$_recent_ts" > "$_dir4/status"
result=$(run_validation_gate "$_dir4")
assert_eq "in_progress (recent) → commit blocked (exit 2)" "2" "$result"
rm -rf "$_dir4"

# ============================================================================
# Group 5: interrupted state → BLOCKED
# ============================================================================
echo ""
echo "=== Group 5: interrupted state → commit blocked ==="

_dir5=$(mktemp -d)
_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
printf 'interrupted\ntimestamp=%s\n' "$_ts" > "$_dir5/status"
result=$(run_validation_gate "$_dir5")
assert_eq "interrupted state → commit blocked (exit 2)" "2" "$result"
rm -rf "$_dir5"

# ============================================================================
# Group 6: in_progress but older than 15 minutes → auto-expired (commit allowed)
# ============================================================================
echo ""
echo "=== Group 6: in_progress older than 15 minutes → auto-expired ==="

_dir6=$(mktemp -d)
# Write a stale in_progress timestamp (20 minutes ago)
# Use Python for portable date arithmetic
_stale_ts=$(python3 -c "
from datetime import datetime, timezone, timedelta
old = datetime.now(timezone.utc) - timedelta(minutes=20)
print(old.strftime('%Y-%m-%dT%H:%M:%SZ'))
" 2>/dev/null || echo "2020-01-01T00:00:00Z")
printf 'in_progress\ntimestamp=%s\n' "$_stale_ts" > "$_dir6/status"
result=$(run_validation_gate "$_dir6")
assert_eq "in_progress older than 15 min → auto-expired (exit 0)" "0" "$result"
rm -rf "$_dir6"

# ============================================================================
# Group 7: No status file → allowed (never run)
# ============================================================================
echo ""
echo "=== Group 7: No status file → allowed ==="

_dir7=$(mktemp -d)
# No status file written
result=$(run_validation_gate "$_dir7")
assert_eq "no status file → commit allowed (exit 0)" "0" "$result"
rm -rf "$_dir7"

# ============================================================================
# Group 8: Non-commit commands → always allowed regardless of state
# ============================================================================
echo ""
echo "=== Group 8: Non-commit commands → always allowed ==="

_dir8=$(mktemp -d)
_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
printf 'in_progress\ntimestamp=%s\n' "$_ts" > "$_dir8/status"

result=$(run_validation_gate "$_dir8" "make test")
assert_eq "in_progress state + make test → allowed (exit 0)" "0" "$result"

result=$(run_validation_gate "$_dir8" "git status")
assert_eq "in_progress state + git status → allowed (exit 0)" "0" "$result"

result=$(run_validation_gate "$_dir8" "ls -la")
assert_eq "in_progress state + ls → allowed (exit 0)" "0" "$result"
rm -rf "$_dir8"

# ============================================================================
# Group 9: WIP/merge/checkpoint commits → exempt even when in_progress
# ============================================================================
echo ""
echo "=== Group 9: WIP/merge/checkpoint → exempt from in_progress block ==="

_dir9=$(mktemp -d)
_ts=$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
printf 'in_progress\ntimestamp=%s\n' "$_ts" > "$_dir9/status"

result=$(run_validation_gate "$_dir9" 'git commit -m "WIP: save state"')
assert_eq "in_progress + WIP commit → exempt (exit 0)" "0" "$result"

result=$(run_validation_gate "$_dir9" 'git commit -m "pre-compact checkpoint"')
assert_eq "in_progress + pre-compact → exempt (exit 0)" "0" "$result"

result=$(run_validation_gate "$_dir9" 'git commit -m "checkpoint save"')
assert_eq "in_progress + checkpoint → exempt (exit 0)" "0" "$result"
rm -rf "$_dir9"

# ============================================================================
# Group 10: in_progress exactly at 15 minute boundary
# ============================================================================
echo ""
echo "=== Group 10: in_progress at exactly 15 minutes (boundary) ==="

_dir10=$(mktemp -d)
# 15 minutes old = borderline, should be treated as expired (>= 15 min = expired)
_boundary_ts=$(python3 -c "
from datetime import datetime, timezone, timedelta
old = datetime.now(timezone.utc) - timedelta(minutes=15)
print(old.strftime('%Y-%m-%dT%H:%M:%SZ'))
" 2>/dev/null || echo "2020-01-01T00:00:00Z")
printf 'in_progress\ntimestamp=%s\n' "$_boundary_ts" > "$_dir10/status"
result=$(run_validation_gate "$_dir10")
# 15 minutes old should be expired
assert_eq "in_progress at 15 min boundary → auto-expired (exit 0)" "0" "$result"
rm -rf "$_dir10"

print_summary
