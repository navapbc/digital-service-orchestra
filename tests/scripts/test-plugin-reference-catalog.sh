#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-plugin-reference-catalog.sh
# Tests for plugin-reference-catalog.sh — scans for external plugin references
#
# Usage: bash lockpick-workflow/tests/scripts/test-plugin-reference-catalog.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CATALOG="$REPO_ROOT/lockpick-workflow/scripts/plugin-reference-catalog.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-plugin-reference-catalog.sh ==="

# Capture output once for all tests
OUTPUT=""
if [ -x "$CATALOG" ]; then
    OUTPUT="$(bash "$CATALOG" 2>/dev/null)"
fi

# ── test_catalog_finds_known_references ──────────────────────────────────────
# Run against the real codebase; verify at least 1 reference found
# (known: TEST-FAILURE-DISPATCH.md has debugging-toolkit, unit-testing references)
_snapshot_fail
found_refs=0
if echo "$OUTPUT" | grep -v '^$' | grep -v '^---' | grep -v 'Summary' | grep -v 'Total' | grep -q '.'; then
    found_refs=1
fi
assert_eq "test_catalog_finds_known_references: at least 1 reference found" "1" "$found_refs"
assert_pass_if_clean "test_catalog_finds_known_references"

# ── test_catalog_output_format ───────────────────────────────────────────────
# Each detail line matches <file>:<number>:<plugin-name>:.*
_snapshot_fail
format_ok=1
detail_lines="$(echo "$OUTPUT" | grep -v '^$' | grep -v '^---' | grep -v 'Summary' | grep -v 'Total' | grep -v '^[a-z-]*: [0-9]')"
if [ -n "$detail_lines" ]; then
    while IFS= read -r line; do
        if ! echo "$line" | grep -qE '^[^:]+:[0-9]+:[a-z-]+:.*$'; then
            format_ok=0
            break
        fi
    done <<< "$detail_lines"
else
    format_ok=0
fi
assert_eq "test_catalog_output_format: detail lines match <file>:<number>:<plugin-name>:.*" "1" "$format_ok"
assert_pass_if_clean "test_catalog_output_format"

# ── test_catalog_summary_count ───────────────────────────────────────────────
# Output contains "Summary" section with per-plugin counts
_snapshot_fail
has_summary=0
echo "$OUTPUT" | grep -q 'Summary' && has_summary=1
assert_eq "test_catalog_summary_count: output contains Summary section" "1" "$has_summary"

has_counts=0
echo "$OUTPUT" | grep -qE '^[a-z-]+: [0-9]+ references' && has_counts=1
assert_eq "test_catalog_summary_count: output contains per-plugin counts" "1" "$has_counts"
assert_pass_if_clean "test_catalog_summary_count"

# ── test_catalog_covers_all_seven_plugins ────────────────────────────────────
# All 7 plugin names appear in the summary section
_snapshot_fail
all_present=1
for plugin in commit-commands claude-md-management code-simplifier backend-api-security debugging-toolkit unit-testing error-debugging; do
    if ! echo "$OUTPUT" | grep -q "^${plugin}: "; then
        all_present=0
        echo "  missing plugin in summary: $plugin" >&2
    fi
done
assert_eq "test_catalog_covers_all_seven_plugins: all 7 plugins listed in summary" "1" "$all_present"
assert_pass_if_clean "test_catalog_covers_all_seven_plugins"

# ── test_catalog_excludes_self ───────────────────────────────────────────────
# The catalog script and its test are not in the output
_snapshot_fail
self_excluded=1
if echo "$detail_lines" | grep -q 'plugin-reference-catalog'; then
    self_excluded=0
fi
assert_eq "test_catalog_excludes_self: catalog script and test not in output" "1" "$self_excluded"
assert_pass_if_clean "test_catalog_excludes_self"

print_summary
