#!/usr/bin/env bash
# tests/scripts/test-validate-referential-integrity-integration.sh
# Integration tests verifying that validate.sh wires check-referential-integrity.sh
# and .pre-commit-config.yaml registers the referential-integrity-check hook.
#
# Tests:
#   test_validate_references_check_referential_integrity — validate.sh source contains a call to check-referential-integrity.sh
#   test_precommit_config_has_referential_integrity_hook  — .pre-commit-config.yaml contains referential-integrity-check hook
#   test_example_precommit_config_has_referential_integrity_hook — examples/ mirror contains the hook
#
# Usage: bash tests/scripts/test-validate-referential-integrity-integration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# REVIEW-DEFENSE: These tests verify REGISTRATION of the referential-integrity-check hook — that validate.sh
# wires check-referential-integrity.sh and that both pre-commit config files declare the hook. This is the
# correct scope for integration tests at this layer. End-to-end execution correctness (broken references,
# missing scripts, edge-case skill/agent files) is the responsibility of the dedicated script-level test
# suite: tests/scripts/test-check-referential-integrity.sh. Error-path coverage also lives there.
# Separating registration checks from execution checks keeps each suite fast, orthogonal, and independently
# runnable — grep-based registration verification is an intentional design choice, not a test coverage gap.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

VALIDATE_SH="$DSO_PLUGIN_DIR/scripts/validate.sh"
PRECOMMIT_CONFIG="$PLUGIN_ROOT/.pre-commit-config.yaml"
EXAMPLE_PRECOMMIT_CONFIG="$PLUGIN_ROOT/examples/pre-commit-config.example.yaml"

echo "=== test-validate-referential-integrity-integration.sh ==="

# ── test_validate_references_check_referential_integrity ─────────────────────
# Static contract check: validate.sh must contain a reference to check-referential-integrity.sh.
test_validate_references_check_referential_integrity() {
    _snapshot_fail

    if grep -q 'check-referential-integrity' "$VALIDATE_SH" 2>/dev/null; then
        has_ref="yes"
    else
        has_ref="no"
    fi
    assert_eq "validate.sh references check-referential-integrity.sh" "yes" "$has_ref"

    assert_pass_if_clean "test_validate_references_check_referential_integrity"
}

# ── test_precommit_config_has_referential_integrity_hook ─────────────────────
# .pre-commit-config.yaml must contain a referential-integrity-check hook entry.
test_precommit_config_has_referential_integrity_hook() {
    _snapshot_fail

    if grep -q 'referential-integrity-check' "$PRECOMMIT_CONFIG" 2>/dev/null; then
        has_hook="yes"
    else
        has_hook="no"
    fi
    assert_eq ".pre-commit-config.yaml has referential-integrity-check hook" "yes" "$has_hook"

    assert_pass_if_clean "test_precommit_config_has_referential_integrity_hook"
}

# ── test_example_precommit_config_has_referential_integrity_hook ─────────────
# examples/pre-commit-config.example.yaml must mirror the referential-integrity-check hook.
test_example_precommit_config_has_referential_integrity_hook() {
    _snapshot_fail

    if grep -q 'referential-integrity-check' "$EXAMPLE_PRECOMMIT_CONFIG" 2>/dev/null; then
        has_hook="yes"
    else
        has_hook="no"
    fi
    assert_eq "examples/ has referential-integrity-check hook" "yes" "$has_hook"

    assert_pass_if_clean "test_example_precommit_config_has_referential_integrity_hook"
}

# ── Run all tests ─────────────────────────────────────────────────────────────
test_validate_references_check_referential_integrity
test_precommit_config_has_referential_integrity_hook
test_example_precommit_config_has_referential_integrity_hook

print_summary
