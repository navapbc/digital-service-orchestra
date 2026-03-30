#!/usr/bin/env bash
# tests/scripts/test-known-issues-template.sh
# Verifies that plugins/dso/docs/templates/KNOWN-ISSUES.md exists and
# contains the required structural elements: placeholder incidents,
# incident format fields, adaptation guidance, search tips, and
# an incident entry format guide.
#
# Usage:
#   bash tests/scripts/test-known-issues-template.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# REVIEW-DEFENSE: This path references a file that does not yet exist — this is an intentional
# RED test in the TDD workflow. The template at plugins/dso/docs/templates/KNOWN-ISSUES.md will
# be created by task 6a8b-ecf3 in the next sprint batch. Tests below are expected to fail (RED)
# until that task completes and the file is created.
TEMPLATE="$PLUGIN_ROOT/plugins/dso/docs/templates/KNOWN-ISSUES.md"

echo "=== test-known-issues-template.sh ==="

test_template_file_exists() {
    if [[ -f "$TEMPLATE" ]]; then
        assert_eq "test_template_file_exists" "exists" "exists"
    else
        assert_eq "test_template_file_exists" "exists" "missing"
    fi
}

test_template_has_placeholder_incidents() {
    local count
    count=$(grep -c '^### INC-' "$TEMPLATE" 2>/dev/null || echo "0")
    if [[ "$count" -ge 3 ]]; then
        assert_eq "test_template_has_placeholder_incidents" "found" "found"
    else
        assert_eq "test_template_has_placeholder_incidents" "found" "missing_or_insufficient (found: $count)"
    fi
}

test_template_has_incident_format_fields() {
    local missing_fields=()
    for field in "Keywords" "Symptom" "Root cause" "Detection" "Fix"; do
        if ! grep -qi "$field" "$TEMPLATE" 2>/dev/null; then
            missing_fields+=("$field")
        fi
    done
    if [[ "${#missing_fields[@]}" -eq 0 ]]; then
        assert_eq "test_template_has_incident_format_fields" "found" "found"
    else
        assert_eq "test_template_has_incident_format_fields" "found" "missing fields: ${missing_fields[*]}"
    fi
}

test_template_has_adaptation_guidance() {
    if grep -qi 'adaptation guidance\|Adaptation Guidance' "$TEMPLATE" 2>/dev/null; then
        assert_eq "test_template_has_adaptation_guidance" "found" "found"
    else
        assert_eq "test_template_has_adaptation_guidance" "found" "missing"
    fi
}

test_template_has_search_tips() {
    if grep -qi 'search tips\|Search Tips' "$TEMPLATE" 2>/dev/null; then
        assert_eq "test_template_has_search_tips" "found" "found"
    else
        assert_eq "test_template_has_search_tips" "found" "missing"
    fi
}

test_template_has_incident_format_guide() {
    # Template should contain a format guide block showing how to write an incident entry
    if grep -qi 'incident entry\|entry format\|format guide\|## Incident Format\|Incident Format' "$TEMPLATE" 2>/dev/null; then
        assert_eq "test_template_has_incident_format_guide" "found" "found"
    else
        assert_eq "test_template_has_incident_format_guide" "found" "missing"
    fi
}

test_template_file_exists
test_template_has_placeholder_incidents
test_template_has_incident_format_fields
test_template_has_adaptation_guidance
test_template_has_search_tips
test_template_has_incident_format_guide

print_summary
