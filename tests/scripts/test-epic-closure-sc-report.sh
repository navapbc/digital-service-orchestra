#!/usr/bin/env bash
# tests/scripts/test-epic-closure-sc-report.sh
# Structural tests for the SC9/SC13/SC14 epic-closure gates in completion-verifier.md.
# Verifies the agent file contains the required gate step (Step 3.5) and all 3 SC reports.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VERIFIER="$REPO_ROOT/plugins/dso/agents/completion-verifier.md"

source "$REPO_ROOT/tests/lib/assert.sh"

test_epic_closure_sc9_gate() {
    # The completion-verifier must contain the SC9 Coverage Gate step
    local has_sc9
    has_sc9=$(grep -c "SC9" "$VERIFIER" 2>/dev/null || echo 0)
    assert_ne "SC9 gate reference present in completion-verifier.md" "0" "$has_sc9"

    # Must reference the coverage harness script
    local has_harness
    has_harness=$(grep -c "preconditions-coverage-harness.sh" "$VERIFIER" 2>/dev/null || echo 0)
    assert_ne "coverage harness invocation present in completion-verifier.md" "0" "$has_harness"

    # Must specify the threshold (100 preventions)
    local has_threshold
    has_threshold=$(grep -c "100" "$VERIFIER" 2>/dev/null || echo 0)
    assert_ne "threshold of 100 preventions referenced in completion-verifier.md" "0" "$has_threshold"

    # Must emit SC9_GATE_FAIL on failure
    local has_fail_signal
    has_fail_signal=$(grep -c "SC9_GATE_FAIL" "$VERIFIER" 2>/dev/null || echo 0)
    assert_ne "SC9_GATE_FAIL signal referenced in completion-verifier.md" "0" "$has_fail_signal"
}

test_epic_closure_sc14_fp_rate() {
    # The completion-verifier must contain the SC14 FP rate gate
    local has_sc14
    has_sc14=$(grep -c "SC14" "$VERIFIER" 2>/dev/null || echo 0)
    assert_ne "SC14 gate reference present in completion-verifier.md" "0" "$has_sc14"

    # Must reference fp-rate-tracker.sh
    local has_tracker
    has_tracker=$(grep -c "fp-rate-tracker.sh" "$VERIFIER" 2>/dev/null || echo 0)
    assert_ne "fp-rate-tracker.sh invocation present in completion-verifier.md" "0" "$has_tracker"
}

test_epic_closure_sc13_restart_analysis() {
    # The completion-verifier must contain the SC13 restart-rate drop analysis
    local has_sc13
    has_sc13=$(grep -c "SC13" "$VERIFIER" 2>/dev/null || echo 0)
    assert_ne "SC13 gate reference present in completion-verifier.md" "0" "$has_sc13"

    # Must reference sc13-restart-analysis.sh
    local has_analysis
    has_analysis=$(grep -c "sc13-restart-analysis.sh" "$VERIFIER" 2>/dev/null || echo 0)
    assert_ne "sc13-restart-analysis.sh invocation present in completion-verifier.md" "0" "$has_analysis"

    # Must reference methodology (Wilson score interval)
    local has_methodology
    has_methodology=$(grep -c -i "wilson" "$VERIFIER" 2>/dev/null || echo 0)
    assert_ne "Wilson score interval methodology referenced in completion-verifier.md" "0" "$has_methodology"
}

test_all_three_sc_reports_in_step() {
    # Step 3.5 must reference all three SCs together as an epic-closure step
    local has_step_35
    has_step_35=$(grep -c "Step 3.5" "$VERIFIER" 2>/dev/null || echo 0)
    assert_ne "Step 3.5 (SC9/SC13/SC14 Gates) present in completion-verifier.md" "0" "$has_step_35"

    # The step must apply only to epics
    local has_epic_only
    has_epic_only=$(grep -c "ticket_type.*epic" "$VERIFIER" 2>/dev/null || echo 0)
    assert_ne "Epic-only guard present for SC gates" "0" "$has_epic_only"
}

test_epic_closure_sc9_gate
test_epic_closure_sc14_fp_rate
test_epic_closure_sc13_restart_analysis
test_all_three_sc_reports_in_step

print_summary
