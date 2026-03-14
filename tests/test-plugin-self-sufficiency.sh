#!/usr/bin/env bash
# lockpick-workflow/tests/test-plugin-self-sufficiency.sh
# Validates that the lockpick-workflow plugin is self-sufficient:
# a new project can adopt it without copying files from .claude/.
#
# Tests:
#   test_no_skill_duplication
#   test_symlinks_resolve_to_plugin
#   test_no_commands_overrides
#   test_reference_docs_in_plugin
#   test_config_schema_complete
#   test_required_skills_resolvable
#   test_migrated_scripts_in_plugin

REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# ============================================================
# (A) test_no_skill_duplication
#
# Skills present in both .claude/skills/ and lockpick-workflow/skills/
# must be symlinks, not independent copies.
# ============================================================

echo "--- test_no_skill_duplication ---"

DUPLICATE_COPIES=()
for skill_dir in "$REPO_ROOT"/lockpick-workflow/skills/*/; do
    skill_name="$(basename "$skill_dir")"
    project_skill="$REPO_ROOT/.claude/skills/$skill_name"
    # A duplicate exists when:
    #   1. The project has a non-symlink dir for this skill, AND
    #   2. The plugin version has a SKILL.md (is a real skill, not just a prompts shell)
    # Stack-coupled skills (project-only SKILL.md, plugin has only prompts/) are NOT duplicates.
    if [[ -d "$project_skill" && ! -L "$project_skill" \
          && -f "$skill_dir/SKILL.md" ]]; then
        DUPLICATE_COPIES+=("$skill_name")
    fi
done

assert_eq "no skill duplication (non-symlink copies)" "0" "${#DUPLICATE_COPIES[@]}"
if [[ ${#DUPLICATE_COPIES[@]} -gt 0 ]]; then
    printf "  duplicated skills: %s\n" "${DUPLICATE_COPIES[*]}" >&2
fi

# ============================================================
# (B) test_symlinks_resolve_to_plugin
#
# Every symlink in .claude/skills/ that points into
# lockpick-workflow/skills/ must resolve to an existing target.
# ============================================================

echo "--- test_symlinks_resolve_to_plugin ---"

BROKEN_SYMLINKS=()
for link in "$REPO_ROOT"/.claude/skills/*; do
    if [[ -L "$link" ]]; then
        target="$(readlink "$link")"
        # Only check links that point into lockpick-workflow
        if [[ "$target" == *lockpick-workflow* ]]; then
            # Resolve relative to the symlink's directory
            resolved="$(cd "$(dirname "$link")" && realpath -q "$target" 2>/dev/null || echo "")"
            if [[ -z "$resolved" || ! -e "$resolved" ]]; then
                BROKEN_SYMLINKS+=("$(basename "$link") -> $target")
            fi
        fi
    fi
done

assert_eq "no broken plugin symlinks" "0" "${#BROKEN_SYMLINKS[@]}"
if [[ ${#BROKEN_SYMLINKS[@]} -gt 0 ]]; then
    for b in "${BROKEN_SYMLINKS[@]}"; do
        printf "  broken: %s\n" "$b" >&2
    done
fi

# ============================================================
# (C) test_no_commands_overrides
#
# .claude/commands/ should not exist — all commands resolve
# through the plugin's command registration.
# ============================================================

echo "--- test_no_commands_overrides ---"

if [[ -d "$REPO_ROOT/.claude/commands" ]]; then
    CMD_COUNT="$(find "$REPO_ROOT/.claude/commands" -type f 2>/dev/null | wc -l | tr -d ' ')"
else
    CMD_COUNT="0"
fi

assert_eq "no .claude/commands/ overrides" "0" "$CMD_COUNT"

# ============================================================
# (D) test_reference_docs_in_plugin
#
# Core workflow reference docs must live in lockpick-workflow/docs/,
# not only in .claude/docs/.
# ============================================================

echo "--- test_reference_docs_in_plugin ---"

REQUIRED_DOCS=(
    SUB-AGENT-BOUNDARIES.md
    WORKTREE-GUIDE.md
    MODEL-TIERS.md
    RESEARCH-PATTERN.md
    PLAN-APPROVAL-WORKFLOW.md
    DEPENDENCY-GUIDANCE.md
)

MISSING_DOCS=()
for doc in "${REQUIRED_DOCS[@]}"; do
    if [[ ! -f "$REPO_ROOT/lockpick-workflow/docs/$doc" ]]; then
        MISSING_DOCS+=("$doc")
    fi
done

assert_eq "all reference docs in plugin" "0" "${#MISSING_DOCS[@]}"
if [[ ${#MISSING_DOCS[@]} -gt 0 ]]; then
    printf "  missing docs: %s\n" "${MISSING_DOCS[*]}" >&2
fi

# Also check that workflow docs are in plugin
REQUIRED_WORKFLOW_DOCS=(
    COMMIT-WORKFLOW.md
    REVIEW-WORKFLOW.md
    TEST-FAILURE-DISPATCH.md
)

MISSING_WF_DOCS=()
for doc in "${REQUIRED_WORKFLOW_DOCS[@]}"; do
    if [[ ! -f "$REPO_ROOT/lockpick-workflow/docs/workflows/$doc" ]]; then
        MISSING_WF_DOCS+=("$doc")
    fi
done

assert_eq "all workflow docs in plugin" "0" "${#MISSING_WF_DOCS[@]}"
if [[ ${#MISSING_WF_DOCS[@]} -gt 0 ]]; then
    printf "  missing workflow docs: %s\n" "${MISSING_WF_DOCS[*]}" >&2
fi

# ============================================================
# (E) test_config_schema_complete
#
# The workflow-config-schema.json must have entries for all
# required config sections.
# ============================================================

echo "--- test_config_schema_complete ---"

SCHEMA_FILE="$REPO_ROOT/lockpick-workflow/docs/workflow-config-schema.json"
REQUIRED_SECTIONS=(commands tickets design jira)

MISSING_SECTIONS=()
for section in "${REQUIRED_SECTIONS[@]}"; do
    if ! grep -q "\"$section\"" "$SCHEMA_FILE" 2>/dev/null; then
        MISSING_SECTIONS+=("$section")
    fi
done

assert_eq "config schema has all required sections" "0" "${#MISSING_SECTIONS[@]}"
if [[ ${#MISSING_SECTIONS[@]} -gt 0 ]]; then
    printf "  missing schema sections: %s\n" "${MISSING_SECTIONS[*]}" >&2
fi

# ============================================================
# (F) test_required_skills_resolvable
#
# Specific skills required by the acceptance criteria must be
# accessible via .claude/skills/ (either as symlinks or dirs).
# ============================================================

echo "--- test_required_skills_resolvable ---"

REQUIRED_SKILLS=(
    interface-contracts
    resolve-conflicts
    tickets-health
    design-onboarding
    design-review
)

UNRESOLVABLE_SKILLS=()
for skill in "${REQUIRED_SKILLS[@]}"; do
    if [[ ! -f "$REPO_ROOT/.claude/skills/$skill/SKILL.md" ]]; then
        UNRESOLVABLE_SKILLS+=("$skill")
    fi
done

assert_eq "all required skills resolvable" "0" "${#UNRESOLVABLE_SKILLS[@]}"
if [[ ${#UNRESOLVABLE_SKILLS[@]} -gt 0 ]]; then
    printf "  unresolvable skills: %s\n" "${UNRESOLVABLE_SKILLS[*]}" >&2
fi

# ============================================================
# (G) test_migrated_scripts_in_plugin
#
# All migrated scripts must:
#   1. Exist in lockpick-workflow/scripts/ and be executable
#   2. Have thin wrappers (< 15 lines) in scripts/
#   3. Each wrapper must contain `exec` delegation keyword
# ============================================================

echo "--- test_migrated_scripts_in_plugin ---"

MIGRATED_SCRIPTS=(
    write-blackboard.sh
    collect-discoveries.sh
    issue-quality-check.sh
    check-acceptance-criteria.sh
    issue-summary.sh
    check-onboarding.sh
    semantic-conflict-check.py
    worktree-sync-from-main.sh
    enrich-file-impact.sh
    sprint-next-batch.sh
    agent-batch-lifecycle.sh
    check-local-env.sh
    ci-create-failure-bug.sh
    pre-commit-executable-guard.sh
    report-flaky-tests.sh
    worktree-create.sh
    audit-skill-resolution.sh
    bench-tk-ready.sh
)

# 1. Check each script exists in plugin and is executable
for script in "${MIGRATED_SCRIPTS[@]}"; do
    assert_eq "migrated script $script in plugin" "true" \
        "$(test -x "$REPO_ROOT/lockpick-workflow/scripts/$script" && echo true || echo false)"
done

# 2. Check each wrapper in scripts/ is thin (< 15 lines)
for script in "${MIGRATED_SCRIPTS[@]}"; do
    wrapper="$REPO_ROOT/scripts/$script"
    if [[ -f "$wrapper" ]]; then
        line_count="$(wc -l < "$wrapper" | tr -d ' ')"
        assert_eq "wrapper $script is thin (< 15 lines, got $line_count)" "true" \
            "$( [[ $line_count -lt 15 ]] && echo true || echo false )"
    else
        assert_eq "wrapper $script exists" "true" "false"
    fi
done

# 3. Check each wrapper contains exec delegation
for script in "${MIGRATED_SCRIPTS[@]}"; do
    wrapper="$REPO_ROOT/scripts/$script"
    if [[ -f "$wrapper" ]]; then
        assert_eq "wrapper $script contains exec" "true" \
            "$(grep -q 'exec' "$wrapper" && echo true || echo false)"
    fi
done

# ============================================================
# (H2) test_command_resolution
#
# All project-referenced commands (/commit, /end, /review) must
# resolve to a project-owned artifact — not rely on external plugins.
# ============================================================

echo "--- test_command_resolution ---"

REQUIRED_COMMANDS=(commit end review)
UNRESOLVED_COMMANDS=()

for cmd in "${REQUIRED_COMMANDS[@]}"; do
    found=false
    # Check all locations where a project command can live
    for path in \
        "$REPO_ROOT/.claude/commands/$cmd.md" \
        "$REPO_ROOT/lockpick-workflow/commands/$cmd.md" \
        "$REPO_ROOT/lockpick-workflow/skills/$cmd/SKILL.md"; do
        if [[ -f "$path" ]]; then
            found=true
            break
        fi
    done
    if [[ "$found" == "false" ]]; then
        UNRESOLVED_COMMANDS+=("$cmd")
    fi
done

assert_eq "all commands resolve to project artifacts" "0" "${#UNRESOLVED_COMMANDS[@]}"
if [[ ${#UNRESOLVED_COMMANDS[@]} -gt 0 ]]; then
    printf "  unresolved commands: %s\n" "${UNRESOLVED_COMMANDS[*]}" >&2
fi

# ============================================================
# (H) test_plugin_internal_references_use_plugin_paths
#
# Plugin skills and hooks must reference migrated scripts via
# plugin-internal paths ($PLUGIN_SCRIPTS/ or sibling paths),
# NOT via $REPO_ROOT/scripts/ wrapper indirection.
# ============================================================

echo "--- test_plugin_internal_references_use_plugin_paths ---"

# agent-batch-lifecycle.sh: no $REPO_ROOT/scripts/ references in skills or hooks
WRAPPER_REFS=$(grep -r '\$REPO_ROOT/scripts/agent-batch-lifecycle\.sh' \
    "$REPO_ROOT/lockpick-workflow/skills/" \
    "$REPO_ROOT/lockpick-workflow/hooks/" 2>/dev/null | wc -l | tr -d ' ')

assert_eq "no wrapper-path references to agent-batch-lifecycle.sh in plugin skills/hooks" "0" "$WRAPPER_REFS"
if [[ "$WRAPPER_REFS" -gt 0 ]]; then
    grep -rn '\$REPO_ROOT/scripts/agent-batch-lifecycle\.sh' \
        "$REPO_ROOT/lockpick-workflow/skills/" \
        "$REPO_ROOT/lockpick-workflow/hooks/" 2>/dev/null | head -5 >&2
fi

# ============================================================
# Summary
# ============================================================

print_summary
