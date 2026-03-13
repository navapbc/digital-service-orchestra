#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-design-wireframe-migration.sh
# Validates that design-wireframe skill has been migrated to lockpick-workflow/skills/
# and uses config-driven stack detection via adapter resolution instead of hardcoded patterns.
#
# Usage:
#   bash lockpick-workflow/tests/hooks/test-design-wireframe-migration.sh

REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

PLUGIN_SKILL="$REPO_ROOT/lockpick-workflow/skills/design-wireframe"
SOURCE_SKILL="$REPO_ROOT/.claude/skills/design-wireframe"
SKILL_MD="$PLUGIN_SKILL/SKILL.md"

# ─── Location tests ───────────────────────────────────────────────────────────

# test_skill_moved_to_plugin
# design-wireframe SKILL.md must exist in lockpick-workflow/skills/
if [[ -f "$SKILL_MD" ]]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_skill_moved_to_plugin" "exists" "$actual"

# test_source_skill_removed
# .claude/skills/design-wireframe/ must be removed from project (symlink to plugin is OK)
if [[ -d "$SOURCE_SKILL" && ! -L "$SOURCE_SKILL" ]]; then
    actual="still_present"
else
    actual="removed"
fi
assert_eq "test_source_skill_removed" "removed" "$actual"

# test_skill_md_nonempty
# Migrated SKILL.md must be non-empty
if [[ -f "$SKILL_MD" ]]; then
    size=$(wc -c < "$SKILL_MD")
    if (( size > 100 )); then
        actual="nonempty"
    else
        actual="empty_or_stub"
    fi
else
    actual="missing"
fi
assert_eq "test_skill_md_nonempty" "nonempty" "$actual"

# test_subdirs_copied
# docs/ and templates/ subdirectories must be present
for subdir in docs templates; do
    if [[ -d "$PLUGIN_SKILL/$subdir" ]]; then
        actual="exists"
    else
        actual="missing"
    fi
    assert_eq "test_subdirs_copied: $subdir" "exists" "$actual"
done

# ─── No hardcoded Flask patterns ──────────────────────────────────────────────

# test_no_hardcoded_component_globs
# The legacy hardcoded glob patterns (tsx, jsx, vue, svelte) must be removed.
# These should come from the adapter instead.
if [[ -f "$SKILL_MD" ]]; then
    if grep -q 'src/components/\*\*/\*\.{tsx,jsx,vue,svelte}' "$SKILL_MD"; then
        actual="hardcoded_globs_present"
    else
        actual="no_hardcoded_globs"
    fi
else
    actual="missing"
fi
assert_eq "test_no_hardcoded_component_globs" "no_hardcoded_globs" "$actual"

# test_no_hardcoded_blueprint_detection
# No direct pyproject.toml sniffing for Flask detection in the skill itself.
# Framework detection should come from the adapter's framework_detection section.
if [[ -f "$SKILL_MD" ]]; then
    if grep -q 'pyproject\.toml' "$SKILL_MD"; then
        actual="hardcoded_pyproject_reference"
    else
        actual="no_hardcoded_pyproject"
    fi
else
    actual="missing"
fi
assert_eq "test_no_hardcoded_blueprint_detection" "no_hardcoded_pyproject" "$actual"

# ─── Adapter resolution logic present ─────────────────────────────────────────

# test_references_read_config
# Skill must reference read-config.sh or resolve-stack-adapter.sh (which
# internally uses read-config.sh) for config-driven adapter resolution.
if [[ -f "$SKILL_MD" ]]; then
    if grep -qE 'read-config\.sh|resolve-stack-adapter\.sh' "$SKILL_MD"; then
        actual="references_read_config"
    else
        actual="no_read_config_reference"
    fi
else
    actual="missing"
fi
assert_eq "test_references_read_config" "references_read_config" "$actual"

# test_references_stack_adapter
# Skill must reference stack-adapters directory or adapter config
if [[ -f "$SKILL_MD" ]]; then
    if grep -q 'stack-adapter' "$SKILL_MD"; then
        actual="references_adapter"
    else
        actual="no_adapter_reference"
    fi
else
    actual="missing"
fi
assert_eq "test_references_adapter" "references_adapter" "$actual"

# test_references_component_file_patterns
# Skill must reference component_file_patterns from the adapter
if [[ -f "$SKILL_MD" ]]; then
    if grep -q 'component_file_patterns' "$SKILL_MD" || grep -q 'glob_patterns' "$SKILL_MD"; then
        actual="references_adapter_patterns"
    else
        actual="no_adapter_pattern_reference"
    fi
else
    actual="missing"
fi
assert_eq "test_references_component_file_patterns" "references_adapter_patterns" "$actual"

# ─── Graceful fallback ────────────────────────────────────────────────────────

# test_fallback_on_missing_adapter
# Skill must document fallback behavior when adapter config is missing
if [[ -f "$SKILL_MD" ]]; then
    if grep -qi 'fallback\|missing adapter\|no adapter\|generic file discovery\|warn' "$SKILL_MD"; then
        actual="has_fallback"
    else
        actual="no_fallback"
    fi
else
    actual="missing"
fi
assert_eq "test_fallback_on_missing_adapter" "has_fallback" "$actual"

# ─── Functional preservation ──────────────────────────────────────────────────

# test_preserves_complexity_triage
# Core skill logic must be preserved (complexity triage, lite/full tracks)
if [[ -f "$SKILL_MD" ]]; then
    if grep -q 'Complexity Triage' "$SKILL_MD" && grep -q 'Lite Track' "$SKILL_MD" && grep -q 'Full Track' "$SKILL_MD"; then
        actual="preserved"
    else
        actual="missing_core_logic"
    fi
else
    actual="missing"
fi
assert_eq "test_preserves_complexity_triage" "preserved" "$actual"

# test_preserves_phase_structure
# All 6 phases must be preserved
if [[ -f "$SKILL_MD" ]]; then
    phase_count=0
    for phase in "Phase 1" "Phase 2" "Phase 3" "Phase 4" "Phase 5" "Phase 6"; do
        if grep -q "$phase" "$SKILL_MD"; then
            (( phase_count++ ))
        fi
    done
    if [[ "$phase_count" -eq 6 ]]; then
        actual="all_phases"
    else
        actual="missing_phases_${phase_count}_of_6"
    fi
else
    actual="missing"
fi
assert_eq "test_preserves_phase_structure" "all_phases" "$actual"

# test_preserves_review_protocol
# Review protocol integration must be preserved
if [[ -f "$SKILL_MD" ]]; then
    if grep -q 'review-protocol' "$SKILL_MD"; then
        actual="preserved"
    else
        actual="missing"
    fi
else
    actual="missing"
fi
assert_eq "test_preserves_review_protocol" "preserved" "$actual"

print_summary
