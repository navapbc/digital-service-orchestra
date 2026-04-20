#!/usr/bin/env bash
# tests/scripts/test-completion-verifier-preconditions.sh
# Structural test: completion-verifier.md contains a Step 1.5 PRECONDITIONS section.
#
# Tests:
#   1. test_completion_verifier_has_preconditions_section — Step 1.5 heading present
#   2. test_completion_verifier_step15_references_read_latest_preconditions — calls _read_latest_preconditions
#
# Usage: bash tests/scripts/test-completion-verifier-preconditions.sh

# NOTE: -e is intentionally omitted — test functions return non-zero by design
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
VERIFIER_MD="$REPO_ROOT/plugins/dso/agents/completion-verifier.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-completion-verifier-preconditions.sh ==="

# ── Test 1: Step 1.5 heading present ─────────────────────────────────────────
echo "Test 1: completion-verifier.md contains Step 1.5 PRECONDITIONS section"
test_completion_verifier_has_preconditions_section() {
    _snapshot_fail
    if [ ! -f "$VERIFIER_MD" ]; then
        assert_eq "completion-verifier.md exists" "exists" "missing"
        return
    fi

    # RED: Step 1.5 heading does not yet exist in completion-verifier.md
    local has_step15="no"
    if grep -qE "Step 1\.5|1\.5.*PRECONDITIONS|PRECONDITIONS.*Step" "$VERIFIER_MD" 2>/dev/null; then
        has_step15="yes"
    fi
    assert_eq "completion-verifier.md contains Step 1.5 PRECONDITIONS section" "yes" "$has_step15"

    assert_pass_if_clean "test_completion_verifier_has_preconditions_section"
}
test_completion_verifier_has_preconditions_section

# ── Test 2: Step 1.5 references _read_latest_preconditions ───────────────────
echo "Test 2: completion-verifier.md Step 1.5 references _read_latest_preconditions"
test_completion_verifier_step15_references_read_latest_preconditions() {
    _snapshot_fail
    if [ ! -f "$VERIFIER_MD" ]; then
        assert_eq "completion-verifier.md exists" "exists" "missing"
        return
    fi

    # RED: _read_latest_preconditions not yet referenced in completion-verifier.md
    local has_fn_ref="no"
    if grep -q "_read_latest_preconditions" "$VERIFIER_MD" 2>/dev/null; then
        has_fn_ref="yes"
    fi
    assert_eq "completion-verifier.md references _read_latest_preconditions" "yes" "$has_fn_ref"

    assert_pass_if_clean "test_completion_verifier_step15_references_read_latest_preconditions"
}
test_completion_verifier_step15_references_read_latest_preconditions

print_summary
