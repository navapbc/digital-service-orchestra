#!/usr/bin/env bash
# tests/hooks/test-scenario-sc-revision.sh
# Structural contract test: brainstorm SKILL.md must contain a scenario-driven SC revision
# step in the Epic Scrutiny Pipeline region (after Step 2.75 and before Step 4 Approval Gate).
#
# This is a Rule 5 structural boundary test (behavioral-testing-standard.md) for a
# non-executable instruction file. It validates required architectural markers that must
# be present when the feature is implemented.
#
# File under test: plugins/dso/skills/brainstorm/SKILL.md
#
# Observable behavior tested:
#   - SKILL.md contains a directive to revise success criteria when scenario analysis
#     reveals SC gaps, within the Epic Scrutiny Pipeline region
#   - SKILL.md requires a fresh AskUserQuestion re-approval (a new gate distinct from
#     Step 4) within that same region, for use after SC revision
#
# The scrutiny pipeline region is bounded by:
#   start: "### Steps 2.5, 2.6, 2.75, and Step 3: Epic Scrutiny Pipeline"
#   end:   "### Step 4: Approval Gate"
#
# RED phase: These markers do NOT exist in SKILL.md — test exits non-zero.
# GREEN phase: After implementation inserts the SC gap check step, test exits zero.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
SKILL_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/SKILL.md"

# skill-refactor: brainstorm phases extracted. Rebind SKILL_MD to aggregated corpus
# (SKILL.md + phases/*.md + verifiable-sc-check.md).
_orig_SKILL_MD="$SKILL_MD"
source "$(git rev-parse --show-toplevel)/tests/skills/lib/brainstorm-skill-aggregate.sh"
SKILL_MD=$(brainstorm_aggregate_path)
trap brainstorm_aggregate_cleanup EXIT


source "${REPO_ROOT}/tests/lib/assert.sh"

# Extract the scrutiny pipeline region: from the Epic Scrutiny Pipeline heading
# through (but not including) the Step 4 Approval Gate heading. The scrutiny
# pipeline's post-return handlers (SC gap check, FEASIBILITY_GAP, etc.) live in
# phases/post-scrutiny-handlers.md after the skill-refactor extraction, so
# include that phase file in the region.
_scrutiny_region() {
    awk '/^### Steps 2\.5, 2\.6, 2\.75, and Step 3: Epic Scrutiny Pipeline/,/^### Step 4: Approval Gate/' \
        "$_orig_SKILL_MD" 2>/dev/null
    local phases_file
    phases_file="$(dirname "$_orig_SKILL_MD")/phases/post-scrutiny-handlers.md"
    [ -f "$phases_file" ] && cat "$phases_file"
}

# ── test_brainstorm_has_sc_revision_after_scenario ──────────────────────────
# Contract: within the Epic Scrutiny Pipeline region (before Step 4), SKILL.md
# must instruct the agent to revise success criteria when scenario analysis
# findings reveal SC gaps.
#
# Acceptable markers:
#   - "revise the success criteria" / "revise success criteria"
#   - "update the success criteria" / "update success criteria"
#   - "SC revision" / "success criteria revision"
#   - "SC gap check" / "sc_gap_check"
#   - "success criteria gap" (any ordering)
#
# NOT acceptable (already present, not the new feature):
#   - "Update the Scenario Analysis section" (updates scenario output, not SCs)

test_brainstorm_has_sc_revision_after_scenario() {
    local region
    region=$(_scrutiny_region)

    # Rule 5 structural contract: assert that a section HEADING (not body prose)
    # for the SC gap check step exists in the scrutiny pipeline region.
    # Acceptable heading forms (case-insensitive):
    #   "#### SC Gap Check"  /  "#### SC Revision"  /  "#### Step 2.75"
    # A heading is a markdown heading line (starts with one or more '#').
    # This check is stable against body-text rewording — only heading removal
    # (i.e., removal of the feature itself) will cause it to fail.
    local heading_found=0

    if echo "$region" | grep -qiE "^#{1,6}[[:space:]].*SC[[:space:]]Gap"; then
        heading_found=1
    fi
    if echo "$region" | grep -qiE "^#{1,6}[[:space:]].*SC[[:space:]]Revision"; then
        heading_found=1
    fi
    # "Step 2.75" as a standalone step identifier in a heading signals the
    # SC gap check insertion point used by the task spec.
    if echo "$region" | grep -qE "^#{1,6}[[:space:]].*[Ss]tep[[:space:]]+2\.75[^,]"; then
        heading_found=1
    fi

    assert_eq \
        "SKILL.md contains SC gap check section heading in scrutiny pipeline region (before Step 4)" \
        "1" \
        "$heading_found"
}

# ── test_brainstorm_sc_revision_requires_reapproval ─────────────────────────
# Contract: within the Epic Scrutiny Pipeline region (before Step 4), SKILL.md
# must require a fresh AskUserQuestion re-approval gate after SC revision.
#
# Rationale: the existing Step 4 AskUserQuestion is the general approval gate
# for the full spec. When SCs are revised in response to scenario findings, the
# user must be re-asked specifically for that revision — a new gate in the
# scrutiny pipeline region, before Step 4.
#
# Assertion: AskUserQuestion appears at least once inside the scrutiny pipeline
# region (between the "### Steps 2.5..." heading and "### Step 4:" heading).

test_brainstorm_sc_revision_requires_reapproval() {
    local region
    region=$(_scrutiny_region)

    local ask_count
    ask_count=$(echo "$region" | grep -c "AskUserQuestion" 2>/dev/null)
    ask_count=${ask_count:-0}

    local has_reapproval=0
    if [ "$ask_count" -ge 1 ] 2>/dev/null; then
        has_reapproval=1
    fi

    assert_eq \
        "SKILL.md has AskUserQuestion for SC re-approval in scrutiny pipeline region (before Step 4)" \
        "1" \
        "$has_reapproval"
}

# ── Run tests ────────────────────────────────────────────────────────────────

test_brainstorm_has_sc_revision_after_scenario
test_brainstorm_sc_revision_requires_reapproval

print_summary
