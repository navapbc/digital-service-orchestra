#!/usr/bin/env bash
# tests/scripts/test-design-notes-migration.sh
# Verifies that DESIGN_NOTES.md references have been migrated to .claude/design-notes.md.
#
# Tests covered:
#   1. test_no_old_design_notes_refs — no bare DESIGN_NOTES.md refs remain in plugins/dso/
#   2. test_schema_default_updated   — workflow-config-schema.json default is .claude/design-notes.md
#   3. test_validate_config_accepts_new_path — validate-config.sh accepts .claude/design-notes.md
#
# Usage: bash tests/scripts/test-design-notes-migration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# RED state: tests 1 and 2 FAIL until the DESIGN_NOTES.md migration is complete.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-design-notes-migration.sh ==="

SCHEMA_FILE="$DSO_PLUGIN_DIR/docs/workflow-config-schema.json"
VALIDATE_CONFIG_SCRIPT="$DSO_PLUGIN_DIR/scripts/validate-config.sh"

# ── test_no_old_design_notes_refs ─────────────────────────────────────────────
# After migration, no file in plugins/dso/ should reference the bare filename
# "DESIGN_NOTES.md" (the old canonical path). The new path is .claude/design-notes.md.
# Exclusions:
#   - .claude/design-notes.md itself (the new file, if it exists)
#   - this test file (it necessarily references the pattern to search for)
_snapshot_fail
count=0
count=$(grep -r 'DESIGN_NOTES\.md' \
    "$DSO_PLUGIN_DIR" \
    2>/dev/null \
    | grep -v '\.claude/design-notes\.md' \
    | grep -v "$(basename "${BASH_SOURCE[0]}")" \
    | wc -l \
    | tr -d ' ')
assert_eq "test_no_old_design_notes_refs" "0" "$count"
assert_pass_if_clean "test_no_old_design_notes_refs"

# ── test_schema_default_updated ───────────────────────────────────────────────
# workflow-config-schema.json must use ".claude/design-notes.md" as the default
# value for design_notes_path, not the legacy "DESIGN_NOTES.md".
_snapshot_fail
if [[ ! -f "$SCHEMA_FILE" ]]; then
    assert_eq "test_schema_default_updated (schema file exists)" "present" "missing"
else
    # Extract the default value for design_notes_path
    schema_default=""
    schema_default=$(python3 -c "
import json
with open('$SCHEMA_FILE') as f:
    d = json.load(f)
def find_default(obj, key):
    if isinstance(obj, dict):
        if key in obj:
            return obj[key].get('default', '')
        for v in obj.values():
            r = find_default(v, key)
            if r is not None:
                return r
    elif isinstance(obj, list):
        for item in obj:
            r = find_default(item, key)
            if r is not None:
                return r
    return None
result = find_default(d, 'design_notes_path')
print(result if result is not None else '')
" 2>/dev/null || true)
    assert_eq "test_schema_default_updated" ".claude/design-notes.md" "$schema_default"
fi
assert_pass_if_clean "test_schema_default_updated"

# ── test_validate_config_accepts_new_path ─────────────────────────────────────
# validate-config.sh must accept a config with design.design_notes_path set to
# .claude/design-notes.md (i.e., recognize it as a known key without errors).
_snapshot_fail
if [[ ! -f "$VALIDATE_CONFIG_SCRIPT" ]]; then
    echo "test_validate_config_accepts_new_path ... SKIP (validate-config.sh not found)"
else
    tmpconf=$(mktemp)
    trap 'rm -f "$tmpconf"' EXIT
    echo "design.design_notes_path=.claude/design-notes.md" > "$tmpconf"
    validate_exit=0
    bash "$VALIDATE_CONFIG_SCRIPT" "$tmpconf" >/dev/null 2>&1 || validate_exit=$?
    assert_eq "test_validate_config_accepts_new_path" "0" "$validate_exit"
fi
assert_pass_if_clean "test_validate_config_accepts_new_path"

print_summary
