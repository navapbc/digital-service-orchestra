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

_CLEANUP_DIRS=()
trap 'for _d in "${_CLEANUP_DIRS[@]:-}"; do [[ -d "$_d" ]] && rm -rf "$_d"; done' EXIT

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

# ── test_stamp_format_consistent ──────────────────────────────────────────────
# Run dso-setup.sh on a fresh temp dir, then check that all 4 installed artifacts
# contain a version stamp and that all version strings match plugin.json.
#
# Artifacts checked:
#   shim (.claude/scripts/dso)             → "# dso-version: <version>"
#   config (.claude/dso-config.conf)       → "# dso-version: <version>"
#   pre-commit (.pre-commit-config.yaml)   → "^x-dso-version: <version>"
#   CI workflow (.github/workflows/ci.yml) → "^x-dso-version: <version>"
#
# RED: dso-setup.sh does not yet embed stamps — all 4 extractions will be empty,
#      causing "stamp present" assertions to fail.
_snapshot_fail

_SETUP_TMPDIR=$(mktemp -d)
_CLEANUP_DIRS+=("$_SETUP_TMPDIR")

_SETUP_EXIT=0
bash "$PLUGIN_ROOT/plugins/dso/scripts/dso-setup.sh" "$_SETUP_TMPDIR" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || _SETUP_EXIT=$?

# Acceptable exit codes: 0 (success) or 2 (warnings-only — missing pre-commit/python3/claude)
if [[ "$_SETUP_EXIT" -eq 0 || "$_SETUP_EXIT" -eq 2 ]]; then
    _setup_ran="yes"
else
    _setup_ran="no"
fi
assert_eq "test_stamp_format_consistent: dso-setup.sh ran successfully (exit 0 or 2)" "yes" "$_setup_ran"

# Read expected version from plugin.json
_expected_version=$(python3 -c "
import json, sys
data = json.load(open('$PLUGIN_JSON'))
print(data.get('version', ''))
" 2>/dev/null)

# Extract stamp from shim: "# dso-version: <version>"
_shim="$_SETUP_TMPDIR/.claude/scripts/dso"
if [[ -f "$_shim" ]]; then
    _shim_version=$(grep -m1 '^# dso-version:' "$_shim" 2>/dev/null | sed 's/^# dso-version: *//' | tr -d '[:space:]') || _shim_version=""
else
    _shim_version=""
fi

# Extract stamp from config: "# dso-version: <version>"
_config="$_SETUP_TMPDIR/.claude/dso-config.conf"
if [[ -f "$_config" ]]; then
    _config_version=$(grep -m1 '^# dso-version:' "$_config" 2>/dev/null | sed 's/^# dso-version: *//' | tr -d '[:space:]') || _config_version=""
else
    _config_version=""
fi

# Extract stamp from pre-commit YAML: "x-dso-version: <version>"
_precommit="$_SETUP_TMPDIR/.pre-commit-config.yaml"
if [[ -f "$_precommit" ]]; then
    _precommit_version=$(grep -m1 '^x-dso-version:' "$_precommit" 2>/dev/null | sed 's/^x-dso-version: *//' | tr -d '[:space:]') || _precommit_version=""
else
    _precommit_version=""
fi

# Extract stamp from CI YAML: "x-dso-version: <version>"
_ci_yml="$_SETUP_TMPDIR/.github/workflows/ci.yml"
if [[ -f "$_ci_yml" ]]; then
    _ci_version=$(grep -m1 '^x-dso-version:' "$_ci_yml" 2>/dev/null | sed 's/^x-dso-version: *//' | tr -d '[:space:]') || _ci_version=""
else
    _ci_version=""
fi

# Assert all 4 artifacts have a stamp present
_shim_present="no"; [[ -n "$_shim_version" ]] && _shim_present="yes"
_config_present="no"; [[ -n "$_config_version" ]] && _config_present="yes"
_precommit_present="no"; [[ -n "$_precommit_version" ]] && _precommit_present="yes"
_ci_present="no"; [[ -n "$_ci_version" ]] && _ci_present="yes"

assert_eq "test_stamp_format_consistent: shim has dso-version stamp" "yes" "$_shim_present"
assert_eq "test_stamp_format_consistent: config has dso-version stamp" "yes" "$_config_present"
assert_eq "test_stamp_format_consistent: pre-commit YAML has x-dso-version stamp" "yes" "$_precommit_present"
assert_eq "test_stamp_format_consistent: CI YAML has x-dso-version stamp" "yes" "$_ci_present"

# Assert all 4 version strings match each other
assert_eq "test_stamp_format_consistent: shim version matches config version" "$_shim_version" "$_config_version"
assert_eq "test_stamp_format_consistent: shim version matches pre-commit version" "$_shim_version" "$_precommit_version"
assert_eq "test_stamp_format_consistent: shim version matches ci version" "$_shim_version" "$_ci_version"

# Assert version matches plugin.json
assert_eq "test_stamp_format_consistent: stamp version matches plugin.json" "$_expected_version" "$_shim_version"

assert_pass_if_clean "test_stamp_format_consistent"

print_summary
