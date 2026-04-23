#!/usr/bin/env bash
# tests/scripts/test-debug-everything-bug-fix-mode.sh
# Structural metadata validation of debug-everything SKILL.md bug-fix mode entry path.
#
# Verifies that the debug-everything skill includes a bug-fix mode that:
#   1. Has a conditional branch in the orchestration flow for open bugs
#   2. Checks for open bug tickets before diagnostic scan
#   3. Explicitly skips the diagnostic scan in bug-fix mode
#   4. Explicitly skips triage sub-agent dispatch in bug-fix mode
#   5. Invokes /dso:fix-bug at orchestrator level (NOT via Task tool) in bug-fix mode
#
# Test status:
#   ALL 7 tests pass GREEN — bug-fix mode is implemented and verified.
#
# Exemption: structural metadata validation of prompt file — not executable code.
#
# Usage: bash tests/scripts/test-debug-everything-bug-fix-mode.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_FILE="$DSO_PLUGIN_DIR/skills/debug-everything/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-debug-everything-bug-fix-mode.sh ==="

# ============================================================
# test_orchestration_flow_has_bug_fix_branch
# The orchestration flow diagram must include a conditional branch
# that routes to bug-fix mode when open bug tickets exist.
# ============================================================
test_orchestration_flow_has_bug_fix_branch() {
    local branch_found="missing"

    # Look for a conditional branch referencing open bugs and bug-fix mode
    # in either a flow diagram (e.g., "[open bugs: bug-fix mode]") or prose summary
    # (e.g., "Bug-Fix Mode — when open bug tickets exist")
    if grep -qE '\[open bugs?.*bug.?fix|bug.?fix.*mode.*open bugs?|Bug.?Fix Mode.*open bug tickets' "$SKILL_FILE" 2>/dev/null; then
        branch_found="found"
    fi

    assert_eq "test_orchestration_flow_has_bug_fix_branch: flow diagram has open-bugs → bug-fix-mode branch" "found" "$branch_found"
}

# ============================================================
# test_bug_detection_step_exists
# SKILL.md must document a step that checks for open bug tickets
# before launching the diagnostic scan.
# ============================================================
test_bug_detection_step_exists() {
    local detection_step_found="missing"

    # Look for a step that checks for open bug tickets specifically BEFORE launching
    # the diagnostic scan (not just any mention of "open bugs" in lifecycle sections).
    # Must reference checking/detecting open bugs as a gating step.
    if grep -qE '(check.*open bug tickets?|detect.*open bug tickets?|open bug tickets?.*before.*diagnostic|open bug tickets?.*entry.*check|Step.*open bug tickets?)' "$SKILL_FILE" 2>/dev/null; then
        detection_step_found="found"
    fi

    assert_eq "test_bug_detection_step_exists: step checking for open bug tickets before diagnostic scan" "found" "$detection_step_found"
}

# ============================================================
# test_bug_fix_mode_skips_diagnostic
# Bug-fix mode must explicitly state that the diagnostic scan
# (Phase 1) is skipped.
# ============================================================
test_bug_fix_mode_skips_diagnostic() {
    local skip_diagnostic_found="missing"

    # Look for explicit skip of diagnostic scan in bug-fix mode section
    if grep -qEi '(bug.?fix mode.*skip.*diagnostic|skip.*diagnostic.*bug.?fix mode|diagnostic.*skipped.*bug.?fix|bug.?fix.*diagnostic.*skip)' "$SKILL_FILE" 2>/dev/null; then
        skip_diagnostic_found="found"
    fi

    assert_eq "test_bug_fix_mode_skips_diagnostic: bug-fix mode explicitly skips diagnostic scan" "found" "$skip_diagnostic_found"
}

# ============================================================
# test_bug_fix_mode_skips_triage
# Bug-fix mode must explicitly state that triage sub-agent
# dispatch is skipped.
# ============================================================
test_bug_fix_mode_skips_triage() {
    local skip_triage_found="missing"

    # Look for explicit skip of triage in bug-fix mode section
    if grep -qEi '(bug.?fix mode.*skip.*triage|skip.*triage.*bug.?fix mode|triage.*skipped.*bug.?fix|bug.?fix.*triage.*skip)' "$SKILL_FILE" 2>/dev/null; then
        skip_triage_found="found"
    fi

    assert_eq "test_bug_fix_mode_skips_triage: bug-fix mode explicitly skips triage sub-agent dispatch" "found" "$skip_triage_found"
}

# ============================================================
# test_orchestrator_level_fix_bug_invocation
# In bug-fix mode, /dso:fix-bug must be invoked at orchestrator
# level (reads SKILL.md inline), NOT via Task tool dispatch.
# Scope: search only within the bug-fix mode section of SKILL.md,
# not the whole file (Phase 5 legitimately uses Task tool dispatch).
# ============================================================
test_orchestrator_level_fix_bug_invocation() {
    local inline_invocation_found="missing"

    # Extract the bug-fix mode section (from a "Bug-Fix Mode" heading to the next top-level heading)
    # then check that it references inline/orchestrator-level fix-bug invocation (not Task tool)
    local bug_fix_section
    bug_fix_section=$(python3 - "$SKILL_FILE" <<'PYEOF'
import sys, re

skill_file = sys.argv[1]
try:
    content = open(skill_file).read()
except FileNotFoundError:
    sys.exit(0)

# Find the bug-fix mode section (case-insensitive heading match)
# Matches ## or ### headings containing "bug-fix mode" or "bug fix mode"
section_match = re.search(
    r'(?m)^#{1,3}\s+.*?[Bb]ug.?[Ff]ix\s+[Mm]ode.*?$(.+?)(?=^#{1,3}\s|\Z)',
    content,
    re.DOTALL
)
if section_match:
    print(section_match.group(1))
PYEOF
)

    # In the extracted section, check for orchestrator-level invocation pattern
    # (reads SKILL.md inline, not via Task tool)
    if [[ -n "$bug_fix_section" ]]; then
        _tmp="$bug_fix_section"; shopt -s nocasematch
        if [[ "$_tmp" =~ inline|orchestrator.*level|reads.*SKILL\.md|NOT.*Task\ tool|not.*via.*Task ]]; then
            shopt -u nocasematch
            inline_invocation_found="found"
        else
            shopt -u nocasematch
        fi
    fi

    assert_eq "test_orchestrator_level_fix_bug_invocation: bug-fix mode invokes fix-bug inline at orchestrator level (not Task tool)" "found" "$inline_invocation_found"
}

# ============================================================
# test_bug_fix_mode_extracts_cli_user_tag
# In bug-fix mode, before inlining fix-bug steps for each ticket,
# the orchestrator must extract tags from ticket show output and
# check for the CLI_user tag to determine the correct fix-bug path.
# ============================================================
test_bug_fix_mode_extracts_cli_user_tag() {
    local skill_content
    skill_content=$(cat "$SKILL_FILE" 2>/dev/null || true)

    local tag_extraction_found="missing"

    # Look for guidance that instructs extracting tags from ticket show output
    # and checking for BUG_TAGS or CLI_user tag specifically before inlining fix-bug.
    _tmp="$skill_content"
    if [[ "$_tmp" =~ BUG_TAGS|CLI_user|cli.user.*tag|tag.*cli.user ]]; then
        tag_extraction_found="found"
    fi

    assert_eq "test_bug_fix_mode_extracts_cli_user_tag: bug-fix mode extracts CLI_user tag from ticket show output before inlining fix-bug" "found" "$tag_extraction_found"
}

# ============================================================
# test_bug_fix_mode_queries_in_progress_tickets
# The SKILL.md must instruct the agent to query BOTH --status=open
# AND --status=in_progress when listing bug tickets for Bug-Fix Mode.
# Without the --status=in_progress query, bugs stuck in_progress are
# permanently invisible and never retried (bug 774d-4866).
# ============================================================
test_bug_fix_mode_queries_in_progress_tickets() {
    local in_progress_query_count
    in_progress_query_count=$(grep -c -- '--status=in_progress' "$SKILL_FILE" 2>/dev/null || true)

    # Must appear at least once — the dual-query fix adds it at 5 callsites;
    # we assert ≥1 so the test survives future consolidations that preserve
    # the intent without duplicating the flag five times.
    local result="missing"
    if [[ "$in_progress_query_count" -ge 1 ]]; then
        result="found"
    fi

    assert_eq "test_bug_fix_mode_queries_in_progress_tickets: SKILL.md must include --status=in_progress in bug ticket queries" "found" "$result"
}

# ============================================================
# test_compaction_resume_continues_after_ticket
# After a compaction event, COMPACTION_RESUME resumes the in-progress
# ticket — but must also instruct the agent to continue processing
# remaining bugs, not stop after the one resumed ticket.
# Also verifies that the past compaction is NOT treated as a live
# Phase 9 shutdown trigger (e7e8-22b7).
# ============================================================
test_compaction_resume_continues_after_ticket() {
    local skill_content
    skill_content=$(cat "$SKILL_FILE" 2>/dev/null || true)

    local continue_found="missing"
    local no_phase9_found="missing"

    # Must instruct the agent to continue to the next bug after the resumed ticket completes.
    # Require a pattern unique to the COMPACTION_RESUME continuation clause — not the
    # CONTEXT ANCHOR "Do NOT stop or wait" lines that predate this fix.
    if echo "$skill_content" | grep -qiE "do NOT stop.*re-query|After.*in.progress ticket.*complet.*do NOT stop|re-query remaining open.*continu"; then
        continue_found="found"
    fi

    # Must clarify that the past compaction does NOT trigger Phase 9 shutdown
    if echo "$skill_content" | grep -qiE "compaction.{0,60}(NOT|not).{0,60}(signal|trigger).{0,60}Phase 9|Phase 9.{0,60}(NOT|not).{0,60}(triggered|fired).{0,60}compaction|prior.{0,60}compaction.{0,60}NOT|not.{0,60}Phase 9.{0,60}shutdown"; then
        no_phase9_found="found"
    fi

    assert_eq "test_compaction_resume_continues_after_ticket: COMPACTION_RESUME must instruct agent to continue remaining bugs" "found" "$continue_found"
    assert_eq "test_compaction_resume_no_phase9_shutdown: COMPACTION_RESUME must clarify past compaction does NOT trigger Phase 9" "found" "$no_phase9_found"
}

# Run all tests
test_orchestration_flow_has_bug_fix_branch
test_bug_detection_step_exists
test_bug_fix_mode_skips_diagnostic
test_bug_fix_mode_skips_triage
test_orchestrator_level_fix_bug_invocation
test_bug_fix_mode_extracts_cli_user_tag
test_bug_fix_mode_queries_in_progress_tickets
test_compaction_resume_continues_after_ticket

print_summary
