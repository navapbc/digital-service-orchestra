#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-resolve-stack-adapter.sh
# Tests for resolve-stack-adapter.sh — resolves the stack adapter file path
# based on workflow-config.yaml stack and template engine settings.
#
# Usage: bash lockpick-workflow/tests/scripts/test-resolve-stack-adapter.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CANONICAL="$REPO_ROOT/lockpick-workflow/scripts/resolve-stack-adapter.sh"
WRAPPER="$REPO_ROOT/scripts/resolve-stack-adapter.sh"
UI_DISCOVER_SKILL="$REPO_ROOT/lockpick-workflow/skills/ui-discover/SKILL.md"
DESIGN_WIREFRAME_SKILL="$REPO_ROOT/lockpick-workflow/skills/design-wireframe/SKILL.md"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-resolve-stack-adapter.sh ==="

# ── test_script_exists_and_executable ────────────────────────────────────────
# (a) canonical script exists and is executable
_snapshot_fail
script_executable=0
[ -x "$CANONICAL" ] && script_executable=1
assert_eq "test_script_exists_and_executable: canonical exists and is executable" "1" "$script_executable"
assert_pass_if_clean "test_script_exists_and_executable"

# ── test_wrapper_exists ───────────────────────────────────────────────────────
# (b) scripts/ wrapper exists and delegates to canonical
_snapshot_fail
wrapper_exists=0
[ -f "$WRAPPER" ] && wrapper_exists=1
assert_eq "test_wrapper_exists: scripts/ wrapper exists" "1" "$wrapper_exists"
# Wrapper should contain exec delegation to lockpick-workflow/scripts/
wrapper_delegates=0
grep -q 'lockpick-workflow/scripts/resolve-stack-adapter.sh' "$WRAPPER" 2>/dev/null && wrapper_delegates=1
assert_eq "test_wrapper_exists: wrapper delegates to canonical" "1" "$wrapper_delegates"
assert_pass_if_clean "test_wrapper_exists"

# ── test_ui_discover_skill_references_script ──────────────────────────────────
# (c) ui-discover/SKILL.md references resolve-stack-adapter.sh
_snapshot_fail
ui_discover_refs=0
grep -q 'resolve-stack-adapter\.sh' "$UI_DISCOVER_SKILL" 2>/dev/null && ui_discover_refs=1
assert_eq "test_ui_discover_skill_references_script: ui-discover/SKILL.md references script" "1" "$ui_discover_refs"
assert_pass_if_clean "test_ui_discover_skill_references_script"

# ── test_design_wireframe_skill_references_script ─────────────────────────────
# (c) design-wireframe/SKILL.md references resolve-stack-adapter.sh
_snapshot_fail
design_wireframe_refs=0
grep -q 'resolve-stack-adapter\.sh' "$DESIGN_WIREFRAME_SKILL" 2>/dev/null && design_wireframe_refs=1
assert_eq "test_design_wireframe_skill_references_script: design-wireframe/SKILL.md references script" "1" "$design_wireframe_refs"
assert_pass_if_clean "test_design_wireframe_skill_references_script"

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
