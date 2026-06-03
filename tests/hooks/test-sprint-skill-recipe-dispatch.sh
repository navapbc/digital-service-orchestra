#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)
source "$REPO_ROOT/tests/lib/assert.sh"

_skill="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"
_skill_content=$(cat "$_skill")

# Assert 1: The recipe: row in Phase E TESTING_MODE routing table references recipe-executor.sh
# shellcheck disable=SC2016  # single quotes intentional: passing literal string with backticks, not expanding variables
assert_contains "SKILL.md: recipe: row in TESTING_MODE routing table references recipe-executor.sh" \
    '| `recipe:` | Execute via `recipe-executor.sh` directly — no sub-agent dispatch.' "$_skill_content"

# Assert 2: The recipe: execution flow section header exists
assert_contains "SKILL.md: recipe: execution flow section header" \
    "**recipe: execution flow**:" "$_skill_content"

# Assert 3: The no-story-branch invariant for recipe: tasks
# shellcheck disable=SC2016  # single quotes intentional: passing literal string with backticks, not expanding variables
assert_contains "SKILL.md: recipe: tasks do NOT create a story branch invariant" \
    '`recipe:` tasks do NOT create a story branch.' "$_skill_content"

# Assert 4: The recipe-executor.sh invocation in the execution flow bash block
# shellcheck disable=SC2016  # single quotes intentional: passing literal string, not expanding $PLUGIN_SCRIPTS
assert_contains "SKILL.md: recipe-executor.sh invocation in execution flow bash block" \
    'bash "$PLUGIN_SCRIPTS/recipe-executor.sh" <recipe_name> [--param key=value ...]' "$_skill_content"

print_summary
