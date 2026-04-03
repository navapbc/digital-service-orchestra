#!/usr/bin/env bash
# tests/skills/test-ui-discover-cli-migration.sh
# RED tests asserting that ui-discover SKILL.md uses @playwright/cli Bash commands
# instead of Python sync_api for route crawling and availability checks.
#
# All critical tests are intentionally RED: SKILL.md currently uses Python sync_api.
# GREEN promotion happens when the CLI migration task is implemented.
#
# Test functions:
#   test_no_sync_playwright_imports      — SKILL.md must not use sync_playwright/sync_api
#   test_cli_commands_present            — SKILL.md must contain @playwright/cli patterns
#   test_availability_check_uses_cli     — availability check must reference CLI binary
#   test_cache_format_preserved          — cache-format-reference.md field names unchanged
#
# Usage: bash tests/skills/test-ui-discover-cli-migration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail (currently RED phase)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_MD="$DSO_PLUGIN_DIR/skills/ui-discover/SKILL.md"
CACHE_FORMAT_DOC="$DSO_PLUGIN_DIR/skills/ui-discover/docs/cache-format-reference.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-ui-discover-cli-migration.sh ==="

# test_no_sync_playwright_imports: SKILL.md must NOT reference sync_playwright or sync_api.
# Python sync API patterns are replaced by @playwright/cli Bash commands in the migration.
test_no_sync_playwright_imports() {
    _snapshot_fail
    local sync_api_found="absent"
    if grep -qE 'sync_playwright|sync_api|from playwright\.sync_api' "$SKILL_MD" 2>/dev/null; then
        sync_api_found="found"
    fi
    assert_eq "test_no_sync_playwright_imports" "absent" "$sync_api_found"
    assert_pass_if_clean "test_no_sync_playwright_imports"
}

# test_cli_commands_present: SKILL.md must contain @playwright/cli command patterns.
# Expected: references to `npx playwright` or `@playwright/cli` or `playwright screenshot`
# or similar CLI-based invocation patterns for route crawling.
test_cli_commands_present() {
    _snapshot_fail
    local cli_pattern_found="absent"
    if grep -qE '@playwright/cli|npx playwright|playwright screenshot|playwright open|playwright codegen' "$SKILL_MD" 2>/dev/null; then
        cli_pattern_found="found"
    fi
    assert_eq "test_cli_commands_present" "found" "$cli_pattern_found"
    assert_pass_if_clean "test_cli_commands_present"
}

# test_availability_check_uses_cli: availability check (Phase 1 Step 1) must use CLI binary.
# Must NOT use `python -c "from playwright` style checks.
# Must use: `command -v playwright`, `which playwright`, or `npx playwright --version`.
test_availability_check_uses_cli() {
    _snapshot_fail
    local python_import_check_found="absent"
    if grep -qE 'python.*from playwright|python.*import.*playwright' "$SKILL_MD" 2>/dev/null; then
        python_import_check_found="found"
    fi
    assert_eq "test_availability_check_uses_cli" "absent" "$python_import_check_found"
    assert_pass_if_clean "test_availability_check_uses_cli"
}

# test_cache_format_preserved: cache-format-reference.md must retain its core field names.
# These fields are consumed by design-wireframe and must not be renamed during migration.
test_cache_format_preserved() {
    _snapshot_fail
    local missing_fields=0
    local required_fields=(
        "version"
        "generatedAt"
        "gitCommit"
        "playwrightUsed"
        "uiFileHashes"
        "entries"
        "dependsOn"
        "route-map"
        "app-shell"
        "design-tokens"
    )
    for field in "${required_fields[@]}"; do
        if ! grep -q "$field" "$CACHE_FORMAT_DOC" 2>/dev/null; then
            missing_fields=$((missing_fields + 1))
            echo "  MISSING FIELD: $field" >&2
        fi
    done
    assert_eq "test_cache_format_preserved" "0" "$missing_fields"
    assert_pass_if_clean "test_cache_format_preserved"
}

# --- Run all test functions ---
test_no_sync_playwright_imports
test_cli_commands_present
test_availability_check_uses_cli
test_cache_format_preserved

print_summary
