#!/usr/bin/env bash
# RED test: structural boundary for docs/designs/stage-boundary-preconditions/
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
source "$REPO_ROOT/tests/lib/assert.sh"
echo "=== test-stage-boundary-preconditions-doc-structure.sh ==="

DOCS_DIR="$REPO_ROOT/docs/designs/stage-boundary-preconditions"

test_schema_reference_exists() {
    local file="$DOCS_DIR/schema-reference.md"
    if [ -f "$file" ]; then
        # Check for required sections
        local has_schema
        has_schema=$(grep -ic "schema_version\|manifest_depth\|PRECONDITIONS" "$file" || true)
        assert_eq "schema-reference.md has schema fields" "1" "$([ "$has_schema" -gt 0 ] && echo 1 || echo 0)"
    else
        assert_eq "schema-reference.md exists" "exists" "missing"
    fi
}

test_validator_guide_exists() {
    local file="$DOCS_DIR/validator-guide.md"
    if [ -f "$file" ]; then
        local has_validator
        has_validator=$(grep -ic "preconditions-validator\|entry.*check\|exit.*write" "$file" || true)
        assert_eq "validator-guide.md has validator references" "1" "$([ "$has_validator" -gt 0 ] && echo 1 || echo 0)"
    else
        assert_eq "validator-guide.md exists" "exists" "missing"
    fi
}

test_consumer_guide_exists() {
    local file="$DOCS_DIR/consumer-guide.md"
    if [ -f "$file" ]; then
        assert_eq "consumer-guide.md is non-empty" "1" "$([ -s "$file" ] && echo 1 || echo 0)"
    else
        assert_eq "consumer-guide.md exists" "exists" "missing"
    fi
}

test_ops_runbook_exists() {
    local file="$DOCS_DIR/ops-runbook.md"
    if [ -f "$file" ]; then
        local has_ops
        has_ops=$(grep -ic "fallback\|troubleshoot\|runbook\|monitor" "$file" || true)
        assert_eq "ops-runbook.md has ops content" "1" "$([ "$has_ops" -gt 0 ] && echo 1 || echo 0)"
    else
        assert_eq "ops-runbook.md exists" "exists" "missing"
    fi
}

test_contracts_index_exists() {
    local file="$DOCS_DIR/contracts-index.md"
    if [ -f "$file" ]; then
        local has_contract
        has_contract=$(grep -ic "preconditions-schema\|coverage-harness\|fp-auto-fallback" "$file" || true)
        assert_eq "contracts-index.md references contracts" "1" "$([ "$has_contract" -gt 0 ] && echo 1 || echo 0)"
    else
        assert_eq "contracts-index.md exists" "exists" "missing"
    fi
}

test_schema_reference_exists
test_validator_guide_exists
test_consumer_guide_exists
test_ops_runbook_exists
test_contracts_index_exists
print_summary
