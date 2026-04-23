#!/usr/bin/env bash
# tests/skills/test-using-dso-delegation.sh
# Structural validation tests for the Sub-Agent Delegation section in
# plugins/dso/skills/using-dso/SKILL.md and HOOK-INJECTION.md.
#
# Validates (SKILL.md — 4 tests):
#   1. Has "## Sub-Agent Delegation" heading
#   2. Red Flags table covers all 3 patterns (sequential reads, serial edits, inline self-review)
#   3. Section line count does not exceed 60 lines
#   4. Scope limitation note present (prevents recursive sub-agent spawning)
#
# Validates (HOOK-INJECTION.md — 1 test):
#   5. HOOK-INJECTION.md contains delegation guidance
#
# Usage: bash tests/skills/test-using-dso-delegation.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_MD="$DSO_PLUGIN_DIR/skills/using-dso/SKILL.md"
HOOK_MD="$DSO_PLUGIN_DIR/skills/using-dso/HOOK-INJECTION.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-using-dso-delegation.sh ==="
echo ""

# ---------------------------------------------------------------------------
# SKILL.md delegation tests
# ---------------------------------------------------------------------------
echo "--- SKILL.md sub-agent delegation tests ---"

# test_skill_md_has_delegation_section
# SKILL.md must have a "## Sub-Agent Delegation" section heading
_snapshot_fail
if grep -q "## Sub-Agent Delegation" "$SKILL_MD" 2>/dev/null; then
    section_found="found"
else
    section_found="missing"
fi
assert_eq "test_skill_md_has_delegation_section" "found" "$section_found"
assert_pass_if_clean "test_skill_md_has_delegation_section"

# test_skill_md_has_three_red_flag_patterns
# SKILL.md must identify all 3 delegation patterns in the Red Flags table:
#   1. Sequential multi-file reads (10+ files)
#   2. Serial independent file edits
#   3. Inline self-review
_snapshot_fail
has_sequential_reads=0
has_serial_edits=0
has_inline_review=0
grep -qiE "sequential.*read|read.*10\+|10\+.*file|multi.file.*read" "$SKILL_MD" 2>/dev/null && has_sequential_reads=1
grep -qiE "serial.*edit|independent.*edit|edit.*serial|parallel.*edit" "$SKILL_MD" 2>/dev/null && has_serial_edits=1
grep -qiE "self.review|inline.*review|review.*own|own.*output" "$SKILL_MD" 2>/dev/null && has_inline_review=1
if [[ "$has_sequential_reads" -eq 1 && "$has_serial_edits" -eq 1 && "$has_inline_review" -eq 1 ]]; then
    patterns_found="found"
else
    patterns_found="missing (reads=$has_sequential_reads serial=$has_serial_edits review=$has_inline_review)"
fi
assert_eq "test_skill_md_has_three_red_flag_patterns" "found" "$patterns_found"
assert_pass_if_clean "test_skill_md_has_three_red_flag_patterns"

# test_skill_md_delegation_section_line_count
# Sub-Agent Delegation section must be ≤60 rendered lines
_snapshot_fail
# Extract lines from "## Sub-Agent Delegation" to the next "## " section heading (or EOF)
if grep -q "## Sub-Agent Delegation" "$SKILL_MD" 2>/dev/null; then
    section_lines=$(awk '/^## Sub-Agent Delegation/{found=1; count=0} found{count++} /^## /{if(found && !/Sub-Agent Delegation/){exit}} END{print count}' "$SKILL_MD" 2>/dev/null || echo 0)
    if [[ "$section_lines" -le 60 ]]; then
        line_count_ok="ok"
    else
        line_count_ok="too_long (${section_lines} lines)"
    fi
else
    # Section missing — test will fail at test_skill_md_has_delegation_section; skip count
    line_count_ok="ok"
fi
assert_eq "test_skill_md_delegation_section_line_count" "ok" "$line_count_ok"
assert_pass_if_clean "test_skill_md_delegation_section_line_count"

# test_skill_md_has_recursive_scope_note
# SKILL.md must contain a scope-limiting note that prevents recursive sub-agent spawning
_snapshot_fail
if grep -qiE "recursive|re.spawn|spawn.*further|not.*spawn.*sub.agent|sub.agent.*not.*re.apply|sub.agent.*must.not" "$SKILL_MD" 2>/dev/null; then
    scope_note_found="found"
else
    scope_note_found="missing"
fi
assert_eq "test_skill_md_has_recursive_scope_note" "found" "$scope_note_found"
assert_pass_if_clean "test_skill_md_has_recursive_scope_note"

# ---------------------------------------------------------------------------
# HOOK-INJECTION.md delegation test
# ---------------------------------------------------------------------------
echo ""
echo "--- HOOK-INJECTION.md delegation test ---"

# test_hook_md_has_delegation_guidance
# HOOK-INJECTION.md must contain sub-agent delegation guidance
_snapshot_fail
if grep -qiE "Sub-Agent Delegation|sub-agent delegation|delegation.*guidance|Red Flag.*delegation" "$HOOK_MD" 2>/dev/null; then
    hook_delegation_found="found"
else
    hook_delegation_found="missing"
fi
assert_eq "test_hook_md_has_delegation_guidance" "found" "$hook_delegation_found"
assert_pass_if_clean "test_hook_md_has_delegation_guidance"

print_summary

# ---------------------------------------------------------------------------
# Test-gate anchor block
# ---------------------------------------------------------------------------
_TEST_GATE_ANCHORS=(
    test_skill_md_has_delegation_section
    test_skill_md_has_three_red_flag_patterns
    test_skill_md_delegation_section_line_count
    test_skill_md_has_recursive_scope_note
    test_hook_md_has_delegation_guidance
)
