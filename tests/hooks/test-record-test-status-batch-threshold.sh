#!/usr/bin/env bash
# tests/hooks/test-record-test-status-batch-threshold.sh
# Structural test for 1534-d9fb:
#   plugins/dso/skills/preplanning/SKILL.md has too many associated tests vs.
#   the advisory batch_threshold — SIGURG interruption risk during pre-commit gate.
#
# Fix: test_gate.batch_threshold must be explicitly set in dso-config.conf to a
#   value high enough that preplanning/SKILL.md's test count does not exceed it.
#
# Per behavioral testing standard Rule 5 (instruction files): test the structural
# boundary of the config and .test-index files.
#
# Usage: bash tests/hooks/test-record-test-status-batch-threshold.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
CONFIG="$REPO_ROOT/.claude/dso-config.conf"
TEST_INDEX="$REPO_ROOT/.test-index"
PREPLANNING_SRC="plugins/dso/skills/preplanning/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

# ── Prerequisite ─────────────────────────────────────────────────────────────
if [[ ! -f "$CONFIG" ]]; then
    echo "SKIP: dso-config.conf not found at $CONFIG"
    exit 0
fi

if [[ ! -f "$TEST_INDEX" ]]; then
    echo "SKIP: .test-index not found at $TEST_INDEX"
    exit 0
fi

# ============================================================
# test_batch_threshold_configured_explicitly (1534-d9fb)
#
# test_gate.batch_threshold must be explicitly set in dso-config.conf
# so it is documented and intentional (not just the default of 20).
# ============================================================
test_batch_threshold_configured_explicitly() {
    local found=0
    grep -q '^test_gate\.batch_threshold=' "$CONFIG" 2>/dev/null && found=1 || true
    assert_eq "test_gate.batch_threshold is explicitly configured (1534-d9fb)" "1" "$found"
}

# ============================================================
# test_preplanning_test_count_within_threshold (1534-d9fb)
#
# The count of tests associated with preplanning/SKILL.md in .test-index
# must not exceed the advisory batch_threshold. Exceeding the threshold
# triggers an advisory NOTE and indicates SIGURG interruption risk.
# ============================================================
test_preplanning_test_count_within_threshold() {
    # Read batch_threshold from config (default 20 if not set)
    local threshold
    threshold=$(grep '^test_gate\.batch_threshold=' "$CONFIG" 2>/dev/null | cut -d= -f2- || true)
    threshold="${threshold:-20}"

    # Count tests for preplanning/SKILL.md in .test-index
    local count=0
    local line
    line=$(grep "^${PREPLANNING_SRC}:" "$TEST_INDEX" 2>/dev/null || true)
    if [[ -n "$line" ]]; then
        local tests_str="${line#*:}"
        count=$(echo "$tests_str" | tr ',' '\n' | grep -cv '^[[:space:]]*$' || true)
        # Ensure count is numeric (grep -cv can return "0" even with exit 0)
        [[ "$count" =~ ^[0-9]+$ ]] || count=0
    fi

    # Assert count does not exceed threshold
    local within=1
    if [[ "$count" -gt "$threshold" ]] 2>/dev/null; then
        within=0
    fi
    assert_eq "preplanning/SKILL.md test count ($count) ≤ batch_threshold ($threshold) (1534-d9fb)" "1" "$within"
}

# ── Run all tests ────────────────────────────────────────────────────────────
test_batch_threshold_configured_explicitly
test_preplanning_test_count_within_threshold

print_summary
