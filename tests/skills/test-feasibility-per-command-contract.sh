#!/usr/bin/env bash
# tests/skills/test-feasibility-per-command-contract.sh
#
# Structural boundary tests for bug 0dee-a535-45dd-4bc4:
# "ACLI feasibility research conducted but documented at insufficient depth
# -> contract gaps allowed 3 layered runtime bugs to ship"
#
# INSTRUCTION DOCUMENT TESTING RATIONALE:
# feasibility-reviewer.md, post-scrutiny-handlers.md, and research-process.md
# are non-executable instruction documents. Their text constitutes the behavioral
# contract — what the LLM agent will do when it reads the document. Per
# behavioral-testing-standard.md Rule 5, instruction-file tests check the
# STRUCTURAL BOUNDARY: required section headings, protocol marker strings, and
# schema field names — not wording or implementation detail.
#
# What we test (structural boundaries):
#   1. feasibility-reviewer.md requires per-command empirical verification for
#      CLI tools (the "per-command" depth requirement must appear)
#   2. feasibility-reviewer.md requires listing every subcommand/method the
#      implementation will call (not just "integration exists")
#   3. feasibility-reviewer.md requires capturing observed contract (flags,
#      payload shapes, error responses) — not just doc-verified capability
#   4. post-scrutiny-handlers.md researchFindings schema includes a
#      command_surface field (structural schema field name)
#   5. post-scrutiny-handlers.md requires the observed contract to be
#      captured verbatim (not just status=verified at integration level)
#   6. preplanning research-process.md requires cross-referencing researchFindings
#      for per-command contract records before implementation stories proceed
#
# All 6 tests FAIL in RED state before the fix because:
#   - feasibility-reviewer.md has no per-command requirement
#   - post-scrutiny-handlers.md has no command_surface schema field
#   - research-process.md has no per-command contract cross-reference
#
# Usage:
#   bash tests/skills/test-feasibility-per-command-contract.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"

FEASIBILITY_MD="${REPO_ROOT}/plugins/dso/agents/feasibility-reviewer.md"
POST_SCRUTINY_MD="${REPO_ROOT}/plugins/dso/skills/brainstorm/phases/post-scrutiny-handlers.md"
RESEARCH_PROCESS_MD="${REPO_ROOT}/plugins/dso/skills/preplanning/prompts/research-process.md"

PASS=0
FAIL=0

pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

# ---------------------------------------------------------------------------
# Test 1: feasibility-reviewer.md requires per-command empirical verification
#
# Given: plugins/dso/agents/feasibility-reviewer.md
# When:  a CLI tool with non-trivial command surface is an integration signal
# Then:  the agent must require per-command (per-subcommand) empirical testing
#
# Structural boundary: the phrase "per-command" or "every command" must appear
# in the agent file to enforce the depth requirement. Without this marker, the
# agent produces integration-level verification ("ACLI authenticates") instead
# of command-level verification ("acli jira workitem edit --labels works as
# set-replace, not additive").
#
# RED: marker absent → agent produces thin verification → runtime bugs ship
# GREEN: marker present → agent performs per-command depth verification
# ---------------------------------------------------------------------------
test_feasibility_per_command_requirement() {
    echo "=== test_feasibility_per_command_requirement ==="

    if [ ! -f "$FEASIBILITY_MD" ]; then
        fail "feasibility-reviewer.md missing — cannot check for per-command requirement"
        return
    fi

    if grep -qiE "per-command|per command|every (sub)?command|each (sub)?command" "$FEASIBILITY_MD"; then
        pass "feasibility-reviewer.md contains per-command empirical verification requirement"
    else
        fail "feasibility-reviewer.md missing per-command verification requirement (required to prevent bug class 0dee)"
    fi
}

# ---------------------------------------------------------------------------
# Test 2: feasibility-reviewer.md requires listing every invocation
#
# Given: plugins/dso/agents/feasibility-reviewer.md
# When:  the agent analyzes a CLI integration
# Then:  it must enumerate every specific subcommand/invocation the epic will use
#
# Structural boundary: "every" or "each" invocation/subcommand enumeration
# instruction must appear. The bug root cause: the agent verified "ACLI
# exists and authenticates" but never listed the specific commands
# (create, edit, transition, delete, comment) to be verified.
#
# RED: no enumeration instruction → agent skips subcommand inventory
# GREEN: enumeration instruction present → agent lists every invocation
# ---------------------------------------------------------------------------
test_feasibility_enumerate_invocations() {
    echo ""
    echo "=== test_feasibility_enumerate_invocations ==="

    if [ ! -f "$FEASIBILITY_MD" ]; then
        fail "feasibility-reviewer.md missing — cannot check for invocation enumeration requirement"
        return
    fi

    if grep -qiE "list every|enumerate every|every.*invocation|every.*subcommand|each.*subcommand|all.*subcommand|commands.*implementation.*will.*call|commands.*will.*issue" "$FEASIBILITY_MD"; then
        pass "feasibility-reviewer.md requires enumerating every subcommand/invocation"
    else
        fail "feasibility-reviewer.md missing invocation enumeration requirement (agent must list all commands the implementation will call)"
    fi
}

# ---------------------------------------------------------------------------
# Test 3: feasibility-reviewer.md requires capturing observed flag/payload contract
#
# Given: plugins/dso/agents/feasibility-reviewer.md
# When:  the agent verifies a CLI integration signal
# Then:  it must capture the observed contract (flags, payload shapes, error
#        responses) — not just "capability verified via docs/GitHub search"
#
# Structural boundary: the words "flag" or "payload" or "error response"
# must appear in the context of what the agent captures. Without this, the
# agent reports "verified" at the integration level without capturing the
# specific invocation contract that implementation depends on.
#
# RED: no flag/payload/error contract capture instruction → contract gaps ship
# GREEN: instruction present → observed contract recorded durably
# ---------------------------------------------------------------------------
test_feasibility_capture_observed_contract() {
    echo ""
    echo "=== test_feasibility_capture_observed_contract ==="

    if [ ! -f "$FEASIBILITY_MD" ]; then
        fail "feasibility-reviewer.md missing — cannot check for observed contract capture"
        return
    fi

    if grep -qiE "flag.*shape|payload.*shape|error.*response|observed.*contract|command.*surface|exact.*flag|exact.*command" "$FEASIBILITY_MD"; then
        pass "feasibility-reviewer.md requires capturing observed contract (flags, payload shapes, error responses)"
    else
        fail "feasibility-reviewer.md missing observed contract capture requirement (agent must record exact flags and payload shapes)"
    fi
}

# ---------------------------------------------------------------------------
# Test 4: post-scrutiny-handlers.md researchFindings schema includes command_surface
#
# Given: plugins/dso/skills/brainstorm/phases/post-scrutiny-handlers.md
# When:  brainstorm persists researchFindings to the epic ticket
# Then:  the researchFindings schema must include a command_surface field
#
# Structural boundary: "command_surface" is a schema field name. Its presence
# in post-scrutiny-handlers.md is a contract requirement — downstream agents
# (preplanning, sprint) that parse RESEARCH_FINDINGS: comments need this field
# to know whether per-command contract was captured for a CLI dependency.
#
# RED: field absent → no structured place to record per-command contracts
# GREEN: field present → per-command contracts are durable and machine-readable
# ---------------------------------------------------------------------------
test_research_findings_command_surface_field() {
    echo ""
    echo "=== test_research_findings_command_surface_field ==="

    if [ ! -f "$POST_SCRUTINY_MD" ]; then
        fail "post-scrutiny-handlers.md missing — cannot check for command_surface field"
        return
    fi

    if grep -qF "command_surface" "$POST_SCRUTINY_MD"; then
        pass "post-scrutiny-handlers.md researchFindings schema includes command_surface field"
    else
        fail "post-scrutiny-handlers.md researchFindings schema missing command_surface field (required to record per-command observed contracts)"
    fi
}

# ---------------------------------------------------------------------------
# Test 5: post-scrutiny-handlers.md instructs agent to capture contract verbatim
#
# Given: plugins/dso/skills/brainstorm/phases/post-scrutiny-handlers.md
# When:  feasibility-reviewer output includes per-command contract findings
# Then:  the persistence step must capture the observed contract verbatim
#
# Structural boundary: the Research Findings Persistence section must mention
# capturing the command contract (not just a (capability, status) tuple).
# This prevents the "integration exists" finding from being the only durable
# record when a per-command contract is the critical gap.
#
# RED: no verbatim contract capture instruction → only status recorded
# GREEN: instruction present → exact flags/payload captured durably
# ---------------------------------------------------------------------------
test_research_findings_capture_verbatim_contract() {
    echo ""
    echo "=== test_research_findings_capture_verbatim_contract ==="

    if [ ! -f "$POST_SCRUTINY_MD" ]; then
        fail "post-scrutiny-handlers.md missing — cannot check for verbatim contract capture"
        return
    fi

    if grep -qiE "command_surface|verbatim.*contract|contract.*verbatim|observed.*flag|exact.*flag|per-command.*contract|command.*contract" "$POST_SCRUTINY_MD"; then
        pass "post-scrutiny-handlers.md instructs agent to capture per-command contract in researchFindings"
    else
        fail "post-scrutiny-handlers.md missing per-command contract capture instruction in Research Findings Persistence"
    fi
}

# ---------------------------------------------------------------------------
# Test 6: research-process.md cross-references per-command contract before
#         implementation stories proceed
#
# Given: plugins/dso/skills/preplanning/prompts/research-process.md
# When:  a story qualifies for integration research (references a CLI tool)
# Then:  the research process must check whether a per-command contract exists
#        in researchFindings before the story proceeds to implementation
#
# Structural boundary: the research-process.md must mention checking for
# per-command contract records (command_surface field) in researchFindings.
# Without this, preplanning decomposition proceeds even when the feasibility
# research only verified "integration exists" not "command surface verified."
#
# RED: no per-command contract check → implementation stories ship with gaps
# GREEN: check present → stories blocked until command contract is captured
# ---------------------------------------------------------------------------
test_research_process_per_command_contract_check() {
    echo ""
    echo "=== test_research_process_per_command_contract_check ==="

    if [ ! -f "$RESEARCH_PROCESS_MD" ]; then
        fail "research-process.md missing — cannot check for per-command contract cross-reference"
        return
    fi

    if grep -qiE "command_surface|per-command.*contract|command.*contract|every.*command.*verified|each.*command.*verified" "$RESEARCH_PROCESS_MD"; then
        pass "research-process.md cross-references per-command contract (command_surface) before proceeding"
    else
        fail "research-process.md missing per-command contract cross-reference (must check command_surface in researchFindings for CLI integration stories)"
    fi
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_feasibility_per_command_requirement
test_feasibility_enumerate_invocations
test_feasibility_capture_observed_contract
test_research_findings_command_surface_field
test_research_findings_capture_verbatim_contract
test_research_process_per_command_contract_check

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
echo "Passed: $PASS"
echo "Failed: $FAIL"

if [ "$FAIL" -gt 0 ]; then
    echo "VALIDATION FAILED"
    exit 1
fi

echo "ALL VALIDATIONS PASSED"
exit 0
