#!/usr/bin/env bash
# tests/scripts/test-marketplace-json.sh
# TDD red-phase tests for .claude-plugin/marketplace.json schema validation
#
# Usage: bash tests/scripts/test-marketplace-json.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# NOTE: These tests are expected to FAIL until marketplace.json is created.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
MARKETPLACE_JSON="$PLUGIN_ROOT/.claude-plugin/marketplace.json"
PLUGIN_JSON="$PLUGIN_ROOT/.claude-plugin/plugin.json"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-marketplace-json.sh ==="

# ── test_marketplace_json_exists ──────────────────────────────────────────────
# marketplace.json must exist at .claude-plugin/marketplace.json
if [[ -f "$MARKETPLACE_JSON" ]]; then
    actual_exists="exists"
else
    actual_exists="missing"
fi
assert_eq "test_marketplace_json_exists: file exists" "exists" "$actual_exists"

# ── test_marketplace_json_has_required_fields ─────────────────────────────────
# All required top-level fields must be present in the JSON.
REQUIRED_FIELDS=(name version description repository homepage install compatibility)
for field in "${REQUIRED_FIELDS[@]}"; do
    if [[ -f "$MARKETPLACE_JSON" ]] && python3 -c "
import json, sys
data = json.load(open('$MARKETPLACE_JSON'))
sys.exit(0 if '$field' in data else 1)
" 2>/dev/null; then
        actual_field="present"
    else
        actual_field="missing"
    fi
    assert_eq "test_marketplace_json_has_required_fields: field '$field' present" "present" "$actual_field"
done

# ── test_marketplace_json_version_is_semver ───────────────────────────────────
# The version field must match semantic versioning format (X.Y.Z).
if [[ -f "$MARKETPLACE_JSON" ]]; then
    version_value=$(python3 -c "
import json
data = json.load(open('$MARKETPLACE_JSON'))
print(data.get('version', ''))
" 2>/dev/null)
else
    version_value=""
fi

if echo "$version_value" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    actual_semver="valid"
else
    actual_semver="invalid"
fi
assert_eq "test_marketplace_json_version_is_semver: version matches semver pattern" "valid" "$actual_semver"

# ── test_marketplace_json_install_command_present ─────────────────────────────
# The install.command field must be a non-empty string.
if [[ -f "$MARKETPLACE_JSON" ]]; then
    install_command=$(python3 -c "
import json, sys
data = json.load(open('$MARKETPLACE_JSON'))
install = data.get('install', {})
cmd = install.get('command', '') if isinstance(install, dict) else ''
print(cmd)
" 2>/dev/null)
else
    install_command=""
fi

if [[ -n "$install_command" ]]; then
    actual_install_cmd="non_empty"
else
    actual_install_cmd="empty"
fi
assert_eq "test_marketplace_json_install_command_present: install.command is non-empty" "non_empty" "$actual_install_cmd"

# ── test_marketplace_json_skills_dir_matches_plugin_json ─────────────────────
# The skills field in marketplace.json must match the skills field in plugin.json.
if [[ -f "$MARKETPLACE_JSON" ]] && [[ -f "$PLUGIN_JSON" ]]; then
    marketplace_skills=$(python3 -c "
import json
data = json.load(open('$MARKETPLACE_JSON'))
print(data.get('skills', ''))
" 2>/dev/null)

    plugin_skills=$(python3 -c "
import json
data = json.load(open('$PLUGIN_JSON'))
print(data.get('skills', ''))
" 2>/dev/null)

    if [[ "$marketplace_skills" == "$plugin_skills" ]]; then
        actual_skills_match="match"
    else
        actual_skills_match="mismatch"
    fi
else
    actual_skills_match="mismatch"
fi
assert_eq "test_marketplace_json_skills_dir_matches_plugin_json: skills field matches plugin.json" "match" "$actual_skills_match"

print_summary
