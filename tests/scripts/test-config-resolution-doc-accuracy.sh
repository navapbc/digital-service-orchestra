#!/usr/bin/env bash
# tests/scripts/test-config-resolution-doc-accuracy.sh
# Verifies CONFIG-RESOLUTION.md accurately documents the actual read-config.sh
# resolution logic — specifically that it does NOT document a resolution step via
# ${CLAUDE_PLUGIN_ROOT}/.claude/dso-config.conf, which was removed from read-config.sh.
#
# Usage: bash tests/scripts/test-config-resolution-doc-accuracy.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-config-resolution-doc-accuracy.sh ==="

# ── test_config_resolution_doc_no_claude_plugin_root_path ────────────────────
# CONFIG-RESOLUTION.md must NOT document a resolution step that uses
# ${CLAUDE_PLUGIN_ROOT}/.claude/dso-config.conf. The read-config.sh script
# removed CLAUDE_PLUGIN_ROOT-based resolution (see comment: 'CLAUDE_PLUGIN_ROOT-based
# resolution removed'). The doc must reflect this.
_snapshot_fail
if grep -qE 'CLAUDE_PLUGIN_ROOT.*dso-config\.conf' "$DSO_PLUGIN_DIR/docs/CONFIG-RESOLUTION.md" 2>/dev/null; then
    actual="found_stale_path"
    echo "  CONFIG-RESOLUTION.md still documents CLAUDE_PLUGIN_ROOT-based resolution:" >&2
    grep -nE 'CLAUDE_PLUGIN_ROOT.*dso-config\.conf' "$DSO_PLUGIN_DIR/docs/CONFIG-RESOLUTION.md" >&2
else
    actual="clean"
fi
assert_eq "test_config_resolution_doc_no_claude_plugin_root_path" "clean" "$actual"
assert_pass_if_clean "test_config_resolution_doc_no_claude_plugin_root_path"

# ── test_migration_doc_no_settings_json_env_override ────────────────────────
# MIGRATION-TO-PLUGIN.md must NOT recommend setting CLAUDE_PLUGIN_ROOT in
# settings.json env block as the primary installation approach. The canonical
# approach is the dso shim reading dso.plugin_root from .claude/dso-config.conf.
# The settings.json env block method is the OLD approach that dso-zu4o removes.
_snapshot_fail
if grep -qE 'CLAUDE_PLUGIN_ROOT.*settings\.json|settings\.json.*CLAUDE_PLUGIN_ROOT' "$DSO_PLUGIN_DIR/docs/MIGRATION-TO-PLUGIN.md" 2>/dev/null; then
    actual_migration="found_stale_settings_json_override"
    echo "  MIGRATION-TO-PLUGIN.md still recommends CLAUDE_PLUGIN_ROOT in settings.json:" >&2
    grep -nE 'CLAUDE_PLUGIN_ROOT.*settings\.json|settings\.json.*CLAUDE_PLUGIN_ROOT' "$DSO_PLUGIN_DIR/docs/MIGRATION-TO-PLUGIN.md" >&2
else
    actual_migration="clean"
fi
assert_eq "test_migration_doc_no_settings_json_env_override" "clean" "$actual_migration"
assert_pass_if_clean "test_migration_doc_no_settings_json_env_override"

print_summary
