#!/usr/bin/env bash
# tests/scripts/test-sprint-planner-dispatch-wiring.sh
# End-to-end fixture for the verification-remediation-planner dispatch wiring
# at three sites in plugins/dso/skills/sprint/SKILL.md:
#   1. Phase F Step 18 (story-level P1 != PASS)
#   2. Phase G Step 2 (epic-level P1 != PASS)
#   3. d039-ac65 re-dispatch site (re-invocation of verifier within Phase F Step 18)
#
# Asserts the SC3 caller-side contract from story f63c-1ca6-b210-4fa5:
# - On P1 != PASS, the orchestrator dispatches dso:verification-remediation-planner
#   BEFORE any remediation ticket is created.
# - When the planner returns confidence != LOW, the orchestrator routes to the
#   indicated decomposer with decomposer_context.
# - When the planner returns confidence == LOW (or scope == PROTOCOL_ERROR),
#   the orchestrator emits HALT_FOR_USER surfacing the planner's evidence.
# - The no-ticket-creation invariant: no .claude/scripts/dso ticket create call
#   appears between the verifier-output read and the planner-output read at any
#   of the three sites.
# - The 4 decision-tree branches (replan_story, new_tasks_in_story,
#   new_story_in_epic, replan_epic) each route to the correct downstream
#   decomposer per the routing table.
#
# Usage: bash tests/scripts/test-sprint-planner-dispatch-wiring.sh
# testing-mode: GREEN

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"

source "$REPO_ROOT/tests/lib/assert.sh"

SKILL_FILE="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"
PLANNER_AGENT="$REPO_ROOT/plugins/dso/agents/verification-remediation-planner.md"
FIXTURES_DIR="$REPO_ROOT/tests/fixtures/verification-remediation-planner"

echo "=== test-sprint-planner-dispatch-wiring.sh ==="

# Sanity: required files exist
test_required_files_present() {
    _snapshot_fail
    if [[ -f "$SKILL_FILE" ]]; then
        assert_eq "test_required_files_present: sprint SKILL.md exists" "exists" "exists"
    else
        assert_eq "test_required_files_present: sprint SKILL.md exists" "exists" "missing"
    fi
    if [[ -f "$PLANNER_AGENT" ]]; then
        assert_eq "test_required_files_present: planner agent file exists" "exists" "exists"
    else
        assert_eq "test_required_files_present: planner agent file exists" "exists" "missing"
    fi
    assert_pass_if_clean "test_required_files_present"
}

# Site 1 (Phase F Step 18 — story-level): planner-dispatch HARD-GATE present
test_site1_phase_f_step_18_planner_gate_present() {
    _snapshot_fail
    # Locate the HARD-GATE block identified by id="planner-dispatch-story-level"
    if grep -q '<HARD-GATE id="planner-dispatch-story-level">' "$SKILL_FILE"; then
        assert_eq "test_site1: HARD-GATE planner-dispatch-story-level present" "present" "present"
    else
        assert_eq "test_site1: HARD-GATE planner-dispatch-story-level present" "present" "missing"
    fi
    # Must dispatch dso:verification-remediation-planner inside the block
    # Extract block content between the opening and closing HARD-GATE
    block=$(awk '/<HARD-GATE id="planner-dispatch-story-level">/,/<\/HARD-GATE>/' "$SKILL_FILE")
    if [[ "$block" == *"dso:verification-remediation-planner"* ]]; then
        assert_eq "test_site1: dispatch references dso:verification-remediation-planner" "present" "present"
    else
        assert_eq "test_site1: dispatch references dso:verification-remediation-planner" "present" "missing"
    fi
    # Must include VERIFIER_ARTIFACT_PATH, STORY_ID, EPIC_ID prompt arguments
    if [[ "$block" == *"VERIFIER_ARTIFACT_PATH"* && "$block" == *"STORY_ID"* && "$block" == *"EPIC_ID"* ]]; then
        assert_eq "test_site1: prompt includes VERIFIER_ARTIFACT_PATH/STORY_ID/EPIC_ID" "present" "present"
    else
        assert_eq "test_site1: prompt includes VERIFIER_ARTIFACT_PATH/STORY_ID/EPIC_ID" "present" "missing"
    fi
    # Must include HALT_FOR_USER path for LOW confidence
    if [[ "$block" == *"HALT_FOR_USER"* && "$block" == *"LOW"* ]]; then
        assert_eq "test_site1: HALT_FOR_USER on confidence==LOW path" "present" "present"
    else
        assert_eq "test_site1: HALT_FOR_USER on confidence==LOW path" "present" "missing"
    fi
    assert_pass_if_clean "test_site1_phase_f_step_18_planner_gate_present"
}

# Site 2 (Phase G Step 2 — epic-level): planner-dispatch HARD-GATE present
test_site2_phase_g_step_2_planner_gate_present() {
    _snapshot_fail
    if grep -q '<HARD-GATE id="planner-dispatch-epic-level">' "$SKILL_FILE"; then
        assert_eq "test_site2: HARD-GATE planner-dispatch-epic-level present" "present" "present"
    else
        assert_eq "test_site2: HARD-GATE planner-dispatch-epic-level present" "present" "missing"
    fi
    block=$(awk '/<HARD-GATE id="planner-dispatch-epic-level">/,/<\/HARD-GATE>/' "$SKILL_FILE")
    if [[ "$block" == *"dso:verification-remediation-planner"* ]]; then
        assert_eq "test_site2: dispatch references dso:verification-remediation-planner" "present" "present"
    else
        assert_eq "test_site2: dispatch references dso:verification-remediation-planner" "present" "missing"
    fi
    if [[ "$block" == *"VERIFIER_ARTIFACT_PATH"* && "$block" == *"STORY_ID"* && "$block" == *"EPIC_ID"* ]]; then
        assert_eq "test_site2: prompt includes VERIFIER_ARTIFACT_PATH/STORY_ID/EPIC_ID" "present" "present"
    else
        assert_eq "test_site2: prompt includes VERIFIER_ARTIFACT_PATH/STORY_ID/EPIC_ID" "present" "missing"
    fi
    if [[ "$block" == *"HALT_FOR_USER"* && "$block" == *"LOW"* ]]; then
        assert_eq "test_site2: HALT_FOR_USER on confidence==LOW path" "present" "present"
    else
        assert_eq "test_site2: HALT_FOR_USER on confidence==LOW path" "present" "missing"
    fi
    assert_pass_if_clean "test_site2_phase_g_step_2_planner_gate_present"
}

# Site 3 (d039-ac65 re-dispatch): the d039-ac65 paragraph explicitly states the
# planner gate applies to the re-dispatched verdict as well. The site reuses
# Phase F Step 18's plumbing, but the consideration #3 requires that the third
# dispatch path is explicitly covered (not silently dropped).
test_site3_d039_ac65_redispatch_covers_planner() {
    _snapshot_fail
    # Find the d039-ac65 paragraph
    if grep -q "d039-ac65" "$SKILL_FILE"; then
        assert_eq "test_site3: d039-ac65 site exists" "present" "present"
    else
        assert_eq "test_site3: d039-ac65 site exists" "present" "missing"
    fi
    # The d039-ac65 paragraph must mention the Planner-dispatch HARD-GATE
    # applying to the re-dispatched verdict.
    paragraph=$(grep -E "d039-ac65" "$SKILL_FILE" | head -1)
    if [[ "$paragraph" == *"Planner-dispatch HARD-GATE"* || "$paragraph" == *"dso:verification-remediation-planner"* ]]; then
        assert_eq "test_site3: d039-ac65 references planner gate" "present" "present"
    else
        assert_eq "test_site3: d039-ac65 references planner gate" "present" "missing"
    fi
    # Must explicitly state the re-dispatch is NOT a bypass
    if [[ "$paragraph" == *"re-dispatch"* && ( "$paragraph" == *"NOT bypass"* || "$paragraph" == *"does NOT bypass"* || "$paragraph" == *"same invariant"* ) ]]; then
        assert_eq "test_site3: re-dispatch not bypass affirmed" "present" "present"
    else
        assert_eq "test_site3: re-dispatch not bypass affirmed" "present" "missing"
    fi
    assert_pass_if_clean "test_site3_d039_ac65_redispatch_covers_planner"
}

# CRITICAL invariant: no `.claude/scripts/dso ticket create` (or equivalent
# ticket-mutating CLI) appears AS AN EXECUTABLE BASH COMMAND between the
# verifier-output write and the planner-output read at any of the three sites.
#
# Implementation: at each site's HARD-GATE block, extract the text between the
# FIRST line containing VERIFIER_JSON_PATH (verifier write step) and the FIRST
# line containing PLANNER_JSON_PATH (planner read step). Then extract ONLY
# the contents of ```bash code fences within that window — prose mentions of
# the prohibited commands (e.g., "MUST NOT invoke `.claude/scripts/dso ticket
# create`") are intentional documentation and must not be flagged. Within
# the extracted bash code, assert no actual ticket-mutating invocation.
extract_bash_code_in_window() {
    # Reads stdin (a markdown window) and emits only the lines inside ```bash
    # fenced blocks (excluding the fence markers themselves).
    awk '
        /^```bash[[:space:]]*$/ { in_bash=1; next }
        /^```[[:space:]]*$/ { in_bash=0; next }
        in_bash { print }
    '
}

test_no_ticket_creation_between_verifier_and_planner_site1() {
    _snapshot_fail
    block=$(awk '/<HARD-GATE id="planner-dispatch-story-level">/,/<\/HARD-GATE>/' "$SKILL_FILE")
    # Window from the FIRST mention of VERIFIER_JSON_PATH (write step) to the
    # FIRST mention of PLANNER_JSON_PATH (read step).
    window=$(awk '
        /VERIFIER_JSON_PATH/ && !started { started=1 }
        started { print }
        /PLANNER_JSON_PATH/ && started { exit }
    ' <<<"$block")
    if [[ -z "$window" ]]; then
        assert_eq "test_site1_no_ticket_creation: window extractable" "extractable" "empty"
    else
        assert_eq "test_site1_no_ticket_creation: window extractable" "extractable" "extractable"
    fi
    # Extract ONLY the bash code from within the window — prose mentions of
    # prohibited commands are documentation and must not be flagged.
    bash_code=$(echo "$window" | extract_bash_code_in_window)
    if [[ "$bash_code" == *"ticket create"* ]]; then
        assert_eq "test_site1_no_ticket_creation: no 'ticket create' bash invocation" "absent" "present"
    else
        assert_eq "test_site1_no_ticket_creation: no 'ticket create' bash invocation" "absent" "absent"
    fi
    if [[ "$bash_code" == *"ticket comment"* ]]; then
        assert_eq "test_site1_no_ticket_creation: no 'ticket comment' bash invocation" "absent" "present"
    else
        assert_eq "test_site1_no_ticket_creation: no 'ticket comment' bash invocation" "absent" "absent"
    fi
    # Also assert the window prose contains the explicit prohibition (so the
    # rule is documented, not merely implied).
    if [[ "$window" == *"MUST NOT"* || "$window" == *"Do NOT call"* ]]; then
        assert_eq "test_site1_no_ticket_creation: prohibition documented in window" "documented" "documented"
    else
        assert_eq "test_site1_no_ticket_creation: prohibition documented in window" "documented" "absent"
    fi
    assert_pass_if_clean "test_no_ticket_creation_between_verifier_and_planner_site1"
}

test_no_ticket_creation_between_verifier_and_planner_site2() {
    _snapshot_fail
    block=$(awk '/<HARD-GATE id="planner-dispatch-epic-level">/,/<\/HARD-GATE>/' "$SKILL_FILE")
    window=$(awk '
        /VERIFIER_JSON_PATH/ && !started { started=1 }
        started { print }
        /PLANNER_JSON_PATH/ && started { exit }
    ' <<<"$block")
    if [[ -z "$window" ]]; then
        assert_eq "test_site2_no_ticket_creation: window extractable" "extractable" "empty"
    else
        assert_eq "test_site2_no_ticket_creation: window extractable" "extractable" "extractable"
    fi
    bash_code=$(echo "$window" | extract_bash_code_in_window)
    if [[ "$bash_code" == *"ticket create"* ]]; then
        assert_eq "test_site2_no_ticket_creation: no 'ticket create' bash invocation" "absent" "present"
    else
        assert_eq "test_site2_no_ticket_creation: no 'ticket create' bash invocation" "absent" "absent"
    fi
    if [[ "$bash_code" == *"ticket comment"* ]]; then
        assert_eq "test_site2_no_ticket_creation: no 'ticket comment' bash invocation" "absent" "present"
    else
        assert_eq "test_site2_no_ticket_creation: no 'ticket comment' bash invocation" "absent" "absent"
    fi
    if [[ "$window" == *"MUST NOT"* || "$window" == *"Do NOT call"* ]]; then
        assert_eq "test_site2_no_ticket_creation: prohibition documented in window" "documented" "documented"
    else
        assert_eq "test_site2_no_ticket_creation: prohibition documented in window" "documented" "absent"
    fi
    assert_pass_if_clean "test_no_ticket_creation_between_verifier_and_planner_site2"
}

# Site 3 (re-dispatch) reuses Site 1's plumbing, so the same window assertion
# at Site 1 covers Site 3 — but we verify the d039-ac65 paragraph asserts
# this explicitly so the invariant cannot drift on re-invocation.
test_no_ticket_creation_site3_d039_covered_by_site1() {
    _snapshot_fail
    paragraph=$(grep -E "d039-ac65" "$SKILL_FILE" | head -1)
    # Must affirm the planner gate applies to re-dispatched verdicts
    # (which means Site 1's no-ticket-creation window applies on re-invocation).
    if [[ "$paragraph" == *"same invariant"* || "$paragraph" == *"does NOT bypass"* ]]; then
        assert_eq "test_site3_no_ticket_creation: covered by Site 1 plumbing assertion" "covered" "covered"
    else
        assert_eq "test_site3_no_ticket_creation: covered by Site 1 plumbing assertion" "covered" "uncovered"
    fi
    assert_pass_if_clean "test_no_ticket_creation_site3_d039_covered_by_site1"
}

# Decision-tree routing fixture: all four branches (replan_story,
# new_tasks_in_story, new_story_in_epic, replan_epic) must each map to a
# distinct downstream dispatch in the SKILL.md routing table.
test_routing_replan_story_to_implementation_plan() {
    _snapshot_fail
    fixture="$FIXTURES_DIR/fixture-replan-story.json"
    if [[ ! -f "$fixture" ]]; then
        assert_eq "test_routing_replan_story: fixture exists" "exists" "missing"
        assert_pass_if_clean "test_routing_replan_story_to_implementation_plan"
        return
    fi
    # Planner would emit scope=replan_story for this verifier output.
    # SKILL.md routing table at both sites must map replan_story -> /dso:implementation-plan.
    # Single quotes are intentional — the pattern contains literal backticks and slashes,
    # and we want no shell expansion.
    # shellcheck disable=SC2016
    if grep -E '\| `replan_story` \| `/dso:implementation-plan' "$SKILL_FILE" >/dev/null; then
        assert_eq "test_routing_replan_story: replan_story -> /dso:implementation-plan" "present" "present"
    else
        assert_eq "test_routing_replan_story: replan_story -> /dso:implementation-plan" "present" "missing"
    fi
    assert_pass_if_clean "test_routing_replan_story_to_implementation_plan"
}

test_routing_new_tasks_in_story_to_planner_supplied() {
    _snapshot_fail
    fixture="$FIXTURES_DIR/fixture-new-tasks.json"
    if [[ ! -f "$fixture" ]]; then
        assert_eq "test_routing_new_tasks: fixture exists" "exists" "missing"
        assert_pass_if_clean "test_routing_new_tasks_in_story_to_planner_supplied"
        return
    fi
    # new_tasks_in_story -> orchestrator creates tasks directly (planner_supplied).
    # shellcheck disable=SC2016
    if grep -E '\| `new_tasks_in_story` \| Orchestrator creates tasks' "$SKILL_FILE" >/dev/null; then
        assert_eq "test_routing_new_tasks: new_tasks_in_story -> orchestrator creates tasks" "present" "present"
    else
        assert_eq "test_routing_new_tasks: new_tasks_in_story -> orchestrator creates tasks" "present" "missing"
    fi
    if grep -q 'planner_supplied' "$SKILL_FILE"; then
        assert_eq "test_routing_new_tasks: planner_supplied upstream noted" "present" "present"
    else
        assert_eq "test_routing_new_tasks: planner_supplied upstream noted" "present" "missing"
    fi
    assert_pass_if_clean "test_routing_new_tasks_in_story_to_planner_supplied"
}

test_routing_new_story_in_epic_to_preplanning() {
    _snapshot_fail
    fixture="$FIXTURES_DIR/fixture-new-story.json"
    if [[ ! -f "$fixture" ]]; then
        assert_eq "test_routing_new_story: fixture exists" "exists" "missing"
        assert_pass_if_clean "test_routing_new_story_in_epic_to_preplanning"
        return
    fi
    # new_story_in_epic -> /dso:preplanning <epic-id>.
    # shellcheck disable=SC2016
    if grep -E '\| `new_story_in_epic` \| `/dso:preplanning' "$SKILL_FILE" >/dev/null; then
        assert_eq "test_routing_new_story: new_story_in_epic -> /dso:preplanning" "present" "present"
    else
        assert_eq "test_routing_new_story: new_story_in_epic -> /dso:preplanning" "present" "missing"
    fi
    assert_pass_if_clean "test_routing_new_story_in_epic_to_preplanning"
}

test_routing_replan_epic_to_brainstorm() {
    _snapshot_fail
    fixture="$FIXTURES_DIR/fixture-replan-epic.json"
    if [[ ! -f "$fixture" ]]; then
        assert_eq "test_routing_replan_epic: fixture exists" "exists" "missing"
        assert_pass_if_clean "test_routing_replan_epic_to_brainstorm"
        return
    fi
    # replan_epic -> /dso:brainstorm <epic-id>.
    # shellcheck disable=SC2016
    if grep -E '\| `replan_epic` \| `/dso:brainstorm' "$SKILL_FILE" >/dev/null; then
        assert_eq "test_routing_replan_epic: replan_epic -> /dso:brainstorm" "present" "present"
    else
        assert_eq "test_routing_replan_epic: replan_epic -> /dso:brainstorm" "present" "missing"
    fi
    assert_pass_if_clean "test_routing_replan_epic_to_brainstorm"
}

# LOW confidence branch: planner returns confidence=LOW (or PROTOCOL_ERROR
# scope) → orchestrator emits HALT_FOR_USER and stops. Verify both sites
# document this branch.
test_low_confidence_halt_for_user_site1() {
    _snapshot_fail
    block=$(awk '/<HARD-GATE id="planner-dispatch-story-level">/,/<\/HARD-GATE>/' "$SKILL_FILE")
    if [[ "$block" == *"PROTOCOL_ERROR"* ]]; then
        assert_eq "test_low_confidence_site1: PROTOCOL_ERROR scope handled" "present" "present"
    else
        assert_eq "test_low_confidence_site1: PROTOCOL_ERROR scope handled" "present" "missing"
    fi
    if [[ "$block" == *"HALT_FOR_USER"* && "$block" == *'remediation_summary'* ]]; then
        assert_eq "test_low_confidence_site1: HALT surfaces planner evidence" "present" "present"
    else
        assert_eq "test_low_confidence_site1: HALT surfaces planner evidence" "present" "missing"
    fi
    # HALT-vs-REPLAN exclusivity must be referenced
    if [[ "$block" == *"REPLAN_ESCALATE"* && ( "$block" == *"exclusive"* || "$block" == *"exclusivity"* ) ]]; then
        assert_eq "test_low_confidence_site1: HALT-vs-REPLAN exclusivity noted" "present" "present"
    else
        assert_eq "test_low_confidence_site1: HALT-vs-REPLAN exclusivity noted" "present" "missing"
    fi
    assert_pass_if_clean "test_low_confidence_halt_for_user_site1"
}

test_low_confidence_halt_for_user_site2() {
    _snapshot_fail
    block=$(awk '/<HARD-GATE id="planner-dispatch-epic-level">/,/<\/HARD-GATE>/' "$SKILL_FILE")
    if [[ "$block" == *"PROTOCOL_ERROR"* ]]; then
        assert_eq "test_low_confidence_site2: PROTOCOL_ERROR scope handled" "present" "present"
    else
        assert_eq "test_low_confidence_site2: PROTOCOL_ERROR scope handled" "present" "missing"
    fi
    if [[ "$block" == *"HALT_FOR_USER"* && "$block" == *'remediation_summary'* ]]; then
        assert_eq "test_low_confidence_site2: HALT surfaces planner evidence" "present" "present"
    else
        assert_eq "test_low_confidence_site2: HALT surfaces planner evidence" "present" "missing"
    fi
    if [[ "$block" == *"REPLAN_ESCALATE"* && ( "$block" == *"exclusive"* || "$block" == *"exclusivity"* ) ]]; then
        assert_eq "test_low_confidence_site2: HALT-vs-REPLAN exclusivity noted" "present" "present"
    else
        assert_eq "test_low_confidence_site2: HALT-vs-REPLAN exclusivity noted" "present" "missing"
    fi
    assert_pass_if_clean "test_low_confidence_halt_for_user_site2"
}

# Fixture validity: each of the four branch fixtures is well-formed JSON and
# encodes a P1=FAIL outcome that the planner would classify into the named
# branch. (Sanity-check the existing fixtures shipped with the planner agent.)
test_branch_fixtures_well_formed() {
    _snapshot_fail
    for branch in replan-story new-tasks new-story replan-epic; do
        fixture="$FIXTURES_DIR/fixture-$branch.json"
        if [[ ! -f "$fixture" ]]; then
            assert_eq "test_branch_fixtures: fixture-$branch.json exists" "exists" "missing"
            continue
        fi
        if python3 -c "import json; d=json.load(open('$fixture')); assert d.get('P1') == 'FAIL'" 2>/dev/null; then
            assert_eq "test_branch_fixtures: fixture-$branch.json has P1=FAIL" "valid" "valid"
        else
            assert_eq "test_branch_fixtures: fixture-$branch.json has P1=FAIL" "valid" "invalid"
        fi
    done
    assert_pass_if_clean "test_branch_fixtures_well_formed"
}

# Planner-agent linkage: SKILL.md must reference the planner agent file path
# in the fallback form (per CLAUDE.md rule:dispatch-verifier mirroring) so a
# reader can locate the canonical agent contract from the dispatch site.
test_planner_agent_file_referenced() {
    _snapshot_fail
    if grep -q "agents/verification-remediation-planner.md" "$SKILL_FILE"; then
        assert_eq "test_planner_agent_file_referenced: agent path referenced" "present" "present"
    else
        assert_eq "test_planner_agent_file_referenced: agent path referenced" "present" "missing"
    fi
    assert_pass_if_clean "test_planner_agent_file_referenced"
}

# Run all tests
test_required_files_present
test_site1_phase_f_step_18_planner_gate_present
test_site2_phase_g_step_2_planner_gate_present
test_site3_d039_ac65_redispatch_covers_planner
test_no_ticket_creation_between_verifier_and_planner_site1
test_no_ticket_creation_between_verifier_and_planner_site2
test_no_ticket_creation_site3_d039_covered_by_site1
test_routing_replan_story_to_implementation_plan
test_routing_new_tasks_in_story_to_planner_supplied
test_routing_new_story_in_epic_to_preplanning
test_routing_replan_epic_to_brainstorm
test_low_confidence_halt_for_user_site1
test_low_confidence_halt_for_user_site2
test_branch_fixtures_well_formed
test_planner_agent_file_referenced

print_summary
