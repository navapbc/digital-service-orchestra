#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-migration-completeness.sh
# RED PHASE tests for Phase 7 migration completeness.
#
# These tests MUST FAIL until the migration from .claude/skills/ and
# .claude/hooks/ to the lockpick-workflow plugin is complete.
#
# Tests:
#   test_migration_completeness_no_generic_skills
#   test_migration_completeness_no_generic_hooks
#   test_migration_completeness_settings_uses_plugin_paths
#   test_migration_completeness_script_paths_exist

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

# Skip unless explicitly requested — these are RED PHASE tests that track migration progress.
# They are expected to fail until the migration is complete.
if [[ "${RUN_RED_PHASE:-}" != "true" ]]; then
    echo "SKIPPED: Red-phase migration tests (set RUN_RED_PHASE=true to run)"
    echo ""
    echo "PASSED: 0  FAILED: 0"
    exit 0
fi

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# ============================================================
# (A) test_migration_completeness_no_generic_skills
#
# After migration, none of these generic workflow skill dirs
# should remain under .claude/skills/. They must have been
# removed (moved to lockpick-workflow/skills/ or deleted).
#
# MUST FAIL — these dirs currently exist.
# ============================================================

GENERIC_SKILLS=(
    batch-overlap-check
    design-review
    dev-onboarding
    dryrun
    end-session
    fix-cascade-recovery
    implementation-plan
    oscillation-check
    plan-review
    preplanning
    retro
    review-protocol
    roadmap
    sprint
    tdd-workflow
)

SKILLS_STILL_PRESENT=0
for skill in "${GENERIC_SKILLS[@]}"; do
    if [[ -d "$REPO_ROOT/.claude/skills/$skill" ]]; then
        (( SKILLS_STILL_PRESENT++ ))
    fi
done

assert_eq \
    "test_migration_completeness_no_generic_skills: no generic workflow skills remain in .claude/skills/" \
    "0" \
    "$SKILLS_STILL_PRESENT"

# ============================================================
# (B) test_migration_completeness_no_generic_hooks
#
# After migration, .claude/hooks/ should contain no .sh files
# (all hooks are now served by the plugin at lockpick-workflow/hooks/).
#
# MUST FAIL — .claude/hooks/*.sh files currently exist.
# ============================================================

HOOK_SH_COUNT=0
for f in "$REPO_ROOT"/.claude/hooks/*.sh; do
    [[ -f "$f" ]] && (( HOOK_SH_COUNT++ ))
done

assert_eq \
    "test_migration_completeness_no_generic_hooks: no .sh files remain in .claude/hooks/" \
    "0" \
    "$HOOK_SH_COUNT"

# ============================================================
# (C) test_migration_completeness_settings_uses_plugin_paths
#
# After migration, .claude/settings.json should:
#   - NOT reference .claude/hooks/ paths
#   - Reference ${CLAUDE_PLUGIN_ROOT} or lockpick-workflow paths
#
# MUST FAIL — settings.json currently references .claude/hooks/.
# ============================================================

SETTINGS_FILE="$REPO_ROOT/.claude/settings.json"

# Check that .claude/hooks/ is NOT referenced
OLD_HOOK_REFS=0
if grep -q '\.claude/hooks' "$SETTINGS_FILE" 2>/dev/null; then
    OLD_HOOK_REFS=1
fi

assert_eq \
    "test_migration_completeness_settings_uses_plugin_paths: settings.json does not reference .claude/hooks/" \
    "0" \
    "$OLD_HOOK_REFS"

# Check that plugin paths ARE referenced (lockpick-workflow/ relative paths)
PLUGIN_PATH_REFS=0
if grep -q 'lockpick-workflow/hooks' "$SETTINGS_FILE" 2>/dev/null; then
    PLUGIN_PATH_REFS=1
fi

assert_eq \
    "test_migration_completeness_settings_uses_plugin_paths: settings.json references lockpick-workflow/hooks" \
    "1" \
    "$PLUGIN_PATH_REFS"

# ============================================================
# (D) test_migration_completeness_script_paths_exist
#
# CLAUDE.md Quick Reference commands reference lockpick-workflow/scripts/.
# After migration, those scripts must exist at the plugin path.
#
# These should already PASS since the plugin scaffold (Phase 1)
# copied scripts. Included for completeness.
# ============================================================

EXPECTED_SCRIPTS=(
    "lockpick-workflow/scripts/validate.sh"
    "lockpick-workflow/scripts/ci-status.sh"
    "lockpick-workflow/scripts/orphaned-tasks.sh"
    "lockpick-workflow/scripts/toggle-tool-logging.sh"
    "lockpick-workflow/scripts/analyze-tool-use.py"
)

for script_path in "${EXPECTED_SCRIPTS[@]}"; do
    full_path="$REPO_ROOT/$script_path"
    EXISTS="no"
    [[ -f "$full_path" ]] && EXISTS="yes"
    assert_eq \
        "test_migration_completeness_script_paths_exist: $script_path exists" \
        "yes" \
        "$EXISTS"
done

# ============================================================
# Summary
# ============================================================

print_summary
