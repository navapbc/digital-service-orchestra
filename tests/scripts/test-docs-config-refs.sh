#!/usr/bin/env bash
# tests/scripts/test-docs-config-refs.sh
# Verify that documentation references are updated for the flat config migration.
#
# Usage: bash tests/scripts/test-docs-config-refs.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-docs-config-refs.sh ==="

# ── test_no_yaml_refs_in_docs ─────────────────────────────────────────────────
# grep docs/ for `workflow-config.yaml` → only historical/ADR mentions allowed
_snapshot_fail
yaml_refs_outside_adr=""
# Search all docs directories, excluding ADR files, historical migration docs,
# and legitimate legacy/fallback mentions.
while IFS= read -r line; do
    file="${line%%:*}"
    # Allow references in ADR files (historical record)
    [[ "$file" == *"/decisions/"* ]] && continue
    # Allow references in FLAT-CONFIG-MIGRATION.md (historical context)
    [[ "$file" == *"FLAT-CONFIG-MIGRATION.md"* ]] && continue
    # Allow references in example/template files (instructional content showing users how to configure)
    [[ "$file" == *"/examples/"* ]] && continue
    # Allow legacy/fallback context mentions (lines that explain .yaml is the old format)
    content="${line#*:}"
    # Skip lines that mention .yaml in the context of legacy/fallback/old format
    _tmp="$content"; shopt -s nocasematch; [[ "$_tmp" =~ legacy|fallback|"old format"|migration ]] && { shopt -u nocasematch; continue; }; shopt -u nocasematch
    yaml_refs_outside_adr="$yaml_refs_outside_adr
$line"
done < <(grep -rn 'workflow-config\.yaml' "$DSO_PLUGIN_DIR/docs/" "$DSO_PLUGIN_DIR/docs/" 2>/dev/null || true)

if [[ -z "${yaml_refs_outside_adr// /}" || -z "$(echo "$yaml_refs_outside_adr" | tr -d '[:space:]')" ]]; then
    actual="clean"
else
    actual="found_refs"
    echo "  Non-historical workflow-config.yaml references found:" >&2
    echo "$yaml_refs_outside_adr" | grep -v '^\s*$' >&2
fi
assert_eq "test_no_yaml_refs_in_docs" "clean" "$actual"
assert_pass_if_clean "test_no_yaml_refs_in_docs"

# ── test_example_conf_exists ──────────────────────────────────────────────────
_snapshot_fail
if [ -f "$DSO_PLUGIN_DIR/docs/dso-config.example.conf" ]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_example_conf_exists" "exists" "$actual"
assert_pass_if_clean "test_example_conf_exists"

# ── test_old_yaml_removed ─────────────────────────────────────────────────────
_snapshot_fail
if [ -f "$REPO_ROOT/workflow-config.yaml" ]; then
    actual="still_exists"
else
    actual="removed"
fi
assert_eq "test_old_yaml_removed" "removed" "$actual"
assert_pass_if_clean "test_old_yaml_removed"

# ── test_cache_tests_removed ──────────────────────────────────────────────────
_snapshot_fail
if [ -f "$PLUGIN_ROOT/tests/scripts/test-read-config-cache.sh" ]; then
    actual="still_exists"
else
    actual="removed"
fi
assert_eq "test_cache_tests_removed" "removed" "$actual"
assert_pass_if_clean "test_cache_tests_removed"

print_summary
