#!/usr/bin/env bash
# tests/scripts/test-plugin-dir-structure.sh
# TDD RED phase: assert the post-refactor plugins/dso/ directory layout exists.
#
# These tests are intentionally written BEFORE the file move (dso-anlb) so they
# fail RED now and turn GREEN after plugins/dso/ is populated.
#
# Assertions:
#   - plugins/dso/{skills,hooks,commands,scripts,docs,.claude-plugin} exist
#   - repo root no longer contains skills/, hooks/, commands/ at top level
#   - plugins/dso/.claude-plugin/plugin.json exists
#   - .claude-plugin/marketplace.json has source path pointing to plugins/dso
#   - dso-config.conf is git-tracked at repo root
#
# Usage: bash tests/scripts/test-plugin-dir-structure.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-plugin-dir-structure.sh ==="

PLUGINS_DSO="$REPO_ROOT/plugins/dso"

# ── test_plugins_dso_dir_exists ───────────────────────────────────────────────
# plugins/dso/ directory must exist after the refactor
_snapshot_fail
if [ -d "$PLUGINS_DSO" ]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_plugins_dso_dir_exists: plugins/dso/ exists" "exists" "$actual"
assert_pass_if_clean "test_plugins_dso_dir_exists"

# ── test_plugins_dso_skills_subdir ────────────────────────────────────────────
# plugins/dso/skills/ must exist
_snapshot_fail
if [ -d "$PLUGINS_DSO/skills" ]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_plugins_dso_skills_subdir: plugins/dso/skills/ exists" "exists" "$actual"
assert_pass_if_clean "test_plugins_dso_skills_subdir"

# ── test_plugins_dso_hooks_subdir ─────────────────────────────────────────────
# plugins/dso/hooks/ must exist
_snapshot_fail
if [ -d "$PLUGINS_DSO/hooks" ]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_plugins_dso_hooks_subdir: plugins/dso/hooks/ exists" "exists" "$actual"
assert_pass_if_clean "test_plugins_dso_hooks_subdir"

# ── test_plugins_dso_commands_subdir ─────────────────────────────────────────
# plugins/dso/commands/ must exist
_snapshot_fail
if [ -d "$PLUGINS_DSO/commands" ]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_plugins_dso_commands_subdir: plugins/dso/commands/ exists" "exists" "$actual"
assert_pass_if_clean "test_plugins_dso_commands_subdir"

# ── test_plugins_dso_scripts_subdir ───────────────────────────────────────────
# plugins/dso/scripts/ must exist
_snapshot_fail
if [ -d "$PLUGINS_DSO/scripts" ]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_plugins_dso_scripts_subdir: plugins/dso/scripts/ exists" "exists" "$actual"
assert_pass_if_clean "test_plugins_dso_scripts_subdir"

# ── test_plugins_dso_docs_subdir ──────────────────────────────────────────────
# plugins/dso/docs/ must exist
_snapshot_fail
if [ -d "$PLUGINS_DSO/docs" ]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_plugins_dso_docs_subdir: plugins/dso/docs/ exists" "exists" "$actual"
assert_pass_if_clean "test_plugins_dso_docs_subdir"

# ── test_plugins_dso_claude_plugin_subdir ─────────────────────────────────────
# plugins/dso/.claude-plugin/ must exist
_snapshot_fail
if [ -d "$PLUGINS_DSO/.claude-plugin" ]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_plugins_dso_claude_plugin_subdir: plugins/dso/.claude-plugin/ exists" "exists" "$actual"
assert_pass_if_clean "test_plugins_dso_claude_plugin_subdir"

# ── test_plugins_dso_plugin_json_exists ───────────────────────────────────────
# plugins/dso/.claude-plugin/plugin.json must exist
_snapshot_fail
if [ -f "$PLUGINS_DSO/.claude-plugin/plugin.json" ]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_plugins_dso_plugin_json_exists: plugins/dso/.claude-plugin/plugin.json exists" "exists" "$actual"
assert_pass_if_clean "test_plugins_dso_plugin_json_exists"

# ── test_marketplace_json_has_source_path ─────────────────────────────────────
# .claude-plugin/marketplace.json must contain source path pointing to plugins/dso
_snapshot_fail
MARKETPLACE="$REPO_ROOT/.claude-plugin/marketplace.json"
if [ -f "$MARKETPLACE" ]; then
    if grep -q '"source"' "$MARKETPLACE" && grep -q 'plugins/dso' "$MARKETPLACE"; then
        actual="has_source_path"
    else
        actual="missing_source_path"
    fi
else
    actual="marketplace_missing"
fi
assert_eq "test_marketplace_json_has_source_path: marketplace.json has source path pointing to plugins/dso" "has_source_path" "$actual"
assert_pass_if_clean "test_marketplace_json_has_source_path"

# ── test_workflow_config_conf_is_git_tracked ──────────────────────────────────
# dso-config.conf must be git-tracked at .claude/dso-config.conf
# (moved from repo root to .claude/ in dso-kknz batch 5)
_snapshot_fail
tracked_output=""
tracked_output=$(git -C "$REPO_ROOT" ls-files ".claude/dso-config.conf" 2>/dev/null)
if [ -n "$tracked_output" ]; then
    actual="tracked"
else
    actual="not_tracked"
fi
assert_eq "test_workflow_config_conf_is_git_tracked: dso-config.conf is git-tracked" "tracked" "$actual"
assert_pass_if_clean "test_workflow_config_conf_is_git_tracked"

# ── test_repo_root_skills_dir_absent ──────────────────────────────────────────
# After the move, repo root must NOT have a skills/ directory
_snapshot_fail
if [ ! -d "$REPO_ROOT/skills" ]; then
    actual="absent"
else
    actual="present"
fi
assert_eq "test_repo_root_skills_dir_absent: repo root skills/ is absent after move" "absent" "$actual"
assert_pass_if_clean "test_repo_root_skills_dir_absent"

# ── test_repo_root_hooks_dir_absent ───────────────────────────────────────────
# After the move, repo root must NOT have a hooks/ directory
_snapshot_fail
if [ ! -d "$REPO_ROOT/hooks" ]; then
    actual="absent"
else
    actual="present"
fi
assert_eq "test_repo_root_hooks_dir_absent: repo root hooks/ is absent after move" "absent" "$actual"
assert_pass_if_clean "test_repo_root_hooks_dir_absent"

# ── test_repo_root_commands_dir_absent ────────────────────────────────────────
# After the move, repo root must NOT have a commands/ directory
_snapshot_fail
if [ ! -d "$REPO_ROOT/commands" ]; then
    actual="absent"
else
    actual="present"
fi
assert_eq "test_repo_root_commands_dir_absent: repo root commands/ is absent after move" "absent" "$actual"
assert_pass_if_clean "test_repo_root_commands_dir_absent"

# ── test_plugin_json_agents_in_sync ───────────────────────────────────────────
# plugin.json agents array must contain exactly the .md files in agents/
_snapshot_fail
agents_dir="$PLUGINS_DSO/agents"
json_agents=$(python3 -c "
import json, os
d = json.load(open('$PLUGINS_DSO/.claude-plugin/plugin.json'))
names = sorted(os.path.basename(p) for p in d.get('agents', []))
print('\n'.join(names))
" 2>/dev/null | sort)
disk_agents=$(python3 -c "
import os
print('\n'.join(sorted(f for f in os.listdir('$agents_dir') if f.endswith('.md'))))
" 2>/dev/null | sort)
if [ "$json_agents" = "$disk_agents" ]; then
    actual="in_sync"
else
    actual="out_of_sync"
    echo "  plugin.json agents vs agents/ directory mismatch:"
    diff <(echo "$json_agents") <(echo "$disk_agents") | sed 's/^/    /'
fi
assert_eq "test_plugin_json_agents_in_sync: plugin.json agents list matches agents/ directory" "in_sync" "$actual"
assert_pass_if_clean "test_plugin_json_agents_in_sync"

print_summary
