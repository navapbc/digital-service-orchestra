#!/usr/bin/env bash
# tests/skills/test-architect-foundation-integration.sh
# Integration tests verifying cross-story acceptance criteria for architect-foundation UX improvements.
# All 5 criteria must pass simultaneously once all story tasks are implemented.
#
# Validates (5 named assertions):
#   test_criterion_a_auto_single_confirm: --auto flag AND single confirmation both present
#   test_criterion_b_standard_batched_summary: summary artifact table present for batched UX
#   test_criterion_c_adrs_generated: always generate ADRs instruction present
#   test_criterion_d_rerun_no_overwrite: append-only merge present (no-overwrite on re-run)
#   test_criterion_e_idempotency: dedup AND idempotency both present
#
# These are structural boundary tests per the Behavioral Test Requirement exemption
# (non-executable LLM instruction file; testing structural presence and shape of instructions).
#
# Usage: bash tests/skills/test-architect-foundation-integration.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_MD="$DSO_PLUGIN_DIR/skills/architect-foundation/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-architect-foundation-integration.sh ==="

# test_criterion_a_auto_single_confirm:
# --auto flag AND 'single.*confirmation' must both be present in SKILL.md.
# The --auto mode skips Socratic dialogue and selects recommended defaults; the batched artifact
# UX uses a single confirmation for all writes. Both must co-exist for criterion A to pass.
test_criterion_a_auto_single_confirm() {
    _snapshot_fail
    local has_auto has_single_confirm criterion_a
    has_auto="no"
    has_single_confirm="no"
    if grep -qE -- "--auto" "$SKILL_MD" 2>/dev/null; then
        has_auto="yes"
    fi
    if grep -qiE "single.*confirmation" "$SKILL_MD" 2>/dev/null; then
        has_single_confirm="yes"
    fi
    if [[ "$has_auto" == "yes" && "$has_single_confirm" == "yes" ]]; then
        criterion_a="found"
    else
        criterion_a="missing"
    fi
    assert_eq "test_criterion_a_auto_single_confirm" "found" "$criterion_a"
    assert_pass_if_clean "test_criterion_a_auto_single_confirm"
}

# test_criterion_b_standard_batched_summary:
# 'summary.*artifact' must be present in SKILL.md.
# Phase 2.75 requires presenting a summary table of all enforcement artifacts before the
# single confirmation step. This is the batched UX standard — no per-file confirmation.
test_criterion_b_standard_batched_summary() {
    _snapshot_fail
    local summary_found
    summary_found="missing"
    if grep -qiE "summary.*artifact" "$SKILL_MD" 2>/dev/null; then
        summary_found="found"
    fi
    assert_eq "test_criterion_b_standard_batched_summary" "found" "$summary_found"
    assert_pass_if_clean "test_criterion_b_standard_batched_summary"
}

# test_criterion_c_adrs_generated:
# 'always generate.*adr' must be present in SKILL.md (case-insensitive).
# Phase 2.8 mandates that ADRs are always generated for all architectural decisions made
# during the session — without asking the user for permission to generate them.
test_criterion_c_adrs_generated() {
    _snapshot_fail
    local adrs_found
    adrs_found="missing"
    if grep -qiE "always generate.*adr" "$SKILL_MD" 2>/dev/null; then
        adrs_found="found"
    fi
    assert_eq "test_criterion_c_adrs_generated" "found" "$adrs_found"
    assert_pass_if_clean "test_criterion_c_adrs_generated"
}

# test_criterion_d_rerun_no_overwrite:
# 'append-only' (or 'append.only') must be present in SKILL.md.
# Phase 2.9 re-run idempotency requires append-only merge: existing enforcement rules must
# not be overwritten on re-run. Only new rules discovered in the current session are appended.
test_criterion_d_rerun_no_overwrite() {
    _snapshot_fail
    local append_found
    append_found="missing"
    if grep -qiE "append-only|append\.only" "$SKILL_MD" 2>/dev/null; then
        append_found="found"
    fi
    assert_eq "test_criterion_d_rerun_no_overwrite" "found" "$append_found"
    assert_pass_if_clean "test_criterion_d_rerun_no_overwrite"
}

# test_criterion_e_idempotency:
# 'dedup' or 'deduplication' AND 'idempotent' or 'idempotency' must both be present in SKILL.md.
# Phase 2.9 re-run idempotency requires: (a) deduplication so identical rules are not added
# twice, and (b) the word 'idempotent' or 'idempotency' to make the guarantee explicit.
test_criterion_e_idempotency() {
    _snapshot_fail
    local has_dedup has_idempotent criterion_e
    has_dedup="no"
    has_idempotent="no"
    if grep -qiE "dedup|deduplication" "$SKILL_MD" 2>/dev/null; then
        has_dedup="yes"
    fi
    if grep -qiE "idempotent|idempotency" "$SKILL_MD" 2>/dev/null; then
        has_idempotent="yes"
    fi
    if [[ "$has_dedup" == "yes" && "$has_idempotent" == "yes" ]]; then
        criterion_e="found"
    else
        criterion_e="missing"
    fi
    assert_eq "test_criterion_e_idempotency" "found" "$criterion_e"
    assert_pass_if_clean "test_criterion_e_idempotency"
}

test_criterion_a_auto_single_confirm
test_criterion_b_standard_batched_summary
test_criterion_c_adrs_generated
test_criterion_d_rerun_no_overwrite
test_criterion_e_idempotency

print_summary
