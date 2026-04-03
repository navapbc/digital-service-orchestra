#!/usr/bin/env bash
# tests/skills/test-ui-discover-cache-compat.sh
# Compatibility tests verifying that @playwright/cli output format produces data
# compatible with the existing ui-discover cache format (manifest.json field names).
#
# Test approach: verify the cache-format-reference.md documents all required
# manifest.json field names, and verify that CLI output format documentation
# maps to those cache fields.
#
# Test functions:
#   test_cache_manifest_fields_present  — verify all required manifest.json field names are documented
#   test_cli_output_field_compatibility — verify CLI output format maps to cache fields
#
# Usage: bash tests/skills/test-ui-discover-cache-compat.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
CACHE_FORMAT_DOC="$DSO_PLUGIN_DIR/skills/ui-discover/docs/cache-format-reference.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-ui-discover-cache-compat.sh ==="

# test_cache_manifest_fields_present: verify all required manifest.json field names are documented.
# The manifest.json schema defines required fields: version, generatedAt, gitCommit,
# playwrightUsed, uiFileHashes, entries. Each must appear in cache-format-reference.md
# so that CLI output consumers can find the contract.
test_cache_manifest_fields_present() {
    _snapshot_fail
    local missing_fields=0
    local required_manifest_fields=(
        "version"
        "generatedAt"
        "gitCommit"
        "playwrightUsed"
        "uiFileHashes"
        "entries"
    )
    for field in "${required_manifest_fields[@]}"; do
        if ! grep -q "\"$field\"" "$CACHE_FORMAT_DOC" 2>/dev/null; then
            missing_fields=$((missing_fields + 1))
            echo "  MISSING MANIFEST FIELD: $field" >&2
        fi
    done
    assert_eq "test_cache_manifest_fields_present" "0" "$missing_fields"
    assert_pass_if_clean "test_cache_manifest_fields_present"
}

# test_cli_output_field_compatibility: verify CLI output format maps to cache fields.
# @playwright/cli produces route data (URLs, screenshots, DOM). The cache format must
# document fields that can be populated from CLI output:
#   - playwrightUsed (boolean flag indicating CLI was used)
#   - playwrightCrawled (per-route boolean flag for CLI-crawled routes)
#   - screenshot (path to CLI-captured screenshot)
#   - dom (DOM data captured via CLI)
#   - route (route path captured from CLI navigation)
# All must appear in cache-format-reference.md for CLI output compatibility.
test_cli_output_field_compatibility() {
    _snapshot_fail
    local missing_fields=0
    local cli_output_fields=(
        "playwrightUsed"
        "playwrightCrawled"
        "screenshot"
        "dom"
        "route"
    )
    for field in "${cli_output_fields[@]}"; do
        if ! grep -q "\"$field\"" "$CACHE_FORMAT_DOC" 2>/dev/null; then
            missing_fields=$((missing_fields + 1))
            echo "  MISSING CLI-MAPPED FIELD: $field" >&2
        fi
    done
    assert_eq "test_cli_output_field_compatibility" "0" "$missing_fields"
    assert_pass_if_clean "test_cli_output_field_compatibility"
}

# --- Run all test functions ---
test_cache_manifest_fields_present
test_cli_output_field_compatibility

print_summary
