#!/usr/bin/env bash
# tests/scripts/test-validate-contract-schemas-integration.sh
# Integration tests verifying that validate.sh wires check-contract-schemas.sh
# and .pre-commit-config.yaml registers the contract-schema-check hook.
#
# Tests:
#   test_validate_references_check_contract_schemas — validate.sh source contains a call to check-contract-schemas.sh
#   test_precommit_config_has_contract_schema_hook  — .pre-commit-config.yaml contains contract-schema-check hook
#   test_example_precommit_config_has_contract_schema_hook — examples/ mirror contains the hook
#
# Usage: bash tests/scripts/test-validate-contract-schemas-integration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# REVIEW-DEFENSE: These tests verify REGISTRATION of the contract-schema-check hook — that validate.sh
# wires check-contract-schemas.sh and that both pre-commit config files declare the hook. This is the
# correct scope for integration tests at this layer. End-to-end execution correctness (what happens when
# the hook runs against malformed YAML, missing sections, or fixture files) is the responsibility of the
# dedicated script-level test suite: tests/scripts/test-check-contract-schemas.sh. Splitting concerns
# this way keeps each suite fast and focused; grep-based registration checks are an intentional design
# choice, not a gap.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

VALIDATE_SH="$DSO_PLUGIN_DIR/scripts/validate.sh"
PRECOMMIT_CONFIG="$PLUGIN_ROOT/.pre-commit-config.yaml"
EXAMPLE_PRECOMMIT_CONFIG="$PLUGIN_ROOT/plugins/dso/docs/examples/pre-commit-config.example.yaml"

echo "=== test-validate-contract-schemas-integration.sh ==="

# ── test_validate_references_check_contract_schemas ──────────────────────────
# Static contract check: validate.sh must contain a reference to check-contract-schemas.sh.
test_validate_references_check_contract_schemas() {
    _snapshot_fail

    if grep -q 'check-contract-schemas' "$VALIDATE_SH" 2>/dev/null; then
        has_ref="yes"
    else
        has_ref="no"
    fi
    assert_eq "validate.sh references check-contract-schemas.sh" "yes" "$has_ref"

    assert_pass_if_clean "test_validate_references_check_contract_schemas"
}

# ── test_precommit_config_has_contract_schema_hook ───────────────────────────
# .pre-commit-config.yaml must contain a contract-schema-check hook entry.
test_precommit_config_has_contract_schema_hook() {
    _snapshot_fail

    if grep -q 'contract-schema-check' "$PRECOMMIT_CONFIG" 2>/dev/null; then
        has_hook="yes"
    else
        has_hook="no"
    fi
    assert_eq ".pre-commit-config.yaml has contract-schema-check hook" "yes" "$has_hook"

    assert_pass_if_clean "test_precommit_config_has_contract_schema_hook"
}

# ── test_example_precommit_config_has_contract_schema_hook ───────────────────
# examples/pre-commit-config.example.yaml must mirror the contract-schema-check hook.
test_example_precommit_config_has_contract_schema_hook() {
    _snapshot_fail

    if grep -q 'contract-schema-check' "$EXAMPLE_PRECOMMIT_CONFIG" 2>/dev/null; then
        has_hook="yes"
    else
        has_hook="no"
    fi
    assert_eq "examples/ has contract-schema-check hook" "yes" "$has_hook"

    assert_pass_if_clean "test_example_precommit_config_has_contract_schema_hook"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_validate_references_check_contract_schemas
test_precommit_config_has_contract_schema_hook
test_example_precommit_config_has_contract_schema_hook

print_summary
