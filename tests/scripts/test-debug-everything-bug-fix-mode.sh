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
#   ALL 5 tests are RED — no bug-fix mode exists in current SKILL.md.
#
# Exemption: structural metadata validation of prompt file — not executable code.
# RED marker: test_orchestration_flow_has_bug_fix_branch (first RED test — all 5 are RED)
#
# Usage: bash tests/scripts/test-debug-everything-bug-fix-mode.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
SKILL_FILE="$DSO_PLUGIN_DIR/skills/debug-everything/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-debug-everything-bug-fix-mode.sh ==="

# ============================================================
# RED MARKER BOUNDARY
# ALL 5 tests below are RED — bug-fix mode does not yet exist
# in debug-everything/SKILL.md. RED marker in .test-index:
#   [test_orchestration_flow_has_bug_fix_branch]
# ============================================================

# ============================================================
# test_orchestration_flow_has_bug_fix_branch
# The orchestration flow diagram must include a conditional branch
# that routes to bug-fix mode when open bug tickets exist.
# RED: current flow has no such branch.
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
# RED: no such step exists in current SKILL.md.
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
# RED: no bug-fix mode exists in current SKILL.md.
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
# RED: no bug-fix mode exists in current SKILL.md.
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
# RED: no bug-fix mode exists in current SKILL.md.
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
# RED: current SKILL.md bug-fix mode has no CLI_user tag extraction guidance.
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
# RED: current SKILL.md only contains --status=open queries; zero
#      occurrences of --status=in_progress exist in the file.
# GREEN: after the dual-query fix is applied, --status=in_progress
#        appears at least once in the Bug-Fix Mode query context.
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

# Run all tests
test_orchestration_flow_has_bug_fix_branch
test_bug_detection_step_exists
test_bug_fix_mode_skips_diagnostic
test_bug_fix_mode_skips_triage
test_orchestrator_level_fix_bug_invocation
test_bug_fix_mode_extracts_cli_user_tag
test_bug_fix_mode_queries_in_progress_tickets

print_summary
