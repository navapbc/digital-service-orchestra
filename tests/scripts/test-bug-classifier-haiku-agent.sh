#!/usr/bin/env bash
# tests/scripts/test-bug-classifier-haiku-agent.sh
# Content validation for plugins/dso/agents/bug-classifier-haiku.md.
#
# Tests:
#   1. File exists and is non-empty
#   2. Output contract: file contains the word 'uncategorized' (fallback return value)
#   3. Dispatch inputs: file contains 'registry' or 'slug list'
#   4. Partial match rule: file contains 'partial match is not a match' (verbatim)
#   5. Fallback statement: file mentions returning 'uncategorized' when no slug fits
#
# Usage: bash tests/scripts/test-bug-classifier-haiku-agent.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-bug-classifier-haiku-agent.sh ==="

AGENT_FILE="$REPO_ROOT/plugins/dso/agents/bug-classifier-haiku.md"

# ── test_file_exists ──────────────────────────────────────────────────────────
test_file_exists() {
    local actual
    if [ -f "$AGENT_FILE" ] && [ -s "$AGENT_FILE" ]; then
        actual="exists_nonempty"
    elif [ -f "$AGENT_FILE" ]; then
        actual="exists_empty"
    else
        actual="missing"
    fi
    assert_eq "test_file_exists: file exists and is non-empty" "exists_nonempty" "$actual"
}

# ── test_output_contract_uncategorized ────────────────────────────────────────
test_output_contract_uncategorized() {
    if [ ! -f "$AGENT_FILE" ]; then
        assert_eq "test_output_contract_uncategorized: agent file must exist" "exists" "missing"
        return
    fi
    local actual
    if grep -q "uncategorized" "$AGENT_FILE"; then
        actual="found"
    else
        actual="not_found"
    fi
    assert_eq "test_output_contract_uncategorized: file contains 'uncategorized'" "found" "$actual"
}

# ── test_dispatch_inputs ──────────────────────────────────────────────────────
test_dispatch_inputs() {
    if [ ! -f "$AGENT_FILE" ]; then
        assert_eq "test_dispatch_inputs: agent file must exist" "exists" "missing"
        return
    fi
    local actual
    if grep -qE "registry|slug list" "$AGENT_FILE"; then
        actual="found"
    else
        actual="not_found"
    fi
    assert_eq "test_dispatch_inputs: file contains 'registry' or 'slug list'" "found" "$actual"
}

# ── test_partial_match_rule ───────────────────────────────────────────────────
test_partial_match_rule() {
    if [ ! -f "$AGENT_FILE" ]; then
        assert_eq "test_partial_match_rule: agent file must exist" "exists" "missing"
        return
    fi
    local actual
    if grep -q "partial match is not a match" "$AGENT_FILE"; then
        actual="found"
    else
        actual="not_found"
    fi
    assert_eq "test_partial_match_rule: file contains 'partial match is not a match'" "found" "$actual"
}

# ── test_fallback_statement ───────────────────────────────────────────────────
test_fallback_statement() {
    if [ ! -f "$AGENT_FILE" ]; then
        assert_eq "test_fallback_statement: agent file must exist" "exists" "missing"
        return
    fi
    local actual
    # Look for a statement connecting 'uncategorized' with the concept of no matching slug
    if grep -q "uncategorized" "$AGENT_FILE" && grep -qE "no slug|no match|does not match|none.*match|no.*fit|fit.*none" "$AGENT_FILE"; then
        actual="found"
    else
        actual="not_found"
    fi
    assert_eq "test_fallback_statement: file mentions returning 'uncategorized' when no slug fits" "found" "$actual"
}

# ── run all tests ─────────────────────────────────────────────────────────────
test_file_exists
test_output_contract_uncategorized
test_dispatch_inputs
test_partial_match_rule
test_fallback_statement

print_summary
