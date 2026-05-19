#!/usr/bin/env bash
# tests/scripts/test-skill-classifier-integration.sh
# RED-phase structural tests: verify that SKILL.md files reference classify-bug-at-closure.
# Task S6-T3 (077c-6455-30e0-4f0e): all tests fail until the production changes are applied.
#
# Tests:
#   1. plugins/dso/skills/debug-everything/SKILL.md contains 'classify-bug-at-closure'
#   2. plugins/dso/skills/end-session/SKILL.md contains 'classify-bug-at-closure'
#   3. plugins/dso/skills/brainstorm/SKILL.md contains 'classify-bug-at-closure'
#   4. plugins/dso/skills/sprint/SKILL.md contains 'classify-bug-at-closure'
#   5. plugins/dso/skills/onboarding/SKILL.md contains 'classify-bug-at-closure' (skip if absent)

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)

# shellcheck source=tests/lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

HELPER="classify-bug-at-closure"

# ---------------------------------------------------------------------------
# Test 1: debug-everything/SKILL.md contains 'classify-bug-at-closure'
# ---------------------------------------------------------------------------
_snapshot_fail
skill_file="$REPO_ROOT/plugins/dso/skills/debug-everything/SKILL.md"
skill_content="$(cat "$skill_file")"
assert_contains \
    "debug-everything/SKILL.md references '$HELPER'" \
    "$HELPER" \
    "$skill_content"
assert_pass_if_clean "test_debug_everything_skill_references_helper"

# ---------------------------------------------------------------------------
# Test 2: end-session/SKILL.md contains 'classify-bug-at-closure'
# ---------------------------------------------------------------------------
_snapshot_fail
skill_file="$REPO_ROOT/plugins/dso/skills/end-session/SKILL.md"
skill_content="$(cat "$skill_file")"
assert_contains \
    "end-session/SKILL.md references '$HELPER'" \
    "$HELPER" \
    "$skill_content"
assert_pass_if_clean "test_end_session_skill_references_helper"

# ---------------------------------------------------------------------------
# Test 3: brainstorm/SKILL.md contains 'classify-bug-at-closure'
# ---------------------------------------------------------------------------
_snapshot_fail
skill_file="$REPO_ROOT/plugins/dso/skills/brainstorm/SKILL.md"
skill_content="$(cat "$skill_file")"
assert_contains \
    "brainstorm/SKILL.md references '$HELPER'" \
    "$HELPER" \
    "$skill_content"
assert_pass_if_clean "test_brainstorm_skill_references_helper"

# ---------------------------------------------------------------------------
# Test 4: sprint/SKILL.md contains 'classify-bug-at-closure'
# ---------------------------------------------------------------------------
_snapshot_fail
skill_file="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"
skill_content="$(cat "$skill_file")"
assert_contains \
    "sprint/SKILL.md references '$HELPER'" \
    "$HELPER" \
    "$skill_content"
assert_pass_if_clean "test_sprint_skill_references_helper"

# ---------------------------------------------------------------------------
# Test 5: onboarding/SKILL.md — check if present; skip gracefully if absent
# ---------------------------------------------------------------------------
_snapshot_fail
skill_file="$REPO_ROOT/plugins/dso/skills/onboarding/SKILL.md"
if [[ -f "$skill_file" ]]; then
    skill_content="$(cat "$skill_file")"
    assert_contains \
        "onboarding/SKILL.md references '$HELPER'" \
        "$HELPER" \
        "$skill_content"
else
    echo "onboarding/SKILL.md not found — skipping (counted as PASS)"
    (( ++PASS ))
fi
assert_pass_if_clean "test_onboarding_skill_references_helper_or_absent"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary
