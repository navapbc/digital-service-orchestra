#!/usr/bin/env bash
# tests/scripts/test-prior-art-search-structure.sh
# TDD RED phase: structural and content validation for the prior-art search
# prompt fragment (plugins/dso/skills/shared/prompts/prior-art-search.md).
#
# All tests are expected to FAIL until the prompt fragment is created.
#
# Section extraction helper:
#   extract_section file header — prints lines within the named section
#   until the next ## header.
#
# Usage: bash tests/scripts/test-prior-art-search-structure.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-prior-art-search-structure.sh ==="

FRAGMENT="$PLUGIN_ROOT/plugins/dso/skills/shared/prompts/prior-art-search.md"

# Section extraction helper: prints lines in $file belonging to section $header
# (from the line after the header until the next ## header).
extract_section() {
    local file=$1 header=$2
    awk -v h="$header" '$0 ~ h {found=1; next} found && /^##/{exit} found{print}' "$file"
}

# ── test_fragment_file_exists ─────────────────────────────────────────────────
# MUST be the first test function — RED marker anchors here.
# The prompt fragment must exist and be non-empty.
test_fragment_file_exists() {
    _snapshot_fail
    local actual
    if [ -f "$FRAGMENT" ] && [ -s "$FRAGMENT" ]; then
        actual="exists_nonempty"
    elif [ -f "$FRAGMENT" ]; then
        actual="exists_empty"
    else
        actual="missing"
    fi
    assert_eq "test_fragment_file_exists: file exists and non-empty" "exists_nonempty" "$actual"
    assert_pass_if_clean "test_fragment_file_exists"
}

# ── test_bright_line_triggers_section ────────────────────────────────────────
# Fragment must contain a "Bright-Line Triggers" section with checklist items.
test_bright_line_triggers_section() {
    _snapshot_fail
    local section_exists checklist_found actual
    section_exists="no"
    checklist_found="no"
    if [ -f "$FRAGMENT" ] && grep -q "Bright-Line Triggers" "$FRAGMENT"; then
        section_exists="yes"
    fi
    if [ "$section_exists" = "yes" ]; then
        if extract_section "$FRAGMENT" "Bright-Line Triggers" | grep -q "^[-*]"; then
            checklist_found="yes"
        fi
    fi
    if [ "$section_exists" = "yes" ] && [ "$checklist_found" = "yes" ]; then
        actual="present_with_checklist"
    else
        actual="missing_or_no_checklist (section=$section_exists checklist=$checklist_found)"
    fi
    assert_eq "test_bright_line_triggers_section: section exists with checklist items" "present_with_checklist" "$actual"
    assert_pass_if_clean "test_bright_line_triggers_section"
}

# ── test_trust_validation_gate ────────────────────────────────────────────────
# Fragment must contain a "Trust Validation Gate" header.
test_trust_validation_gate() {
    _snapshot_fail
    local actual
    if [ -f "$FRAGMENT" ] && grep -q "Trust Validation Gate" "$FRAGMENT"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_trust_validation_gate: Trust Validation Gate header present" "present" "$actual"
    assert_pass_if_clean "test_trust_validation_gate"
}

# ── test_trust_gate_hard_blocker_rule ─────────────────────────────────────────
# The Trust Validation Gate section must contain both a "hard blocker" phrase
# AND a decision verb (must/shall/require/block).
test_trust_gate_hard_blocker_rule() {
    _snapshot_fail
    local section hard_blocker decision_verb actual
    section=""
    if [ -f "$FRAGMENT" ]; then
        section=$(extract_section "$FRAGMENT" "Trust Validation Gate")
    fi
    hard_blocker="no"
    decision_verb="no"
    # REVIEW-DEFENSE(finding-3): `hard.blocker` uses dot to match any character in ERE, which is equivalent
    # to the grep behavior on the same pattern. The OR branch `*hard\ blocker*` uses glob matching for the
    # literal two-word form. Together these patterns cover all expected document variants — no regression.
    if [[ "${section,,}" =~ hard.blocker ]] || [[ "${section,,}" == *hard\ blocker* ]]; then
        hard_blocker="yes"
    fi
    if [[ "${section,,}" =~ (^|[[:space:]])must([[:space:]]|$)|(^|[[:space:]])shall([[:space:]]|$)|(^|[[:space:]])require([[:space:]]|$)|(^|[[:space:]])block([[:space:]]|$) ]]; then
        decision_verb="yes"
    fi
    if [ "$hard_blocker" = "yes" ] && [ "$decision_verb" = "yes" ]; then
        actual="has_hard_blocker_and_decision_verb"
    else
        actual="missing (hard_blocker=$hard_blocker decision_verb=$decision_verb)"
    fi
    assert_eq "test_trust_gate_hard_blocker_rule: hard blocker AND decision verb present" "has_hard_blocker_and_decision_verb" "$actual"
    assert_pass_if_clean "test_trust_gate_hard_blocker_rule"
}

# ── test_tiered_search_protocol ───────────────────────────────────────────────
# Fragment must contain call budgets of approximately 6 and 10 in a tiered
# search protocol section.
test_tiered_search_protocol() {
    _snapshot_fail
    local has_6 has_10 actual
    has_6="no"
    has_10="no"
    if [ -f "$FRAGMENT" ] && grep -qE "\b6\b" "$FRAGMENT"; then
        has_6="yes"
    fi
    if [ -f "$FRAGMENT" ] && grep -qE "\b10\b" "$FRAGMENT"; then
        has_10="yes"
    fi
    if [ "$has_6" = "yes" ] && [ "$has_10" = "yes" ]; then
        actual="has_budgets_6_and_10"
    else
        actual="missing_budgets (6=$has_6 10=$has_10)"
    fi
    assert_eq "test_tiered_search_protocol: call budgets ~6 and ~10 present" "has_budgets_6_and_10" "$actual"
    assert_pass_if_clean "test_tiered_search_protocol"
}

# ── test_routine_exclusions_content ───────────────────────────────────────────
# A routine exclusions section must mention single-file AND formatting/lint.
test_routine_exclusions_content() {
    _snapshot_fail
    local has_single_file has_fmt_lint actual
    has_single_file="no"
    has_fmt_lint="no"
    if [ -f "$FRAGMENT" ] && grep -qi "single.file\|single file" "$FRAGMENT"; then
        has_single_file="yes"
    fi
    if [ -f "$FRAGMENT" ] && grep -qiE "formatting|lint" "$FRAGMENT"; then
        has_fmt_lint="yes"
    fi
    if [ "$has_single_file" = "yes" ] && [ "$has_fmt_lint" = "yes" ]; then
        actual="has_single_file_and_fmt_lint"
    else
        actual="missing (single_file=$has_single_file fmt_lint=$has_fmt_lint)"
    fi
    assert_eq "test_routine_exclusions_content: single-file AND formatting/lint present" "has_single_file_and_fmt_lint" "$actual"
    assert_pass_if_clean "test_routine_exclusions_content"
}

# ── test_evd_relationship ─────────────────────────────────────────────────────
# EVD (Existing vs. Discovered) section must be >= 5 lines long AND contain
# the words supersede, boundary, or complement.
test_evd_relationship() {
    _snapshot_fail
    local section line_count has_relationship actual
    section=""
    if [ -f "$FRAGMENT" ]; then
        section=$(extract_section "$FRAGMENT" "EVD\|Existing.*Discovered\|Discovered.*Existing")
        if [ -z "$section" ] && grep -qi "EVD" "$FRAGMENT"; then
            section=$(extract_section "$FRAGMENT" "EVD")
        fi
    fi
    line_count=0
    if [ -n "$section" ]; then
        line_count=$(echo "$section" | grep -c ".")
    fi
    has_relationship="no"
    if [[ "${section,,}" =~ supersede|boundary|complement ]]; then
        has_relationship="yes"
    fi
    if [ "$line_count" -ge 5 ] && [ "$has_relationship" = "yes" ]; then
        actual="evd_valid"
    else
        actual="invalid (lines=$line_count relationship=$has_relationship)"
    fi
    assert_eq "test_evd_relationship: EVD section >= 5 lines AND relationship terms present" "evd_valid" "$actual"
    assert_pass_if_clean "test_evd_relationship"
}

# ── test_non_interactive_fallback ─────────────────────────────────────────────
# Fragment must have a non-interactive fallback section with a structured
# output indicator (e.g., JSON, YAML, structured output, output format).
test_non_interactive_fallback() {
    _snapshot_fail
    local has_noninteractive has_structured actual
    has_noninteractive="no"
    has_structured="no"
    if [ -f "$FRAGMENT" ] && grep -qiE "non.interactive|noninteractive|non_interactive" "$FRAGMENT"; then
        has_noninteractive="yes"
    fi
    if [ -f "$FRAGMENT" ] && grep -qiE "structured.output|output.format|JSON|YAML" "$FRAGMENT"; then
        has_structured="yes"
    fi
    if [ "$has_noninteractive" = "yes" ] && [ "$has_structured" = "yes" ]; then
        actual="has_fallback_and_structured_output"
    else
        actual="missing (noninteractive=$has_noninteractive structured=$has_structured)"
    fi
    assert_eq "test_non_interactive_fallback: non-interactive fallback with structured output indicator" "has_fallback_and_structured_output" "$actual"
    assert_pass_if_clean "test_non_interactive_fallback"
}

# ── test_is_executable ────────────────────────────────────────────────────────
# This test file itself must be executable.
test_is_executable() {
    _snapshot_fail
    local self actual
    self="${BASH_SOURCE[0]}"
    if [ -x "$self" ]; then
        actual="executable"
    else
        actual="not_executable"
    fi
    assert_eq "test_is_executable: test file is executable" "executable" "$actual"
    assert_pass_if_clean "test_is_executable"
}

# ── Run all tests ──────────────────────────────────────────────────────────────
test_fragment_file_exists
test_bright_line_triggers_section
test_trust_validation_gate
test_trust_gate_hard_blocker_rule
test_tiered_search_protocol
test_routine_exclusions_content
test_evd_relationship
test_non_interactive_fallback
test_is_executable

print_summary
