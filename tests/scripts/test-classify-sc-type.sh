#!/usr/bin/env bash
# tests/scripts/test-classify-sc-type.sh
# Tests for the deterministic SC classifier.
#
# Covers:
#   1. Action verbs → behavioral
#   2. State verbs → structural
#   3. No matching verbs → behavioral (default)
#   4. Mixed verbs → behavioral (action takes precedence)
#   5. Case insensitivity
#   6. Stdin input mode
#   7. Argument input mode

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
CLASSIFIER="$REPO_ROOT/plugins/dso/scripts/classify-sc-type.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-classify-sc-type.sh ==="

echo "Test 1: Action verbs produce behavioral"
test_action_verbs() {
    _snapshot_fail
    local result

    result=$(echo "The system exports rules as Rego format" | bash "$CLASSIFIER")
    assert_eq "exports → behavioral" "behavioral" "$result"

    result=$(echo "The reconciler creates local tickets for inbound mutations" | bash "$CLASSIFIER")
    assert_eq "creates → behavioral" "behavioral" "$result"

    result=$(echo "The API returns a 200 with valid credentials" | bash "$CLASSIFIER")
    assert_eq "returns → behavioral" "behavioral" "$result"

    result=$(echo "The system processes inbound mutations correctly" | bash "$CLASSIFIER")
    assert_eq "processes → behavioral" "behavioral" "$result"

    result=$(echo "The endpoint validates input before persisting" | bash "$CLASSIFIER")
    assert_eq "validates → behavioral" "behavioral" "$result"

    assert_pass_if_clean "test_action_verbs"
}
test_action_verbs

echo "Test 2: State verbs produce structural"
test_state_verbs() {
    _snapshot_fail
    local result

    result=$(echo "The configuration file exists at config/defaults.yaml" | bash "$CLASSIFIER")
    assert_eq "exists → structural" "structural" "$result"

    result=$(echo "The system is configured with OAuth provider settings" | bash "$CLASSIFIER")
    assert_eq "is configured → structural" "structural" "$result"

    result=$(echo "The manifest contains all required fields" | bash "$CLASSIFIER")
    assert_eq "contains → structural" "structural" "$result"

    result=$(echo "The adapter is documented in the API reference" | bash "$CLASSIFIER")
    assert_eq "is documented → structural" "structural" "$result"

    assert_pass_if_clean "test_state_verbs"
}
test_state_verbs

echo "Test 3: No matching verbs default to behavioral"
test_default_behavioral() {
    _snapshot_fail
    local result

    result=$(echo "Something happens with the data" | bash "$CLASSIFIER")
    assert_eq "no match → behavioral" "behavioral" "$result"

    result=$(echo "The feature works end to end" | bash "$CLASSIFIER")
    assert_eq "generic → behavioral" "behavioral" "$result"

    assert_pass_if_clean "test_default_behavioral"
}
test_default_behavioral

echo "Test 4: Mixed verbs — action takes precedence"
test_mixed_verbs() {
    _snapshot_fail
    local result

    result=$(echo "The system creates a configuration file that exists at config/out.yaml" | bash "$CLASSIFIER")
    assert_eq "creates + exists → behavioral" "behavioral" "$result"

    assert_pass_if_clean "test_mixed_verbs"
}
test_mixed_verbs

echo "Test 5: Case insensitivity"
test_case_insensitive() {
    _snapshot_fail
    local result

    result=$(echo "The System CREATES Local Tickets" | bash "$CLASSIFIER")
    assert_eq "uppercase CREATES → behavioral" "behavioral" "$result"

    result=$(echo "The Config File EXISTS" | bash "$CLASSIFIER")
    assert_eq "uppercase EXISTS → structural" "structural" "$result"

    assert_pass_if_clean "test_case_insensitive"
}
test_case_insensitive

echo "Test 6: Stdin input mode"
test_stdin_mode() {
    _snapshot_fail
    local result

    result=$(printf "The endpoint returns JSON" | bash "$CLASSIFIER")
    assert_eq "stdin → behavioral" "behavioral" "$result"

    assert_pass_if_clean "test_stdin_mode"
}
test_stdin_mode

echo "Test 7: Argument input mode"
test_arg_mode() {
    _snapshot_fail
    local result

    result=$(bash "$CLASSIFIER" "The endpoint returns JSON")
    assert_eq "arg → behavioral" "behavioral" "$result"

    assert_pass_if_clean "test_arg_mode"
}
test_arg_mode

echo ""
echo "=== test-classify-sc-type.sh complete ==="
print_summary
