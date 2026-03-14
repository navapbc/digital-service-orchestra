#!/usr/bin/env bash
# lockpick-workflow/tests/plugin/test-plugin-docs-no-claude-skills-paths.sh
# Verifies that plugin documentation and template files do not reference
# .claude/skills/ — all such paths should use lockpick-workflow/skills/
# or CLAUDE_PLUGIN_ROOT/skills/.
#
# Tests:
#   test_no_claude_skills_in_docs
#   test_no_claude_skills_in_templates

REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# ============================================================
# test_no_claude_skills_in_docs
# ============================================================

echo "--- test_no_claude_skills_in_docs ---"

# Exclude MIGRATION-TO-PLUGIN.md — it documents the migration FROM .claude/skills/ and references are historical
DOCS_MATCHES=$(grep -rn '\.claude/skills/' "$REPO_ROOT/lockpick-workflow/docs/" --exclude='MIGRATION-TO-PLUGIN.md' 2>/dev/null || true)
assert_eq "no .claude/skills/ references in lockpick-workflow/docs/" "" "$DOCS_MATCHES"

# ============================================================
# test_no_claude_skills_in_templates
# ============================================================

echo "--- test_no_claude_skills_in_templates ---"

TEMPLATE_MATCHES=$(grep -rn '\.claude/skills/' "$REPO_ROOT/lockpick-workflow/templates/" 2>/dev/null || true)
assert_eq "no .claude/skills/ references in lockpick-workflow/templates/" "" "$TEMPLATE_MATCHES"

print_summary
