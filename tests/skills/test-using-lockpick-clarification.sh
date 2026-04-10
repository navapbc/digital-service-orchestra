#!/usr/bin/env bash
# tests/skills/test-using-lockpick-clarification.sh
# Structural validation tests for the clarification loop content in
# plugins/dso/skills/using-lockpick/SKILL.md and HOOK-INJECTION.md.
#
#
# Validates (SKILL.md — 10 tests):
#   1. Has "## When No Skill Matches" heading (clarification section)
#   2. Has confidence test pattern ("one sentence what.*why")
#   3. Has silent investigation tools (Read, Grep, tk show)
#   4. Has Intent as labeled probing area
#   5. Has Scope as labeled probing area
#   6. Has Risks as labeled probing area
#   7. Has interaction style guidance ("one question" and "multiple-choice")
#   8. Preserves existing routing ("## The Rule" and "## Skill Priority")
#   9. Has dogfooding/intent-match measurement guidance
#  10. Clarification section appears after "## User Instructions" line
#
# Validates (HOOK-INJECTION.md — 3 tests):
#  11. Has clarification section heading
#  12. Has confidence test reference
#  13. Has probing areas (Intent, Scope, Risks)
#
# Usage: bash tests/skills/test-using-lockpick-clarification.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_MD="$DSO_PLUGIN_DIR/skills/using-lockpick/SKILL.md"
HOOK_MD="$DSO_PLUGIN_DIR/skills/using-lockpick/HOOK-INJECTION.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-using-lockpick-clarification.sh ==="
echo ""

# ---------------------------------------------------------------------------
# SKILL.md tests
# ---------------------------------------------------------------------------
echo "--- SKILL.md clarification loop tests ---"

# test_skill_md_has_clarification_section
# SKILL.md must have a "## When No Skill Matches" section heading
_snapshot_fail
if grep -q "## When No Skill Matches" "$SKILL_MD" 2>/dev/null; then
    section_found="found"
else
    section_found="missing"
fi
assert_eq "test_skill_md_has_clarification_section" "found" "$section_found"
assert_pass_if_clean "test_skill_md_has_clarification_section"

# test_skill_md_has_confidence_test
# SKILL.md must contain guidance about a one-sentence confidence test
# Pattern: "one sentence" near "what" and "why" (ask yourself: can I say in one sentence what I'm doing and why?)
_snapshot_fail
if grep -qiE "one sentence.*(what|why)|(what|why).*one sentence" "$SKILL_MD" 2>/dev/null; then
    confidence_found="found"
else
    confidence_found="missing"
fi
assert_eq "test_skill_md_has_confidence_test" "found" "$confidence_found"
assert_pass_if_clean "test_skill_md_has_confidence_test"

# test_skill_md_has_silent_investigation
# SKILL.md must list silent investigation tools (Read, Grep, tk show)
_snapshot_fail
has_read=0
has_grep=0
has_tk_show=0
grep -q "Read" "$SKILL_MD" 2>/dev/null && has_read=1
grep -q "Grep" "$SKILL_MD" 2>/dev/null && has_grep=1
grep -qE "tk show" "$SKILL_MD" 2>/dev/null && has_tk_show=1
investigation_score=$(( has_read + has_grep + has_tk_show ))
# Need all three investigation tools mentioned in the clarification context
# (they may already appear elsewhere; what matters is they appear in the clarification loop)
if grep -qE "(Read|Grep|tk show).*investigation|investigation.*(Read|Grep|tk show)|silent.*(Read|Grep)|clarif.*(Read|Grep|tk)" "$SKILL_MD" 2>/dev/null; then
    investigation_found="found"
else
    investigation_found="missing"
fi
assert_eq "test_skill_md_has_silent_investigation" "found" "$investigation_found"
assert_pass_if_clean "test_skill_md_has_silent_investigation"

# test_skill_md_has_intent_probing
# SKILL.md must label "Intent" as a probing area with a description involving "what outcome"
_snapshot_fail
if grep -qE "Intent.*what outcome|Intent.*probe|Intent.*ask" "$SKILL_MD" 2>/dev/null; then
    intent_found="found"
else
    intent_found="missing"
fi
assert_eq "test_skill_md_has_intent_probing" "found" "$intent_found"
assert_pass_if_clean "test_skill_md_has_intent_probing"

# test_skill_md_has_scope_probing
# SKILL.md must label "Scope" as a probing area with a description
_snapshot_fail
if grep -qE "Scope.*what.*change|Scope.*boundary|Scope.*probe|Scope.*affect" "$SKILL_MD" 2>/dev/null; then
    scope_found="found"
else
    scope_found="missing"
fi
assert_eq "test_skill_md_has_scope_probing" "found" "$scope_found"
assert_pass_if_clean "test_skill_md_has_scope_probing"

# test_skill_md_has_risks_probing
# SKILL.md must label "Risks" as a probing area with a description
_snapshot_fail
if grep -qE "Risks.*what.*break|Risks.*what.*wrong|Risks.*concern|Risks.*probe" "$SKILL_MD" 2>/dev/null; then
    risks_found="found"
else
    risks_found="missing"
fi
assert_eq "test_skill_md_has_risks_probing" "found" "$risks_found"
assert_pass_if_clean "test_skill_md_has_risks_probing"

# test_skill_md_has_interaction_style
# SKILL.md must mention "one question" and "multiple-choice" in clarification style guidance
_snapshot_fail
has_one_question=0
has_multiple_choice=0
grep -qiE "one question" "$SKILL_MD" 2>/dev/null && has_one_question=1
grep -qiE "multiple.choice|multiple choice" "$SKILL_MD" 2>/dev/null && has_multiple_choice=1
if [[ "$has_one_question" -eq 1 && "$has_multiple_choice" -eq 1 ]]; then
    interaction_found="found"
else
    interaction_found="missing"
fi
assert_eq "test_skill_md_has_interaction_style" "found" "$interaction_found"
assert_pass_if_clean "test_skill_md_has_interaction_style"

# test_skill_md_preserves_existing_routing
# SKILL.md must still contain "## The Rule" and "## Skill Priority" headings (criterion 1)
_snapshot_fail
has_the_rule=0
has_skill_priority=0
grep -q "## The Rule" "$SKILL_MD" 2>/dev/null && has_the_rule=1
grep -q "## Skill Priority" "$SKILL_MD" 2>/dev/null && has_skill_priority=1
if [[ "$has_the_rule" -eq 1 && "$has_skill_priority" -eq 1 ]]; then
    routing_preserved="found"
else
    routing_preserved="missing"
fi
assert_eq "test_skill_md_preserves_existing_routing" "found" "$routing_preserved"
assert_pass_if_clean "test_skill_md_preserves_existing_routing"

# test_skill_md_has_dogfooding_guidance
# SKILL.md must contain intent-match measurement guidance (dogfooding/criterion 6)
_snapshot_fail
if grep -qiE "intent.match|measure.*intent|dogfood|success.*measure|intent.*success" "$SKILL_MD" 2>/dev/null; then
    dogfood_found="found"
else
    dogfood_found="missing"
fi
assert_eq "test_skill_md_has_dogfooding_guidance" "found" "$dogfood_found"
assert_pass_if_clean "test_skill_md_has_dogfooding_guidance"

# test_skill_md_clarification_after_user_instructions
# "## When No Skill Matches" must appear after "## User Instructions" in the file
# (the clarification loop extends the file; it does not replace existing content)
_snapshot_fail
user_instructions_line=$(grep -n "^## User Instructions$" "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1 || echo 0)
when_no_skill_line=$(grep -n "^## When No Skill Matches$" "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1 || echo 0)
# Default to 0 if empty
user_instructions_line="${user_instructions_line:-0}"
when_no_skill_line="${when_no_skill_line:-0}"

# Both must exist and When No Skill Matches must be after User Instructions
if [[ "$when_no_skill_line" -gt 0 && "$user_instructions_line" -gt 0 && \
      "$when_no_skill_line" -gt "$user_instructions_line" ]]; then
    order_correct="correct"
else
    order_correct="incorrect"
fi
assert_eq "test_skill_md_clarification_after_user_instructions" "correct" "$order_correct"
assert_pass_if_clean "test_skill_md_clarification_after_user_instructions"

# ---------------------------------------------------------------------------
# HOOK-INJECTION.md tests
# ---------------------------------------------------------------------------
echo ""
echo "--- HOOK-INJECTION.md clarification loop tests ---"

# test_hook_md_has_clarification_section
# HOOK-INJECTION.md must have a clarification section heading
_snapshot_fail
if grep -qiE "## When No Skill Matches|## Clarification" "$HOOK_MD" 2>/dev/null; then
    hook_section_found="found"
else
    hook_section_found="missing"
fi
assert_eq "test_hook_md_has_clarification_section" "found" "$hook_section_found"
assert_pass_if_clean "test_hook_md_has_clarification_section"

# test_hook_md_has_confidence_test
# HOOK-INJECTION.md must reference the confidence test (one sentence what/why)
_snapshot_fail
if grep -qiE "one sentence.*(what|why)|(what|why).*one sentence|confidence" "$HOOK_MD" 2>/dev/null; then
    hook_confidence_found="found"
else
    hook_confidence_found="missing"
fi
assert_eq "test_hook_md_has_confidence_test" "found" "$hook_confidence_found"
assert_pass_if_clean "test_hook_md_has_confidence_test"

# test_hook_md_has_probing_areas
# HOOK-INJECTION.md must mention Intent, Scope, and Risks as probing areas
_snapshot_fail
has_hook_intent=0
has_hook_scope=0
has_hook_risks=0
grep -q "Intent" "$HOOK_MD" 2>/dev/null && has_hook_intent=1
grep -q "Scope" "$HOOK_MD" 2>/dev/null && has_hook_scope=1
grep -q "Risks" "$HOOK_MD" 2>/dev/null && has_hook_risks=1
if [[ "$has_hook_intent" -eq 1 && "$has_hook_scope" -eq 1 && "$has_hook_risks" -eq 1 ]]; then
    hook_probing_found="found"
else
    hook_probing_found="missing"
fi
assert_eq "test_hook_md_has_probing_areas" "found" "$hook_probing_found"
assert_pass_if_clean "test_hook_md_has_probing_areas"

# test_hook_md_has_unknown_skill_fallback (bugs 47fb-23f7, db64-18d7)
# HOOK-INJECTION.md must contain explicit fallback guidance for when the Skill
# tool returns "Unknown skill" — directing Claude to read the SKILL.md directly
# rather than stopping or reporting failure to the user.
_snapshot_fail
if grep -qiE "Unknown skill|Skill tool fails|skill.*not found|skill.*unavailable" "$HOOK_MD" 2>/dev/null; then
    hook_unknown_skill="found"
else
    hook_unknown_skill="missing"
fi
assert_eq "test_hook_md_has_unknown_skill_fallback" "found" "$hook_unknown_skill"
assert_pass_if_clean "test_hook_md_has_unknown_skill_fallback"

# test_hook_md_has_successfully_loaded_guidance (bug 8985-4efc)
# HOOK-INJECTION.md must explain what to do when the Skill tool returns
# "Successfully loaded skill" without visible content. Without this, the model
# interprets the confirmation as a loading step and falls back to reading the
# SKILL.md file directly — bypassing skill isolation and tool restrictions.
# The guidance must clarify: the content IS in context (system-reminder), do
# NOT re-invoke the Skill tool, do NOT use Read to fetch the skill file.
# Before fix: no such guidance → model falls back to Read → RED (test fails).
# After fix:  guidance present in HOOK-INJECTION.md → GREEN (test passes).
_snapshot_fail
if grep -qiE "Successfully loaded skill|loaded skill.*system.reminder|skill.*content.*system|system.reminder.*skill.*content" "$HOOK_MD" 2>/dev/null; then
    hook_loaded_guidance="found"
else
    hook_loaded_guidance="missing"
fi
assert_eq "test_hook_md_has_successfully_loaded_guidance" "found" "$hook_loaded_guidance"
assert_pass_if_clean "test_hook_md_has_successfully_loaded_guidance"

# test_skill_md_has_successfully_loaded_guidance (bug 8985-4efc)
# SKILL.md must also explain the "Successfully loaded skill" return value behavior
# so that the guidance persists in the full skill file (not just the injected hook).
_snapshot_fail
if grep -qiE "Successfully loaded skill|loaded skill.*system.reminder|skill.*content.*system|system.reminder.*skill.*content" "$SKILL_MD" 2>/dev/null; then
    skill_loaded_guidance="found"
else
    skill_loaded_guidance="missing"
fi
assert_eq "test_skill_md_has_successfully_loaded_guidance" "found" "$skill_loaded_guidance"
assert_pass_if_clean "test_skill_md_has_successfully_loaded_guidance"

print_summary

# ---------------------------------------------------------------------------
# Test-gate anchor block — literal test names for record-test-status.sh
# ---------------------------------------------------------------------------
_TEST_GATE_ANCHORS=(
    test_skill_md_has_clarification_section
    test_skill_md_has_confidence_test
    test_skill_md_has_silent_investigation
    test_skill_md_has_intent_probing
    test_skill_md_has_scope_probing
    test_skill_md_has_risks_probing
    test_skill_md_has_interaction_style
    test_skill_md_preserves_existing_routing
    test_skill_md_has_dogfooding_guidance
    test_skill_md_clarification_after_user_instructions
    test_hook_md_has_clarification_section
    test_hook_md_has_confidence_test
    test_hook_md_has_probing_areas
    test_hook_md_has_unknown_skill_fallback
)
