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
# Check name and description as non-empty strings; source may be a string or object (git-subdir format)
for field in name description; do
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
# source may be a non-empty string or a non-null object (git-subdir format)
if [[ -f "$MARKETPLACE_JSON" ]] && python3 -c "
import json, sys
data = json.load(open('$MARKETPLACE_JSON'))
plugin = data.get('plugins', [{}])[0]
src = plugin.get('source')
ok = (isinstance(src, str) and len(src) > 0) or (isinstance(src, dict) and len(src) > 0)
sys.exit(0 if ok else 1)
" 2>/dev/null; then
    actual_field="present"
else
    actual_field="missing"
fi
assert_eq "test_marketplace_json_plugin_has_required_fields: plugins[0].source present" "present" "$actual_field"
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

# ── test_stamp_format_consistent (57ad-0d1e) ─────────────────────────────────
# RED phase: FAILS until stamp_artifact() is implemented in dso-setup.sh.
# After dso-setup.sh runs on a temp dir, all 4 installed artifacts must:
#   (a) have a version stamp present
#   (b) share the same version string
#   (c) text artifacts (shim, config) use `# dso-version: <ver>`
#   (d) YAML artifacts (pre-commit, ci) use `x-dso-version: <ver>`
#   (e) the stamped version matches plugin.json
SETUP_SCRIPT="$DSO_PLUGIN_DIR/scripts/onboarding/dso-setup.sh"
_STAMP_TMPDIR=$(mktemp -d)
trap 'rm -rf "$_STAMP_TMPDIR"' EXIT

_snapshot_fail
bash "$SETUP_SCRIPT" "$_STAMP_TMPDIR" "$DSO_PLUGIN_DIR" >/dev/null 2>&1 || true

# Extract plugin.json version
_plugin_ver=$(python3 -c "import json; print(json.load(open('$PLUGIN_JSON'))['version'])" 2>/dev/null || echo "")

# Extract stamps from each artifact
_shim_stamp=$(grep '# dso-version:' "$_STAMP_TMPDIR/.claude/scripts/dso" 2>/dev/null | head -1 | sed 's/.*# dso-version: *//' | tr -d '[:space:]')
_conf_stamp=$(grep '# dso-version:' "$_STAMP_TMPDIR/.claude/dso-config.conf" 2>/dev/null | head -1 | sed 's/.*# dso-version: *//' | tr -d '[:space:]')
_precommit_stamp=$(grep '^x-dso-version:' "$_STAMP_TMPDIR/.pre-commit-config.yaml" 2>/dev/null | head -1 | sed 's/x-dso-version: *//' | tr -d '[:space:]')
_ci_stamp=$(grep '^x-dso-version:' "$_STAMP_TMPDIR/.github/workflows/ci.yml" 2>/dev/null | head -1 | sed 's/x-dso-version: *//' | tr -d '[:space:]')

# All 4 stamps must be present
if [[ -n "$_shim_stamp" ]]; then actual_shim="present"; else actual_shim="missing"; fi
assert_eq "test_stamp_format_consistent: shim has # dso-version stamp" "present" "$actual_shim"

if [[ -n "$_conf_stamp" ]]; then actual_conf="present"; else actual_conf="missing"; fi
assert_eq "test_stamp_format_consistent: config has # dso-version stamp" "present" "$actual_conf"

if [[ -n "$_precommit_stamp" ]]; then actual_pre="present"; else actual_pre="missing"; fi
assert_eq "test_stamp_format_consistent: pre-commit has x-dso-version stamp" "present" "$actual_pre"

if [[ -n "$_ci_stamp" ]]; then actual_ci="present"; else actual_ci="missing"; fi
assert_eq "test_stamp_format_consistent: ci.yml has x-dso-version stamp" "present" "$actual_ci"

# All version strings must match plugin.json
if [[ -n "$_plugin_ver" && "$_shim_stamp" == "$_plugin_ver" ]]; then actual_match_shim="match"; else actual_match_shim="mismatch"; fi
assert_eq "test_stamp_format_consistent: shim version matches plugin.json" "match" "$actual_match_shim"

if [[ -n "$_plugin_ver" && "$_conf_stamp" == "$_plugin_ver" ]]; then actual_match_conf="match"; else actual_match_conf="mismatch"; fi
assert_eq "test_stamp_format_consistent: config version matches plugin.json" "match" "$actual_match_conf"

if [[ -n "$_plugin_ver" && "$_precommit_stamp" == "$_plugin_ver" ]]; then actual_match_pre="match"; else actual_match_pre="mismatch"; fi
assert_eq "test_stamp_format_consistent: pre-commit version matches plugin.json" "match" "$actual_match_pre"

if [[ -n "$_plugin_ver" && "$_ci_stamp" == "$_plugin_ver" ]]; then actual_match_ci="match"; else actual_match_ci="mismatch"; fi
assert_eq "test_stamp_format_consistent: ci.yml version matches plugin.json" "match" "$actual_match_ci"

assert_pass_if_clean "test_stamp_format_consistent"

# ── test_marketplace_json_has_two_plugins ─────────────────────────────────────
# RED marker: [test_marketplace_json_has_two_plugins]
# FAILS until marketplace.json is updated to two git-subdir entries.
_snapshot_fail
if [[ -f "$MARKETPLACE_JSON" ]] && python3 -c "
import json, sys
data = json.load(open('$MARKETPLACE_JSON'))
plugins = data.get('plugins', [])
sys.exit(0 if len(plugins) == 2 else 1)
" 2>/dev/null; then
    actual_two_plugins="two"
else
    actual_two_plugins="not-two"
fi
assert_eq "test_marketplace_json_has_two_plugins: plugins array has exactly 2 entries" "two" "$actual_two_plugins"
assert_pass_if_clean "test_marketplace_json_has_two_plugins"

# ── test_marketplace_json_dso_uses_git_subdir ─────────────────────────────────
_snapshot_fail
if [[ -f "$MARKETPLACE_JSON" ]] && python3 -c "
import json, sys
data = json.load(open('$MARKETPLACE_JSON'))
plugins = data.get('plugins', [])
dso = next((p for p in plugins if p.get('name') == 'dso'), None)
if dso is None:
    sys.exit(1)
src = dso.get('source', {})
if not isinstance(src, dict):
    sys.exit(1)
import re
ref = src.get('ref', '')
# After cutover, dso stable channel is pinned to a semver tag (v*.*.*)
# Pre-cutover it was 'main' — accept both so the test is not brittle across releases
valid_ref = ref == 'main' or bool(re.match(r'^v\d+\.\d+\.\d+$', ref))
ok = (
    src.get('source') == 'git-subdir'
    and 'navapbc/digital-service-orchestra' in src.get('url', '')
    and src.get('path') == 'plugins/dso'
    and valid_ref
)
sys.exit(0 if ok else 1)
" 2>/dev/null; then
    actual_dso_gitsubdir="valid"
else
    actual_dso_gitsubdir="invalid"
fi
assert_eq "test_marketplace_json_dso_uses_git_subdir: dso entry uses git-subdir source" "valid" "$actual_dso_gitsubdir"
assert_pass_if_clean "test_marketplace_json_dso_uses_git_subdir"

# ── test_marketplace_json_dso_dev_uses_git_subdir ─────────────────────────────
_snapshot_fail
if [[ -f "$MARKETPLACE_JSON" ]] && python3 -c "
import json, sys
data = json.load(open('$MARKETPLACE_JSON'))
plugins = data.get('plugins', [])
dso_dev = next((p for p in plugins if p.get('name') == 'dso-dev'), None)
if dso_dev is None:
    sys.exit(1)
src = dso_dev.get('source', {})
if not isinstance(src, dict):
    sys.exit(1)
ok = (
    src.get('source') == 'git-subdir'
    and 'navapbc/digital-service-orchestra' in src.get('url', '')
    and src.get('path') == 'plugins/dso'
    and src.get('ref') == 'main'
)
sys.exit(0 if ok else 1)
" 2>/dev/null; then
    actual_dso_dev_gitsubdir="valid"
else
    actual_dso_dev_gitsubdir="invalid"
fi
assert_eq "test_marketplace_json_dso_dev_uses_git_subdir: dso-dev entry uses git-subdir source" "valid" "$actual_dso_dev_gitsubdir"
assert_pass_if_clean "test_marketplace_json_dso_dev_uses_git_subdir"

print_summary
