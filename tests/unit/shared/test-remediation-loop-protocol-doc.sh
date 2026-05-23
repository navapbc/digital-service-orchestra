#!/usr/bin/env bash
# tests/unit/shared/test-remediation-loop-protocol-doc.sh
# Self-conformance smoke test for remediation-loop-protocol.md.
#
# Extracts canonical tokens and values from the protocol document and asserts
# they match what the conformance harness enforces. This test verifies that
# the doc itself is internally consistent and contains all required content.
#
# Usage:
#   bash tests/unit/shared/test-remediation-loop-protocol-doc.sh
#
# Exit code: 0 (all pass), 1 (any failure)

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
source "$REPO_ROOT/tests/lib/assert.sh"

DOC="$REPO_ROOT/plugins/dso/skills/shared/workflows/remediation-loop-protocol.md"

echo "=== test-remediation-loop-protocol-doc.sh ==="

# ---------------------------------------------------------------------------
# test_doc_exists: the protocol document must exist
# ---------------------------------------------------------------------------
test_doc_exists() {
    _snapshot_fail
    if [[ -f "$DOC" ]]; then
        (( ++PASS ))
        echo "doc exists ... PASS"
    else
        (( ++FAIL ))
        printf "FAIL: doc_exists\n  at: %s:%s\n  expected file: %s\n" "${BASH_SOURCE[0]}" "${LINENO}" "$DOC" >&2
    fi
    assert_pass_if_clean "test_doc_exists"
}

# ---------------------------------------------------------------------------
# test_all_termination_tokens_in_doc
# ---------------------------------------------------------------------------
test_all_termination_tokens_in_doc() {
    _snapshot_fail
    local doc_contents
    doc_contents="$(cat "$DOC")"
    assert_contains "REPLAN_ESCALATE in doc" "REPLAN_ESCALATE" "$doc_contents"
    assert_contains "HALT_FOR_USER in doc" "HALT_FOR_USER" "$doc_contents"
    assert_contains "OSCILLATION_HALT in doc" "OSCILLATION_HALT" "$doc_contents"
    assert_contains "PROTOCOL_ERROR in doc" "PROTOCOL_ERROR" "$doc_contents"
    assert_pass_if_clean "test_all_termination_tokens_in_doc"
}

# ---------------------------------------------------------------------------
# test_cycle_declaration_format
# ---------------------------------------------------------------------------
test_cycle_declaration_format() {
    _snapshot_fail
    local doc_contents
    doc_contents="$(cat "$DOC")"
    assert_contains "cycle declaration format" "Current cycle: N of MAX_CYCLES" "$doc_contents"
    assert_pass_if_clean "test_cycle_declaration_format"
}

# ---------------------------------------------------------------------------
# test_oscillation_halt_token_in_doc
# ---------------------------------------------------------------------------
test_oscillation_halt_token_in_doc() {
    _snapshot_fail
    local doc_contents
    doc_contents="$(cat "$DOC")"
    assert_contains "OSCILLATION_HALT token" "OSCILLATION_HALT" "$doc_contents"
    assert_pass_if_clean "test_oscillation_halt_token_in_doc"
}

# ---------------------------------------------------------------------------
# test_oscillation_check_hard_gate
# ---------------------------------------------------------------------------
test_oscillation_check_hard_gate() {
    _snapshot_fail
    local doc_contents
    doc_contents="$(cat "$DOC")"
    assert_contains "oscillation-check skill reference" "/dso:oscillation-check" "$doc_contents"
    assert_contains "OSCILLATION_CHECK_SKIPPED escape" "OSCILLATION_CHECK_SKIPPED" "$doc_contents"
    assert_pass_if_clean "test_oscillation_check_hard_gate"
}

# ---------------------------------------------------------------------------
# test_upstream_enum_values: all three permitted upstream values must appear
# ---------------------------------------------------------------------------
test_upstream_enum_values() {
    _snapshot_fail
    local doc_contents
    doc_contents="$(cat "$DOC")"
    assert_contains "upstream enum: brainstorm" "brainstorm" "$doc_contents"
    assert_contains "upstream enum: preplanning" "preplanning" "$doc_contents"
    assert_contains "upstream enum: planner_supplied" "planner_supplied" "$doc_contents"
    assert_pass_if_clean "test_upstream_enum_values"
}

# ---------------------------------------------------------------------------
# test_halt_vs_replan_exclusivity
# ---------------------------------------------------------------------------
test_halt_vs_replan_exclusivity() {
    _snapshot_fail
    local doc_contents
    doc_contents="$(cat "$DOC")"
    # The doc must explicitly state the mutual exclusivity invariant.
    # Accept any of the canonical phrasings.
    if [[ "$doc_contents" == *"mutually exclusive"* ]] || \
       [[ "$doc_contents" == *"IFF"* ]] || \
       [[ "$doc_contents" == *"if and only if"* ]] || \
       [[ "$doc_contents" == *"exclusiv"* ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: halt_vs_replan_exclusivity_phrase\n  at: %s:%s\n  expected one of: mutually exclusive / IFF / if and only if / exclusiv\n" "${BASH_SOURCE[0]}" "${LINENO}" >&2
    fi
    assert_pass_if_clean "test_halt_vs_replan_exclusivity"
}

# ---------------------------------------------------------------------------
# test_delta_output_token_and_producers
# ---------------------------------------------------------------------------
test_delta_output_token_and_producers() {
    _snapshot_fail
    local doc_contents
    doc_contents="$(cat "$DOC")"
    assert_contains "DELTA OUTPUT token" "DELTA OUTPUT" "$doc_contents"
    # SC1 producer
    assert_contains "SC1 story-decomposer reference" "story-decomposer" "$doc_contents"
    # SC2 producers
    if [[ "$doc_contents" == *"approach-proposer"* ]] || [[ "$doc_contents" == *"task-decomposer"* ]]; then
        (( ++PASS ))
    else
        (( ++FAIL ))
        printf "FAIL: SC2 producer reference\n  at: %s:%s\n  expected: approach-proposer or task-decomposer\n" "${BASH_SOURCE[0]}" "${LINENO}" >&2
    fi
    assert_pass_if_clean "test_delta_output_token_and_producers"
}

# ---------------------------------------------------------------------------
# test_max_cycles_config_key
# ---------------------------------------------------------------------------
test_max_cycles_config_key() {
    _snapshot_fail
    local doc_contents
    doc_contents="$(cat "$DOC")"
    assert_contains "planning.max_remediation_cycles config key" "planning.max_remediation_cycles" "$doc_contents"
    assert_pass_if_clean "test_max_cycles_config_key"
}

# ---------------------------------------------------------------------------
# test_harness_reference
# ---------------------------------------------------------------------------
test_harness_reference() {
    _snapshot_fail
    local doc_contents
    doc_contents="$(cat "$DOC")"
    assert_contains "protocol-conformance-harness.sh reference" "protocol-conformance-harness.sh" "$doc_contents"
    assert_pass_if_clean "test_harness_reference"
}

# ---------------------------------------------------------------------------
# test_replan_escalate_signal_contract_cited
# ---------------------------------------------------------------------------
test_replan_escalate_signal_contract_cited() {
    _snapshot_fail
    local doc_contents
    doc_contents="$(cat "$DOC")"
    assert_contains "replan-escalate-signal.md citation" "replan-escalate-signal.md" "$doc_contents"
    assert_pass_if_clean "test_replan_escalate_signal_contract_cited"
}

# ---------------------------------------------------------------------------
# test_planning_config_sh_sourcing
# ---------------------------------------------------------------------------
test_planning_config_sh_sourcing() {
    _snapshot_fail
    local doc_contents
    doc_contents="$(cat "$DOC")"
    assert_contains "planning-config.sh reference" "planning-config.sh" "$doc_contents"
    assert_pass_if_clean "test_planning_config_sh_sourcing"
}

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------
test_doc_exists
test_all_termination_tokens_in_doc
test_cycle_declaration_format
test_oscillation_halt_token_in_doc
test_oscillation_check_hard_gate
test_upstream_enum_values
test_halt_vs_replan_exclusivity
test_delta_output_token_and_producers
test_max_cycles_config_key
test_harness_reference
test_replan_escalate_signal_contract_cited
test_planning_config_sh_sourcing

print_summary
