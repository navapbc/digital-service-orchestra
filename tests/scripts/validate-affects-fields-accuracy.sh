#!/usr/bin/env bash
# tests/scripts/validate-affects-fields-accuracy.sh
# Structural validation for tests/fixtures/affects-fields-classifier.json.
# Checks that all entries have required fields and labels are valid values.
# Accuracy is structural — no ML-based scoring.
#
# Story: 18b0-7c5d (inference-challenge mode for red-team-reviewer)
#
# Usage: bash tests/scripts/validate-affects-fields-accuracy.sh [path-to-fixture]
# Exit 0: all structural checks pass
# Exit 1: one or more structural checks failed

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

FIXTURE="${1:-$REPO_ROOT/tests/fixtures/affects-fields-classifier.json}"

REQUIRED_FIELDS=(decision_text affects_fields label source_ticket)
VALID_LABELS=(high_stakes rationale_only)

errors=0

# --- Check fixture file exists ---
if [[ ! -f "$FIXTURE" ]]; then
    printf "[FAIL] Fixture file not found: %s\n" "$FIXTURE" >&2
    exit 1
fi

# --- Check it is valid JSON ---
if ! jq empty "$FIXTURE" 2>/dev/null; then
    printf "[FAIL] Fixture is not valid JSON: %s\n" "$FIXTURE" >&2
    exit 1
fi

# --- Check minimum entry count ---
total=$(jq -s 'length' "$FIXTURE" 2>/dev/null || echo 0)
if [[ "$total" -lt 100 ]]; then
    printf "[FAIL] Fixture has %d entries; need >= 100\n" "$total" >&2
    (( errors++ )) || true
else
    printf "[PASS] Entry count: %d\n" "$total"
fi

# --- Check required fields present on every entry ---
missing_fields_count=$(jq -s '[.[] | select(
    (.decision_text == null) or
    (.affects_fields == null) or
    (.label == null) or
    (.source_ticket == null)
)] | length' "$FIXTURE" 2>/dev/null || echo 999)

if [[ "$missing_fields_count" -ne 0 ]]; then
    printf "[FAIL] %d entries are missing one or more required fields (decision_text, affects_fields, label, source_ticket)\n" \
        "$missing_fields_count" >&2
    (( errors++ )) || true
else
    printf "[PASS] All entries have required fields\n"
fi

# --- Check affects_fields is always an array ---
non_array_count=$(jq -s '[.[] | select(.affects_fields | type != "array")] | length' \
    "$FIXTURE" 2>/dev/null || echo 999)
if [[ "$non_array_count" -ne 0 ]]; then
    printf "[FAIL] %d entries have non-array affects_fields\n" "$non_array_count" >&2
    (( errors++ )) || true
else
    printf "[PASS] All affects_fields values are arrays\n"
fi

# --- Check labels are only high_stakes or rationale_only ---
invalid_label_count=$(jq -s '[.[] | select(.label != "high_stakes" and .label != "rationale_only")] | length' \
    "$FIXTURE" 2>/dev/null || echo 999)
if [[ "$invalid_label_count" -ne 0 ]]; then
    printf "[FAIL] %d entries have invalid label values (must be high_stakes or rationale_only)\n" \
        "$invalid_label_count" >&2
    (( errors++ )) || true
else
    printf "[PASS] All label values are valid\n"
fi

# --- Check high_stakes count ---
hs_count=$(jq -s '[.[] | select(.label == "high_stakes")] | length' "$FIXTURE" 2>/dev/null || echo 0)
if [[ "$hs_count" -lt 50 ]]; then
    printf "[FAIL] Only %d high_stakes entries; need >= 50\n" "$hs_count" >&2
    (( errors++ )) || true
else
    printf "[PASS] high_stakes count: %d\n" "$hs_count"
fi

# --- Check rationale_only count ---
ro_count=$(jq -s '[.[] | select(.label == "rationale_only")] | length' "$FIXTURE" 2>/dev/null || echo 0)
if [[ "$ro_count" -lt 50 ]]; then
    printf "[FAIL] Only %d rationale_only entries; need >= 50\n" "$ro_count" >&2
    (( errors++ )) || true
else
    printf "[PASS] rationale_only count: %d\n" "$ro_count"
fi

# --- Summary ---
if [[ "$errors" -gt 0 ]]; then
    printf "\nvalidate-affects-fields-accuracy: FAILED (%d error(s))\n" "$errors" >&2
    exit 1
fi

printf "\nvalidate-affects-fields-accuracy: PASSED\n"
exit 0
