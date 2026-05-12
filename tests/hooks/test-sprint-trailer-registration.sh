#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)
source "$REPO_ROOT/tests/lib/assert.sh"

_cfg="$REPO_ROOT/.pre-commit-config.yaml"
_skill="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"

_cfg_content=$(cat "$_cfg")
_skill_content=$(cat "$_skill")

assert_contains "pre-commit config: sprint-trailer-check hook registered" \
    "sprint-trailer-check" "$_cfg_content"
assert_contains "pre-commit config: check-sprint-trailer.sh referenced" \
    "check-sprint-trailer.sh" "$_cfg_content"
assert_contains "sprint SKILL.md: DSO_SPRINT_MODE set before commit" \
    "DSO_SPRINT_MODE=1" "$_skill_content"
assert_contains "sprint SKILL.md: DSO_SPRINT_MODE unset after commit" \
    "unset DSO_SPRINT_MODE" "$_skill_content"

print_summary
