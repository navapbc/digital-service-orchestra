#!/usr/bin/env bash
# tests/scripts/test-retro-classification-step.sh
# Structural assertion tests for the Bug Classification step in retro/SKILL.md.
# Task ba47-c4ee-e481-4570 (RED phase): all tests fail until the step is added.

set -euo pipefail

REPO_ROOT=$(git rev-parse --show-toplevel)
# shellcheck source=tests/lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

TARGET_SKILL="$REPO_ROOT/plugins/dso/skills/retro/SKILL.md"

# ---------------------------------------------------------------------------
# Guard: if SKILL.md is missing entirely, fail all 7 tests and exit.
# ---------------------------------------------------------------------------
if [[ ! -f "$TARGET_SKILL" ]]; then
    for i in 1 2 3 4 5 6 7; do
        _snapshot_fail
        assert_contains "test_$i: SKILL.md not found" "SKILL.md present" ""
        assert_pass_if_clean "test_$i: SKILL.md not found"
    done
    print_summary
fi

SKILL_CONTENT=$(< "$TARGET_SKILL")

# ---------------------------------------------------------------------------
# Test 1: 'Bug Classification' text present
# ---------------------------------------------------------------------------
_snapshot_fail
assert_contains \
    "test_1: contains 'Bug Classification'" \
    "Bug Classification" \
    "$SKILL_CONTENT"
assert_pass_if_clean "test_1: contains 'Bug Classification'"

# ---------------------------------------------------------------------------
# Test 2: 'bug-classification-stats.sh' call present
# ---------------------------------------------------------------------------
_snapshot_fail
assert_contains \
    "test_2: contains 'bug-classification-stats.sh'" \
    "bug-classification-stats.sh" \
    "$SKILL_CONTENT"
assert_pass_if_clean "test_2: contains 'bug-classification-stats.sh'"

# ---------------------------------------------------------------------------
# Test 3: 'bug-type-uncategorized' labeled finding trigger
# ---------------------------------------------------------------------------
_snapshot_fail
assert_contains \
    "test_3: contains 'bug-type-uncategorized'" \
    "bug-type-uncategorized" \
    "$SKILL_CONTENT"
assert_pass_if_clean "test_3: contains 'bug-type-uncategorized'"

# ---------------------------------------------------------------------------
# Test 4: 'bug-type-classifier-failed' labeled finding trigger
# ---------------------------------------------------------------------------
_snapshot_fail
assert_contains \
    "test_4: contains 'bug-type-classifier-failed'" \
    "bug-type-classifier-failed" \
    "$SKILL_CONTENT"
assert_pass_if_clean "test_4: contains 'bug-type-classifier-failed'"

# ---------------------------------------------------------------------------
# Test 5: Exact health-check message present
# ---------------------------------------------------------------------------
_snapshot_fail
assert_contains \
    "test_5: contains exact health message" \
    "Bug classification health: no threshold breaches in this window." \
    "$SKILL_CONTENT"
assert_pass_if_clean "test_5: contains exact health message"

# ---------------------------------------------------------------------------
# Test 6: 'recurrence_threshold' or 'threshold' reference for slug count trigger
# ---------------------------------------------------------------------------
_snapshot_fail
if [[ "$SKILL_CONTENT" == *"recurrence_threshold"* ]] || [[ "$SKILL_CONTENT" == *"threshold"* ]]; then
    (( ++PASS ))
    echo "test_6: contains threshold reference ... PASS"
else
    (( ++FAIL ))
    printf "FAIL: test_6: contains threshold reference\n  expected to contain: recurrence_threshold or threshold\n" >&2
fi
assert_pass_if_clean "test_6: contains threshold reference"

# ---------------------------------------------------------------------------
# Test 7: Section is marked MANDATORY
# ---------------------------------------------------------------------------
_snapshot_fail
assert_contains \
    "test_7: section marked MANDATORY" \
    "MANDATORY" \
    "$SKILL_CONTENT"
assert_pass_if_clean "test_7: section marked MANDATORY"

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
print_summary
