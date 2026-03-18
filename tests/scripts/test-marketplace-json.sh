#!/usr/bin/env bash
# tests/scripts/test-marketplace-json.sh
# Tests for .claude-plugin/marketplace.json schema validation
#
# Validates the marketplace catalog format: name, owner, plugins[].
#
# Usage: bash tests/scripts/test-marketplace-json.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
# marketplace.json stays at repo root; plugin.json is inside the plugin subdir
MARKETPLACE_JSON="$PLUGIN_ROOT/.claude-plugin/marketplace.json"
PLUGIN_JSON="$DSO_PLUGIN_DIR/.claude-plugin/plugin.json"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-marketplace-json.sh ==="

# ── test_marketplace_json_exists ──────────────────────────────────────────────
_snapshot_fail
if [[ -f "$MARKETPLACE_JSON" ]]; then
    actual_exists="exists"
else
    actual_exists="missing"
fi
assert_eq "test_marketplace_json_exists: file exists" "exists" "$actual_exists"
assert_pass_if_clean "test_marketplace_json_exists"

# ── test_marketplace_json_valid_json ──────────────────────────────────────────
_snapshot_fail
if [[ -f "$MARKETPLACE_JSON" ]] && python3 -c "import json; json.load(open('$MARKETPLACE_JSON'))" 2>/dev/null; then
    actual_valid="valid"
else
    actual_valid="invalid"
fi
assert_eq "test_marketplace_json_valid_json: file is valid JSON" "valid" "$actual_valid"
assert_pass_if_clean "test_marketplace_json_valid_json"

# ── test_marketplace_json_has_name ────────────────────────────────────────────
_snapshot_fail
if [[ -f "$MARKETPLACE_JSON" ]] && python3 -c "
import json, sys
data = json.load(open('$MARKETPLACE_JSON'))
sys.exit(0 if isinstance(data.get('name'), str) and len(data['name']) > 0 else 1)
" 2>/dev/null; then
    actual_name="present"
else
    actual_name="missing"
fi
assert_eq "test_marketplace_json_has_name: top-level name is non-empty string" "present" "$actual_name"
assert_pass_if_clean "test_marketplace_json_has_name"

# ── test_marketplace_json_has_owner ───────────────────────────────────────────
_snapshot_fail
if [[ -f "$MARKETPLACE_JSON" ]] && python3 -c "
import json, sys
data = json.load(open('$MARKETPLACE_JSON'))
owner = data.get('owner', {})
sys.exit(0 if isinstance(owner, dict) and isinstance(owner.get('name'), str) and len(owner['name']) > 0 else 1)
" 2>/dev/null; then
    actual_owner="present"
else
    actual_owner="missing"
fi
assert_eq "test_marketplace_json_has_owner: owner.name is non-empty string" "present" "$actual_owner"
assert_pass_if_clean "test_marketplace_json_has_owner"

# ── test_marketplace_json_has_plugins_array ───────────────────────────────────
_snapshot_fail
if [[ -f "$MARKETPLACE_JSON" ]] && python3 -c "
import json, sys
data = json.load(open('$MARKETPLACE_JSON'))
plugins = data.get('plugins', [])
sys.exit(0 if isinstance(plugins, list) and len(plugins) > 0 else 1)
" 2>/dev/null; then
    actual_plugins="present"
else
    actual_plugins="missing"
fi
assert_eq "test_marketplace_json_has_plugins_array: plugins is non-empty array" "present" "$actual_plugins"
assert_pass_if_clean "test_marketplace_json_has_plugins_array"

# ── test_marketplace_json_plugin_has_required_fields ──────────────────────────
_snapshot_fail
PLUGIN_FIELDS=(name source description)
for field in "${PLUGIN_FIELDS[@]}"; do
    if [[ -f "$MARKETPLACE_JSON" ]] && python3 -c "
import json, sys
data = json.load(open('$MARKETPLACE_JSON'))
plugin = data.get('plugins', [{}])[0]
sys.exit(0 if isinstance(plugin.get('$field'), str) and len(plugin['$field']) > 0 else 1)
" 2>/dev/null; then
        actual_field="present"
    else
        actual_field="missing"
    fi
    assert_eq "test_marketplace_json_plugin_has_required_fields: plugins[0].$field present" "present" "$actual_field"
done
assert_pass_if_clean "test_marketplace_json_plugin_has_required_fields"

# ── test_marketplace_json_plugin_name_matches_plugin_json ─────────────────────
# The plugin name in marketplace.json must match the name in plugin.json.
_snapshot_fail
if [[ -f "$MARKETPLACE_JSON" ]] && [[ -f "$PLUGIN_JSON" ]]; then
    marketplace_name=$(python3 -c "
import json
data = json.load(open('$MARKETPLACE_JSON'))
print(data.get('plugins', [{}])[0].get('name', ''))
" 2>/dev/null)
    plugin_name=$(python3 -c "
import json
data = json.load(open('$PLUGIN_JSON'))
print(data.get('name', ''))
" 2>/dev/null)
    if [[ "$marketplace_name" == "$plugin_name" ]]; then
        actual_match="match"
    else
        actual_match="mismatch"
    fi
else
    actual_match="mismatch"
fi
assert_eq "test_marketplace_json_plugin_name_matches_plugin_json: plugins[0].name matches plugin.json name" "match" "$actual_match"
assert_pass_if_clean "test_marketplace_json_plugin_name_matches_plugin_json"

print_summary
