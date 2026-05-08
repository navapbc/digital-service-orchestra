#!/usr/bin/env bash
# tests/skills/test-sprint-retry-budget-dispatch.sh
# Structural boundary test for sprint SKILL.md Phase E sub-agent retry budget.
#
# Story: d853-bf07 — Sub-agent retry budget with model escalation
# Task:  9e42-e5a4
#
# Per behavioral-testing-standard.md Rule 5, instruction-file tests check the
# STRUCTURAL BOUNDARY — section headings and their required structural markers —
# not body-text wording. Each test asserts on the presence of a structural
# element that Phase E must contain after implementation.
#
# What we test (structural boundary — all absent in Phase E currently → RED):
#   1. Phase E contains the token MAX_ATTEMPTS in the context of parsing fields
#      from task descriptions (retry budget parsing).
#   2. Phase E contains an explicit list of parsed fields that includes MAX_ATTEMPTS
#      (the structured fields contract Phase E reads from task descriptions).
#   3. Phase E contains sonnet→opus escalation language scoped to the retry /
#      attempt loop (distinct from the existing red-test-writer tier escalation).
#
# Usage:
#   bash tests/skills/test-sprint-retry-budget-dispatch.sh

set -uo pipefail
# tests/skills/. -e is intentionally omitted: assert.sh tracks failures via counters and
# print_summary provides the final exit code. Adding -e would exit on the first assert_eq
# failure, suppressing remaining test output. pipefail is retained for subprocess errors.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-sprint-retry-budget-dispatch.sh ==="

# Helper: extract Phase E content (from "## Phase E" to the next "## Phase" heading).
_phase4_content() {
    awk '/^## Phase E/,/^## Phase [F-I]/' "$SKILL_FILE" 2>/dev/null
}

# ---------------------------------------------------------------------------
# test_sprint_phase4_max_attempts_parsing
#
# Given: sprint SKILL.md Phase E (Sub-Agent Launch) section
# When:  we look for MAX_ATTEMPTS as a parsed field from task descriptions
# Then:  the token MAX_ATTEMPTS must appear in Phase E (retry budget parsing)
#
# Structural boundary: presence of MAX_ATTEMPTS in Phase E is the interface
# contract — it signals that Phase E reads and honours this field when
# dispatching sub-agents.
#
# RED before implementation: Phase E does not mention MAX_ATTEMPTS at all.
# GREEN after implementation: MAX_ATTEMPTS appears in Phase E's parsing block.
# ---------------------------------------------------------------------------
test_sprint_phase4_max_attempts_parsing() {
    local phase4
    phase4=$(_phase4_content)

    local found=0
    echo "$phase4" | grep -q "MAX_ATTEMPTS" && found=1

    assert_eq \
        "test_sprint_phase4_max_attempts_parsing: MAX_ATTEMPTS token present in Phase E (retry budget parsing)" \
        "1" "$found"
}

# ---------------------------------------------------------------------------
# test_sprint_phase4_lists_parsed_fields
#
# Given: sprint SKILL.md Phase E section
# When:  we look for an explicit enumeration of fields read from task descriptions
#        that includes MAX_ATTEMPTS
# Then:  Phase E must contain a list or table that enumerates MAX_ATTEMPTS
#        alongside at least one other field name (establishes a "fields" contract)
#
# Structural boundary: the presence of a fields-list that includes MAX_ATTEMPTS
# is the contract that Phase E reads a structured set of fields from each task
# description. A bare mention of MAX_ATTEMPTS would satisfy test 1 but not this
# test — this test requires it appear in a listing/enumeration context.
#
# Acceptable patterns (any of these):
#   - A markdown list item: "- MAX_ATTEMPTS" or "* MAX_ATTEMPTS"
#   - A table row containing MAX_ATTEMPTS
#   - An inline enumeration: "..., MAX_ATTEMPTS, ..."
#
# RED before implementation: no such field list exists in Phase E.
# GREEN after implementation: Phase E enumerates the parsed fields including MAX_ATTEMPTS.
# ---------------------------------------------------------------------------
test_sprint_phase4_lists_parsed_fields() {
    local phase4
    phase4=$(_phase4_content)

    local found=0
    # Match MAX_ATTEMPTS in a list/table/enumeration context:
    #   markdown list item:  "- MAX_ATTEMPTS" / "* MAX_ATTEMPTS" / "1. MAX_ATTEMPTS"
    #   table cell:          "| MAX_ATTEMPTS" / "MAX_ATTEMPTS |"
    #   inline list element: ", MAX_ATTEMPTS" / "MAX_ATTEMPTS,"
    #   code block field:    "`MAX_ATTEMPTS`" in a fields/parameters block
    echo "$phase4" | grep -qE "^[[:space:]]*[-*].*MAX_ATTEMPTS|[|].*MAX_ATTEMPTS|MAX_ATTEMPTS.*[|]|,.*MAX_ATTEMPTS|MAX_ATTEMPTS.*,|\`MAX_ATTEMPTS\`" && found=1

    assert_eq \
        "test_sprint_phase4_lists_parsed_fields: MAX_ATTEMPTS appears in a fields enumeration (list/table) in Phase E" \
        "1" "$found"
}

# ---------------------------------------------------------------------------
# test_sprint_phase4_sonnet_opus_escalation
#
# Given: sprint SKILL.md Phase E section
# When:  we look for retry-budget-driven model escalation language (sonnet→opus)
# Then:  Phase E must describe escalating from sonnet to opus based on attempt
#        count or retry budget exhaustion for the dispatched sub-agent
#
# Structural boundary: both "sonnet" and "opus" must appear in Phase E in a
# context that connects them to retry/attempt logic — not just the existing
# red-test-writer tier escalation (which uses "Tier 3" language). The pattern
# requires the co-occurrence of (sonnet OR attempt/retry) AND opus near each
# other in Phase E.
#
# RED before implementation: Phase E lacks sub-agent retry/sonnet→opus escalation.
#   (The only existing Phase E opus reference is "Tier 3 — Re-dispatch
#   dso:red-test-writer (opus model override)", which is a red-test-writer
#   concern, not the sub-agent dispatch retry budget.)
# GREEN after implementation: Phase E contains language describing sonnet→opus
#   escalation tied to MAX_ATTEMPTS or retry-budget exhaustion for the task
#   sub-agent itself.
# ---------------------------------------------------------------------------
test_sprint_phase4_sonnet_opus_escalation() {
    local phase4
    phase4=$(_phase4_content)

    local found=0
    # Require that Phase E contains sonnet-to-opus escalation language in a
    # retry/attempt context tied to MAX_ATTEMPTS or retry budget — distinct from
    # the existing red-test-writer Tier 1/2/3 dispatch table.
    #
    # The specific structural contract: some block in Phase E must contain BOTH
    # "sonnet" (or "haiku") AND "opus" in the same region that also contains
    # "MAX_ATTEMPTS" or "retry" within a tight window. This ensures the test
    # only passes when the retry-budget escalation protocol is explicitly documented.
    #
    # This deliberately excludes the existing Tier 1/Tier 3 red-test-writer table
    # because those lines never mention MAX_ATTEMPTS or "retry budget".
    found=$(python3 -c "
import re, sys

content = open('$SKILL_FILE').read()

# Extract Phase E only (from '## Phase E' to next '## Phase N')
phase4_match = re.search(r'^## Phase E.*?(?=^## Phase [F-I])', content, re.MULTILINE | re.DOTALL)
if not phase4_match:
    print('0')
    sys.exit(0)

phase4 = phase4_match.group(0)

# A 400-character sliding window must contain ALL THREE:
#   1. 'MAX_ATTEMPTS' OR 'retry.*budget' OR 'budget.*retry'
#   2. a model tier word: 'sonnet' or 'haiku'
#   3. 'opus'
# This co-occurrence constraint ensures the test fires only when
# MAX_ATTEMPTS-driven model escalation is documented in Phase E.
step = 40
window_size = 400
for i in range(0, len(phase4), step):
    w = phase4[i:i+window_size]
    has_budget = bool(re.search(r'MAX_ATTEMPTS|retry.{0,20}budget|budget.{0,20}retry|attempt.{0,20}escalat', w, re.IGNORECASE))
    has_base   = bool(re.search(r'\bsonnet\b|\bhaiku\b', w, re.IGNORECASE))
    has_opus   = bool(re.search(r'\bopus\b', w, re.IGNORECASE))
    if has_budget and has_base and has_opus:
        print('1')
        sys.exit(0)

print('0')
" 2>/dev/null) || found=0

    assert_eq \
        "test_sprint_phase4_sonnet_opus_escalation: sonnet→opus escalation (retry-budget context) described in Phase E" \
        "1" "$found"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_sprint_phase4_max_attempts_parsing
test_sprint_phase4_lists_parsed_fields
test_sprint_phase4_sonnet_opus_escalation

print_summary

# ---------------------------------------------------------------------------
# Test-gate anchor block — literal test names for record-test-status.sh
# ---------------------------------------------------------------------------
_TEST_GATE_ANCHORS=(
    test_sprint_phase4_max_attempts_parsing
    test_sprint_phase4_lists_parsed_fields
    test_sprint_phase4_sonnet_opus_escalation
)
