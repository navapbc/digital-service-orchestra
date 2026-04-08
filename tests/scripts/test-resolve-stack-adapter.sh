#!/usr/bin/env bash
# tests/scripts/test-resolve-stack-adapter.sh
# Tests for resolve-stack-adapter.sh — resolves the stack adapter file path
# based on workflow-config.yaml stack and template engine settings.
#
# Usage: bash tests/scripts/test-resolve-stack-adapter.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
CANONICAL="$DSO_PLUGIN_DIR/scripts/resolve-stack-adapter.sh"
UI_DISCOVER_SKILL="$DSO_PLUGIN_DIR/skills/ui-discover/SKILL.md"
source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-resolve-stack-adapter.sh ==="

# ── test_script_exists_and_executable ────────────────────────────────────────
# (a) canonical script exists and is executable
_snapshot_fail
script_executable=0
[ -x "$CANONICAL" ] && script_executable=1
assert_eq "test_script_exists_and_executable: canonical exists and is executable" "1" "$script_executable"
assert_pass_if_clean "test_script_exists_and_executable"

# ── test_ui_discover_skill_references_script ──────────────────────────────────
# (c) ui-discover/SKILL.md references resolve-stack-adapter.sh
_snapshot_fail
ui_discover_refs=0
grep -q 'resolve-stack-adapter\.sh' "$UI_DISCOVER_SKILL" 2>/dev/null && ui_discover_refs=1
assert_eq "test_ui_discover_skill_references_script: ui-discover/SKILL.md references script" "1" "$ui_discover_refs"
assert_pass_if_clean "test_ui_discover_skill_references_script"

# ── test_ui_designer_agent_references_script ─────────────────────────────────
# (c) dso:ui-designer agent references resolve-stack-adapter.sh
# design-wireframe/SKILL.md is now a redirect stub (superseded by dso:ui-designer);
# the adapter resolution logic moved to the ui-designer agent.
UI_DESIGNER_AGENT="$DSO_PLUGIN_DIR/agents/ui-designer.md"
_snapshot_fail
ui_designer_refs=0
grep -q 'resolve-stack-adapter\.sh' "$UI_DESIGNER_AGENT" 2>/dev/null && ui_designer_refs=1
assert_eq "test_ui_designer_agent_references_script: ui-designer.md references script" "1" "$ui_designer_refs"
assert_pass_if_clean "test_ui_designer_agent_references_script"

# ── test_script_outputs_to_stdout ─────────────────────────────────────────────
# (d) script outputs the adapter file path (or empty string) to stdout
# Run with no REPO_ROOT override — in an environment without a matching adapter
# the script should exit 0 and output an empty string (or a valid path) to stdout
_snapshot_fail
script_ran=0
output=$(bash "$CANONICAL" 2>/dev/null)
exit_code=$?
# Script must exit 0 (success — even when no adapter is found)
[ "$exit_code" -eq 0 ] && script_ran=1
assert_eq "test_script_outputs_to_stdout: script exits 0" "1" "$script_ran"
# Output must be either empty or a file that exists (a valid adapter path)
output_valid=0
if [[ -z "$output" ]]; then
    output_valid=1  # empty string is valid (no adapter found)
elif [[ -f "$output" ]]; then
    output_valid=1  # non-empty output must point to an existing file
fi
assert_eq "test_script_outputs_to_stdout: output is empty or a valid file path" "1" "$output_valid"
assert_pass_if_clean "test_script_outputs_to_stdout"

print_summary
