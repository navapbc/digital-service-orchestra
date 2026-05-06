#!/usr/bin/env bash
# tests/scripts/test-red-team-affects-fields-classifier.sh
# RED tests verifying that affects-fields classifier fixtures and validator
# exist with required structure. All tests FAIL until the fixtures are created.
#
# Story: 18b0-7c5d (inference-challenge mode for red-team-reviewer)
# Testing mode: RED (new behavior — fixtures don't exist yet)
#
# Usage: bash tests/scripts/test-red-team-affects-fields-classifier.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

FIXTURE="$REPO_ROOT/tests/fixtures/affects-fields-classifier.json"
VALIDATOR="$REPO_ROOT/tests/scripts/validate-affects-fields-accuracy.sh"

# ---------------------------------------------------------------------------
# test_classifier_fixture_exists
# Expect: tests/fixtures/affects-fields-classifier.json exists
# RED: file does not exist yet
# ---------------------------------------------------------------------------
test_classifier_fixture_exists() {
    if test -f "$FIXTURE"; then
        actual=present
    else
        actual=missing
    fi
    assert_eq "tests/fixtures/affects-fields-classifier.json exists" \
        "present" "$actual"
}

# ---------------------------------------------------------------------------
# test_fixture_has_minimum_examples
# Expect: fixture has at least 100 entries
# RED: file does not exist yet (dependency on test_classifier_fixture_exists)
# ---------------------------------------------------------------------------
test_fixture_has_minimum_examples() {
    if ! test -f "$FIXTURE"; then
        assert_eq "affects-fields-classifier.json has >= 100 entries (file missing)" \
            "present" "missing"
        return
    fi
    local count
    count=$(jq -s 'length' "$FIXTURE" 2>/dev/null || echo 0)
    if [[ "$count" -ge 100 ]]; then
        actual=sufficient
    else
        actual=insufficient
    fi
    assert_eq "affects-fields-classifier.json has >= 100 entries (found: $count)" \
        "sufficient" "$actual"
}

# ---------------------------------------------------------------------------
# test_fixture_has_high_stakes_examples
# Expect: fixture has at least 50 entries with label='high_stakes'
# RED: file does not exist yet
# ---------------------------------------------------------------------------
test_fixture_has_high_stakes_examples() {
    if ! test -f "$FIXTURE"; then
        assert_eq "affects-fields-classifier.json has >= 50 high_stakes examples (file missing)" \
            "present" "missing"
        return
    fi
    local count
    count=$(jq -s '[.[] | select(.label == "high_stakes")] | length' "$FIXTURE" 2>/dev/null || echo 0)
    if [[ "$count" -ge 50 ]]; then
        actual=sufficient
    else
        actual=insufficient
    fi
    assert_eq "affects-fields-classifier.json has >= 50 high_stakes examples (found: $count)" \
        "sufficient" "$actual"
}

# ---------------------------------------------------------------------------
# test_fixture_has_rationale_only_examples
# Expect: fixture has at least 50 entries with label='rationale_only'
# RED: file does not exist yet
# ---------------------------------------------------------------------------
test_fixture_has_rationale_only_examples() {
    if ! test -f "$FIXTURE"; then
        assert_eq "affects-fields-classifier.json has >= 50 rationale_only examples (file missing)" \
            "present" "missing"
        return
    fi
    local count
    count=$(jq -s '[.[] | select(.label == "rationale_only")] | length' "$FIXTURE" 2>/dev/null || echo 0)
    if [[ "$count" -ge 50 ]]; then
        actual=sufficient
    else
        actual=insufficient
    fi
    assert_eq "affects-fields-classifier.json has >= 50 rationale_only examples (found: $count)" \
        "sufficient" "$actual"
}

# ---------------------------------------------------------------------------
# test_fixture_entries_have_required_fields
# Expect: all entries have decision_text, affects_fields, label, source_ticket
# RED: file does not exist yet
# ---------------------------------------------------------------------------
test_fixture_entries_have_required_fields() {
    if ! test -f "$FIXTURE"; then
        assert_eq "affects-fields-classifier.json entries have required fields (file missing)" \
            "present" "missing"
        return
    fi
    local missing_fields_count
    missing_fields_count=$(jq -s '[.[] | select(
        (.decision_text == null) or
        (.affects_fields == null) or
        (.label == null) or
        (.source_ticket == null)
    )] | length' "$FIXTURE" 2>/dev/null || echo 999)
    if [[ "$missing_fields_count" -eq 0 ]]; then
        actual=all_present
    else
        actual=fields_missing
    fi
    assert_eq "all affects-fields-classifier.json entries have required fields (missing: $missing_fields_count)" \
        "all_present" "$actual"
}

# ---------------------------------------------------------------------------
# test_accuracy_validator_exists
# Expect: tests/scripts/validate-affects-fields-accuracy.sh exists
# RED: script does not exist yet
# ---------------------------------------------------------------------------
test_accuracy_validator_exists() {
    if test -f "$VALIDATOR"; then
        actual=present
    else
        actual=missing
    fi
    assert_eq "tests/scripts/validate-affects-fields-accuracy.sh exists" \
        "present" "$actual"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_classifier_fixture_exists
test_fixture_has_minimum_examples
test_fixture_has_high_stakes_examples
test_fixture_has_rationale_only_examples
test_fixture_entries_have_required_fields
test_accuracy_validator_exists

print_summary
