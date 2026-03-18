#!/usr/bin/env bash
# tests/scripts/test-check-plugin-test-needed.sh
# Tests for check-plugin-test-needed.sh — detects whether plugin tests should run
# based on the list of changed files.
#
# Usage: bash tests/scripts/test-check-plugin-test-needed.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
CANONICAL="$DSO_PLUGIN_DIR/scripts/check-plugin-test-needed.sh"
WORKFLOW_FILE="$DSO_PLUGIN_DIR/docs/workflows/COMMIT-WORKFLOW.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-check-plugin-test-needed.sh ==="

# ── test_script_exists_and_executable ────────────────────────────────────────
# (a) canonical script exists and is executable
_snapshot_fail
script_executable=0
[ -x "$CANONICAL" ] && script_executable=1
assert_eq "test_script_exists_and_executable: canonical exists and is executable" "1" "$script_executable"
assert_pass_if_clean "test_script_exists_and_executable"

# ── test_commit_workflow_has_plugin_test_step ─────────────────────────────────
# (c) COMMIT-WORKFLOW.md has a mandatory plugin test step (Step 1.75)
_snapshot_fail
workflow_has_step=0
grep -q 'make test-plugin' "$WORKFLOW_FILE" 2>/dev/null && workflow_has_step=1
assert_eq "test_commit_workflow_has_plugin_test_step: COMMIT-WORKFLOW.md has make test-plugin" "1" "$workflow_has_step"
assert_pass_if_clean "test_commit_workflow_has_plugin_test_step"

# ── test_exits_zero_for_lockpick_workflow_scripts ─────────────────────────────
# (d) exits 0 when scripts/* file is in the changed list
_snapshot_fail
exit_code_lw_scripts=0
echo 'scripts/foo.sh' | bash "$CANONICAL" 2>/dev/null
exit_code_lw_scripts=$?
assert_eq "test_exits_zero_for_lockpick_workflow_scripts: exits 0 for scripts/*" "0" "$exit_code_lw_scripts"
assert_pass_if_clean "test_exits_zero_for_lockpick_workflow_scripts"

# ── test_exits_zero_for_lockpick_workflow_hooks ──────────────────────────────
_snapshot_fail
exit_code_lw_hooks=0
echo 'hooks/pre-commit' | bash "$CANONICAL" 2>/dev/null
exit_code_lw_hooks=$?
assert_eq "test_exits_zero_for_lockpick_workflow_hooks: exits 0 for hooks/*" "0" "$exit_code_lw_hooks"
assert_pass_if_clean "test_exits_zero_for_lockpick_workflow_hooks"

# ── test_exits_zero_for_lockpick_workflow_skills ──────────────────────────────
_snapshot_fail
exit_code_lw_skills=0
echo 'skills/some-skill.md' | bash "$CANONICAL" 2>/dev/null
exit_code_lw_skills=$?
assert_eq "test_exits_zero_for_lockpick_workflow_skills: exits 0 for skills/*" "0" "$exit_code_lw_skills"
assert_pass_if_clean "test_exits_zero_for_lockpick_workflow_skills"

# ── test_exits_zero_for_scripts_dir ──────────────────────────────────────────
_snapshot_fail
exit_code_scripts=0
echo 'scripts/some-script.sh' | bash "$CANONICAL" 2>/dev/null
exit_code_scripts=$?
assert_eq "test_exits_zero_for_scripts_dir: exits 0 for scripts/*" "0" "$exit_code_scripts"
assert_pass_if_clean "test_exits_zero_for_scripts_dir"

# ── test_exits_zero_for_pre_commit_config ────────────────────────────────────
_snapshot_fail
exit_code_precommit=0
echo '.pre-commit-config.yaml' | bash "$CANONICAL" 2>/dev/null
exit_code_precommit=$?
assert_eq "test_exits_zero_for_pre_commit_config: exits 0 for .pre-commit-config.yaml" "0" "$exit_code_precommit"
assert_pass_if_clean "test_exits_zero_for_pre_commit_config"

# ── test_exits_zero_for_makefile ─────────────────────────────────────────────
_snapshot_fail
exit_code_makefile=0
echo 'Makefile' | bash "$CANONICAL" 2>/dev/null
exit_code_makefile=$?
assert_eq "test_exits_zero_for_makefile: exits 0 for Makefile" "0" "$exit_code_makefile"
assert_pass_if_clean "test_exits_zero_for_makefile"

# ── test_exits_zero_for_app_makefile ─────────────────────────────────────────
_snapshot_fail
exit_code_app_makefile=0
echo 'app/Makefile' | bash "$CANONICAL" 2>/dev/null
exit_code_app_makefile=$?
assert_eq "test_exits_zero_for_app_makefile: exits 0 for app/Makefile" "0" "$exit_code_app_makefile"
assert_pass_if_clean "test_exits_zero_for_app_makefile"

# ── test_exits_nonzero_for_unrelated_file ────────────────────────────────────
# exits non-zero when no plugin-related files in the changed list
_snapshot_fail
exit_code_unrelated=0
echo 'app/src/some_module.py' | bash "$CANONICAL" 2>/dev/null && exit_code_unrelated=0 || exit_code_unrelated=$?
assert_ne "test_exits_nonzero_for_unrelated_file: exits non-zero for unrelated file" "0" "$exit_code_unrelated"
assert_pass_if_clean "test_exits_nonzero_for_unrelated_file"

# ── test_exits_nonzero_for_empty_input ───────────────────────────────────────
_snapshot_fail
exit_code_empty=0
echo '' | bash "$CANONICAL" 2>/dev/null && exit_code_empty=0 || exit_code_empty=$?
assert_ne "test_exits_nonzero_for_empty_input: exits non-zero for empty input" "0" "$exit_code_empty"
assert_pass_if_clean "test_exits_nonzero_for_empty_input"

# ── test_detects_workflow_file ────────────────────────────────────────────────
# Script name matches what the task calls "test_check_plugin_test_needed_detects_workflow_file"
# When a scripts/* file is in the list, exits 0
_snapshot_fail
exit_code_detect=0
echo 'scripts/check-plugin-test-needed.sh' | bash "$CANONICAL" 2>/dev/null
exit_code_detect=$?
assert_eq "test_check_plugin_test_needed_detects_workflow_file: detects scripts/* file" "0" "$exit_code_detect"
assert_pass_if_clean "test_check_plugin_test_needed_detects_workflow_file"

print_summary
