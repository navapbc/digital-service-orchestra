#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-skill-copy-phase1.sh
# Verifies that all 14 workflow-generic skills have been copied to
# lockpick-workflow/skills/ with SKILL.md and subdirectory contents intact.
#
# Usage:
#   bash lockpick-workflow/tests/hooks/test-skill-copy-phase1.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

PLUGIN_SKILLS="$PLUGIN_ROOT/skills"
SOURCE_SKILLS="$REPO_ROOT/.claude/skills"

# The 14 workflow-generic skills that must be copied
SKILLS=(
    sprint
    plan-review
    review-protocol
    tdd-workflow
    fix-cascade-recovery
    oscillation-check
    implementation-plan
    roadmap
    dryrun
    batch-overlap-check
    retro
    end-session
    design-review
    dev-onboarding
)

# test_skills_dir_exists
# lockpick-workflow/skills/ directory must exist.
if [[ -d "$PLUGIN_SKILLS" ]]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_skills_dir_exists" "exists" "$actual"

# test_skill_md_exists
# Each skill must have a SKILL.md at lockpick-workflow/skills/{name}/SKILL.md.
for skill in "${SKILLS[@]}"; do
    if [[ -f "$PLUGIN_SKILLS/$skill/SKILL.md" ]]; then
        actual="exists"
    else
        actual="missing"
    fi
    assert_eq "test_skill_md_exists: $skill" "exists" "$actual"
done

# test_skill_md_nonempty
# Each copied SKILL.md must be non-empty (not a stub).
for skill in "${SKILLS[@]}"; do
    if [[ -f "$PLUGIN_SKILLS/$skill/SKILL.md" ]]; then
        size=$(wc -c < "$PLUGIN_SKILLS/$skill/SKILL.md")
        if (( size > 0 )); then
            actual="nonempty"
        else
            actual="empty"
        fi
    else
        actual="missing"
    fi
    assert_eq "test_skill_md_nonempty: $skill" "nonempty" "$actual"
done

# test_skill_subdirs_copied
# Skills with subdirectories must have those subdirs present in the plugin copy.
# Verified: sprint has prompts/, implementation-plan has docs/, roadmap has docs/, retro has docs/,
# preplanning has docs/, design-review has docs/, dev-onboarding has docs/.
# Note: Using parallel arrays instead of associative arrays for bash 3.x compatibility.
SKILL_SUBDIR_SKILLS=(sprint implementation-plan roadmap retro preplanning design-review dev-onboarding)
SKILL_SUBDIR_DIRS=(prompts docs docs docs docs docs docs)

for i in 0 1 2 3 4 5 6; do
    skill="${SKILL_SUBDIR_SKILLS[$i]}"
    subdir="${SKILL_SUBDIR_DIRS[$i]}"
    if [[ -d "$PLUGIN_SKILLS/$skill/$subdir" ]]; then
        actual="exists"
    else
        actual="missing"
    fi
    assert_eq "test_skill_subdirs_copied: $skill/$subdir" "exists" "$actual"
done

# test_source_skills_removed
# After Phase 7 migration, generic workflow skills should NOT remain in .claude/skills/.
# They have been moved to lockpick-workflow/skills/ (removal was the migration step).
# RED PHASE: Skip unless explicitly requested — expected to fail until migration is complete.
if [[ "${RUN_RED_PHASE:-}" == "true" ]]; then
    REMAINING_SOURCE_SKILLS=0
    for skill in "${SKILLS[@]}"; do
        if [[ -f "$SOURCE_SKILLS/$skill/SKILL.md" ]]; then
            (( REMAINING_SOURCE_SKILLS++ ))
        fi
    done
    assert_eq "test_source_skills_removed: no generic skills remain in .claude/skills/" "0" "$REMAINING_SOURCE_SKILLS"
fi

print_summary
