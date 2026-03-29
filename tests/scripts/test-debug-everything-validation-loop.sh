#!/usr/bin/env bash
# tests/scripts/test-debug-everything-validation-loop.sh
# Structural metadata validation of debug-everything SKILL.md validation loop.
#
# Verifies that the debug-everything skill includes a Validation Mode that:
#   1. Has a "Validation Mode" or validation loop section
#   2. Runs a diagnostic scan after bug-fix mode
#   3. Creates bug tickets for newly discovered failures
#   4. Loops back to bug-fix mode when new bugs are found
#   5. References debug.max_fix_validate_cycles config key
#   6. Documents stop-and-report behavior at max iterations
#
# Also includes a dedup test:
#   7. Documents dedup logic — only ONE ticket per unique failure across iterations
#
# Test status:
#   ALL 7 tests are RED — no Validation Mode exists in current SKILL.md.
#
# Exemption: structural metadata validation of prompt file — not executable code.
# RED marker: test_validation_mode_section_exists (first RED test — all 7 are RED)
#
# Usage: bash tests/scripts/test-debug-everything-validation-loop.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_FILE="$DSO_PLUGIN_DIR/skills/debug-everything/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-debug-everything-validation-loop.sh ==="

# ============================================================
# RED MARKER BOUNDARY
# ALL 7 tests below are RED — Validation Mode does not yet exist
# in debug-everything/SKILL.md. RED marker in .test-index:
#   [test_validation_mode_section_exists]
# ============================================================

# ============================================================
# test_validation_mode_section_exists
# SKILL.md must contain a "Validation Mode" section or a
# validation loop section that describes a post-bugfix loop.
# RED: no such section exists in current SKILL.md.
# ============================================================
test_validation_mode_section_exists() {
    local section_found="missing"

    # Look for a heading or section explicitly describing a validation mode
    # or validation loop (case-insensitive)
    if grep -qEi '(##+ *Validation Mode|##+ *Validation Loop|validation mode|fix.validate cycle|fix.*validate.*loop)' "$SKILL_FILE" 2>/dev/null; then
        section_found="found"
    fi

    assert_eq "test_validation_mode_section_exists: SKILL.md contains Validation Mode or validation loop section" "found" "$section_found"
}

# ============================================================
# test_validation_runs_diagnostic_after_bugfix
# Validation mode must document running a diagnostic scan after
# bug-fix mode completes.
# RED: no validation mode exists in current SKILL.md.
# ============================================================
test_validation_runs_diagnostic_after_bugfix() {
    local diagnostic_after_bugfix="missing"

    # Look for evidence that validation mode runs a diagnostic after bug-fix completes
    if grep -qEi '(validation mode.*diagnostic|diagnostic.*after.*bug.?fix|re.diagnose.*after.*fix|validation.*scan.*after.*bug.?fix|fix.*then.*diagnos)' "$SKILL_FILE" 2>/dev/null; then
        diagnostic_after_bugfix="found"
    fi

    assert_eq "test_validation_runs_diagnostic_after_bugfix: validation mode runs diagnostic after bug-fix" "found" "$diagnostic_after_bugfix"
}

# ============================================================
# test_validation_creates_tickets_for_new_failures
# Validation mode must document creating bug tickets for newly
# discovered failures found during the validation pass.
# RED: no validation mode exists in current SKILL.md.
# ============================================================
test_validation_creates_tickets_for_new_failures() {
    local creates_tickets="missing"

    # Look for documentation of creating tickets for new failures found in validation
    if grep -qEi '(creat.*ticket.*new.*fail|new.*fail.*ticket|ticket.*newly.*discovered|new.*bug.*ticket.*validation|validation.*creat.*ticket)' "$SKILL_FILE" 2>/dev/null; then
        creates_tickets="found"
    fi

    assert_eq "test_validation_creates_tickets_for_new_failures: validation mode creates tickets for new failures" "found" "$creates_tickets"
}

# ============================================================
# test_validation_loops_back_to_bugfix
# Validation mode must document looping back to bug-fix mode
# when new bugs are found during the validation pass.
# RED: no validation mode exists in current SKILL.md.
# ============================================================
test_validation_loops_back_to_bugfix() {
    local loops_back="missing"

    # Look for documentation of looping back to bug-fix mode
    if grep -qEi '(loop.*back.*bug.?fix|return.*bug.?fix.*mode|bug.?fix.*mode.*new.*bug|new.*bug.*loop.*bug.?fix|loop.*back.*fix)' "$SKILL_FILE" 2>/dev/null; then
        loops_back="found"
    fi

    assert_eq "test_validation_loops_back_to_bugfix: validation mode loops back to bug-fix when new bugs found" "found" "$loops_back"
}

# ============================================================
# test_validation_respects_max_iterations
# Validation mode must reference debug.max_fix_validate_cycles
# or a max iterations limit that bounds the fix→validate loop.
# RED: no validation mode exists in current SKILL.md.
# ============================================================
test_validation_respects_max_iterations() {
    local max_cycles_ref="missing"

    # Look for a reference to the max_fix_validate_cycles config key or
    # a max iterations limit in the context of the validation loop
    if grep -qE '(max_fix_validate_cycles|max.*fix.*validate.*cycle|max.*validate.*cycle|fix.*validate.*max|maximum.*fix.*cycle)' "$SKILL_FILE" 2>/dev/null; then
        max_cycles_ref="found"
    fi

    assert_eq "test_validation_respects_max_iterations: validation mode references max fix-validate cycle limit" "found" "$max_cycles_ref"
}

# ============================================================
# test_validation_stops_and_reports_at_max
# Validation mode must document stop-and-report behavior when
# the maximum number of fix→validate cycles is reached.
# RED: no validation mode exists in current SKILL.md.
# ============================================================
test_validation_stops_and_reports_at_max() {
    local stop_and_report="missing"

    # Look for documentation of stopping and reporting to the user at max iterations
    if grep -qEi '(stop.*report.*max|max.*cycle.*stop|escalate.*max.*cycle|max.*iteration.*report|report.*max.*iteration|cycles.*exceeded|stop.*max.*fix)' "$SKILL_FILE" 2>/dev/null; then
        stop_and_report="found"
    fi

    assert_eq "test_validation_stops_and_reports_at_max: validation mode stops and reports at max iterations" "found" "$stop_and_report"
}

# ============================================================
# test_validation_deduplicates_tickets
# Validation mode must document dedup logic — when the same
# failure appears in consecutive validation iterations, only
# ONE ticket is created per unique failure (not duplicates).
# RED: no validation mode exists in current SKILL.md.
# ============================================================
test_validation_deduplicates_tickets() {
    local dedup_found="missing"

    # Look for documentation of deduplication of tickets across iterations
    if grep -qEi '(dedup|de-dup|duplicate.*ticket|ticket.*duplicate|one ticket.*unique|unique.*failure.*one ticket|already.*ticket.*skip|skip.*existing.*ticket)' "$SKILL_FILE" 2>/dev/null; then
        dedup_found="found"
    fi

    assert_eq "test_validation_deduplicates_tickets: validation mode deduplicates tickets for same failure across iterations" "found" "$dedup_found"
}

# ============================================================
# Run all tests
# ============================================================
test_validation_mode_section_exists
test_validation_runs_diagnostic_after_bugfix
test_validation_creates_tickets_for_new_failures
test_validation_loops_back_to_bugfix
test_validation_respects_max_iterations
test_validation_stops_and_reports_at_max
test_validation_deduplicates_tickets

print_summary
