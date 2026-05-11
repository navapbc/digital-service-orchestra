#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)
source "$REPO_ROOT/tests/lib/assert.sh"

_skill="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"
_skill_content=$(cat "$_skill")

# shellcheck disable=SC2016  # single quotes intentional: passing literal string, not expanding $PLUGIN_SCRIPTS
assert_contains "SKILL.md: SPRINT_MODE variable set from mode-detect.sh" \
    'SPRINT_MODE=$(bash "$PLUGIN_SCRIPTS/mode-detect.sh")' "$_skill_content"
assert_contains "SKILL.md: MODE: ci-pr banner" \
    "MODE: ci-pr" "$_skill_content"
assert_contains "SKILL.md: MODE: local banner" \
    "MODE: local — per-story PR mechanisms inactive" "$_skill_content"
assert_contains "SKILL.md: Mode Detection section heading" \
    "### Mode Detection" "$_skill_content"

print_summary
