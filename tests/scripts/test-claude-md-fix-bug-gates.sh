#!/usr/bin/env bash
# tests/scripts/test-claude-md-fix-bug-gates.sh
# Tests: assert CLAUDE.md reflects hypothesis enforcement gates added in epic b7ac-1d7f,
# and SKILL.md documents new gates added in epic fe4c-8dc2.
#
# Verifies that CLAUDE.md documents:
#   1. hypothesis_tests field in the fix-bug RESULT schema (replaces tests_run)
#   2. RED-before-fix gate (Step 5.5 blocks code modification until RED test confirmed)
#
# Verifies that fix-bug SKILL.md documents:
#   3. Step 7.5 Anti-Pattern Scan as a mandatory post-fix step
#   4. root_cause_report enforcement (agent separation gate in Step 6)
#
# These are agent-awareness requirements — future agents reading CLAUDE.md must know
# the investigation RESULT must include hypothesis_tests and that code changes are
# blocked until a RED test is confirmed failing.
#
# Usage: bash tests/scripts/test-claude-md-fix-bug-gates.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
CLAUDE_MD="$REPO_ROOT/CLAUDE.md"
FIX_BUG_SKILL_MD="$PLUGIN_ROOT/plugins/dso/skills/fix-bug/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-claude-md-fix-bug-gates.sh ==="
echo ""

# ── test_claude_md_hypothesis_tests_field ─────────────────────────────────────
# CLAUDE.md must reference hypothesis_tests as the RESULT schema field
# for fix-bug investigation results. This replaces the old tests_run field.
# Future agents need to know investigation results require hypothesis_tests.
claude_md_content="$(cat "$CLAUDE_MD")"

assert_contains \
    "test_claude_md_hypothesis_tests_field: CLAUDE.md mentions hypothesis_tests" \
    "hypothesis_tests" \
    "$claude_md_content"
echo ""

# ── test_claude_md_red_before_fix_gate ────────────────────────────────────────
# CLAUDE.md must reference the RED-before-fix gate so agents know that
# code modification (Edit, Write, fix sub-agent dispatch) is blocked until
# a RED test is confirmed failing.
assert_contains \
    "test_claude_md_red_before_fix_gate: CLAUDE.md mentions RED-before-fix gate" \
    "RED-before-fix" \
    "$claude_md_content"
echo ""

# ── test_anti_pattern_scan_mandatory ─────────────────────────────────────────
# SKILL.md must document Step 7.5 Anti-Pattern Scan as a mandatory post-fix step.
# Future agents must know that after the fix is verified GREEN, they must scan
# for other occurrences of the same anti-pattern in the codebase.
skill_md_content="$(cat "$FIX_BUG_SKILL_MD")"

assert_contains \
    "test_anti_pattern_scan_mandatory: SKILL.md contains Step 7.5 Anti-Pattern Scan" \
    "Step 7.5" \
    "$skill_md_content"
echo ""

# ── test_agent_separation_gate_documented ─────────────────────────────────────
# SKILL.md must document the root_cause_report enforcement gate in Step 6.
# This agent separation gate prevents the orchestrator from self-producing the
# root_cause_report — it must come from the investigation sub-agent's RESULT.
assert_contains \
    "test_agent_separation_gate_documented: SKILL.md contains root_cause_report enforcement" \
    "root_cause_report" \
    "$skill_md_content"
echo ""

# ── test_claude_md_cli_user_skips_intent_search ───────────────────────────────
# CLAUDE.md architecture table must explicitly document that CLI_user-tagged
# tickets skip intent-search dispatch. The dso:intent-search routing row must
# mention CLI_user within 5 lines (grep -A5 -B5 context window) so future
# agents know to bypass Gate 1a for user-reported bugs.
_snapshot_fail
_intent_context=$(echo "$claude_md_content" | grep -A5 -B5 "intent-search")
_tmp="$_intent_context"
if [[ "$_tmp" == *"CLI_user"* ]]; then
    echo "PASS: test_claude_md_cli_user_skips_intent_search: CLAUDE.md documents CLI_user skip for intent-search"
    (( ++PASS ))
else
    echo "FAIL: test_claude_md_cli_user_skips_intent_search: CLAUDE.md does not document CLI_user skip near intent-search" >&2
    printf "  expected: CLI_user mentioned within 5 lines of intent-search in CLAUDE.md\n" >&2
    printf "  actual:   no CLI_user found near intent-search\n" >&2
    (( ++FAIL ))
fi
echo ""

# ── test_claude_md_gate1a_cli_user_skip_phrase ────────────────────────────────
# CLAUDE.md must contain a phrase near CLI_user that confirms Gate 1a is
# skipped for CLI_user-tagged tickets. Acceptable phrases: "skips", "skip",
# "intent-aligned" (the GATE_1A_RESULT value when bypassed), or "Gate 1a".
_snapshot_fail
_cli_context=$(echo "$claude_md_content" | grep -A3 -B3 "CLI_user")
_tmp="$_cli_context"; shopt -s nocasematch
if [[ "$_tmp" =~ skips?|intent-aligned|"Gate 1a" ]]; then
    shopt -u nocasematch
    echo "PASS: test_claude_md_gate1a_cli_user_skip_phrase"
    (( ++PASS ))
else
    shopt -u nocasematch
    echo "FAIL: test_claude_md_gate1a_cli_user_skip_phrase: CLAUDE.md has no skip/intent-aligned/Gate 1a phrase near CLI_user" >&2
    printf "  expected: skip/intent-aligned/Gate 1a within 3 lines of CLI_user\n" >&2
    printf "  actual:   no qualifying phrase found\n" >&2
    (( ++FAIL ))
fi
echo ""

print_summary
