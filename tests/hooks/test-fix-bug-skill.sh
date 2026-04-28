#!/usr/bin/env bash
# tests/hooks/test-fix-bug-skill.sh
# Verifies that the /dso:fix-bug skill file exists at
# skills/fix-bug/SKILL.md and contains the
# required frontmatter and content sections.
#
# RED PHASE: All tests are expected to FAIL until the skill is implemented.
#
# Usage:
#   bash tests/hooks/test-fix-bug-skill.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

SKILL_FILE="$DSO_PLUGIN_DIR/skills/fix-bug/SKILL.md"

echo "=== test-fix-bug-skill.sh ==="

# test_fix_bug_skill_file_exists
# The SKILL.md must exist at the expected path.
if [[ -f "$SKILL_FILE" ]]; then
    actual="exists"
else
    actual="missing"
fi
assert_eq "test_fix_bug_skill_file_exists" "exists" "$actual"

# test_fix_bug_skill_frontmatter_name
# Frontmatter must declare: name: fix-bug
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q "^name: fix-bug" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_fix_bug_skill_frontmatter_name" "present" "$actual"
fi

# test_fix_bug_skill_user_invocable
# Frontmatter must declare: user-invocable: true
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q "^user-invocable: true" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_fix_bug_skill_user_invocable" "present" "$actual"
fi

# test_fix_bug_skill_mechanical_path_section
# Skill must reference a mechanical path for classification/routing.
if [[ -f "$SKILL_FILE" ]]; then
    if grep -qi "mechanical" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_fix_bug_skill_mechanical_path_section" "present" "$actual"
fi

# test_fix_bug_skill_scoring_section
# Skill must include a scoring rubric for bug classification.
if [[ -f "$SKILL_FILE" ]]; then
    if grep -qi "scor" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_fix_bug_skill_scoring_section" "present" "$actual"
fi

# test_fix_bug_skill_config_resolution_section
# Skill must document Config Resolution steps or section.
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q "Config Resolution" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_fix_bug_skill_config_resolution_section" "present" "$actual"
fi

# test_fix_bug_skill_workflow_skeleton_section
# Skill must include workflow step indicators (e.g., Step 1, Phase 1, or numbered steps).
if [[ -f "$SKILL_FILE" ]]; then
    if grep -qE "^(Step [0-9]|Phase [0-9]|[0-9]+\\.)" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_fix_bug_skill_workflow_skeleton_section" "present" "$actual"
fi

# test_fix_bug_skill_complexity_evaluation
# Skill must include a Phase D Step 2 (Fix Complexity Evaluation) heading AND reference the complexity-evaluator.
if [[ -f "$SKILL_FILE" ]]; then
    if grep -qE "Phase D Step 2|Fix Complexity Evaluation" "$SKILL_FILE" && grep -q "complexity-evaluator" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_fix_bug_skill_complexity_evaluation" "present" "$actual"
fi

# test_fix_bug_skill_escalation_report
# Skill must include an 'Escalation Report' section with fields 'bug_id' and 'investigation_findings'.
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q "Escalation Report" "$SKILL_FILE" && grep -q "bug_id" "$SKILL_FILE" && grep -q "investigation_findings" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_fix_bug_skill_escalation_report" "present" "$actual"
fi

# test_fix_bug_skill_subagent_detection
# Skill must reference 'running as a sub-agent' AND 'Agent tool'.
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q "running as a sub-agent" "$SKILL_FILE" && grep -q "Agent tool" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_fix_bug_skill_subagent_detection" "present" "$actual"
fi

# test_fix_bug_skill_hard_gate_present
# Skill must contain a HARD-GATE block in the preamble.
if [[ -f "$SKILL_FILE" ]]; then
    if grep -q "HARD-GATE" "$SKILL_FILE"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_fix_bug_skill_hard_gate_present" "present" "$actual"
fi

# test_fix_bug_skill_hard_gate_prohibits_code_before_steps
# The HARD-GATE block must prohibit code modification before completing Steps 1-5.
if [[ -f "$SKILL_FILE" ]]; then
    _tmp=$(grep -A10 "HARD-GATE" "$SKILL_FILE"); if grep -qiE "step.*1.*5|steps 1|before.*step|1 through 5" <<< "$_tmp"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_fix_bug_skill_hard_gate_prohibits_code_before_steps" "present" "$actual"
fi

# test_fix_bug_skill_hard_gate_prohibits_inline_investigation
# The HARD-GATE block must explicitly prohibit inline investigation as a
# substitute for sub-agent dispatch. This prevents agents from rationalizing
# "I'll just investigate quickly before dispatching". The phrase "inline" must
# appear within 20 lines of the HARD-GATE marker.
if [[ -f "$SKILL_FILE" ]]; then
    _tmp=$(grep -A20 "HARD-GATE" "$SKILL_FILE"); if grep -qi "inline" <<< "$_tmp"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_fix_bug_skill_hard_gate_prohibits_inline_investigation" "present" "$actual"
fi

# test_fix_bug_skill_step2_mandatory_dispatch_directive
# Investigation Sub-Agent Dispatch step (Phase C Step 1) must contain a mandatory dispatch directive ("MUST dispatch" or
# "YOU MUST dispatch") that explicitly requires sub-agent dispatch rather
# than leaving it as an option the orchestrator can rationalize around.
if [[ -f "$SKILL_FILE" ]]; then
    _tmp=$(grep -A30 -E "Step [0-9]+: Investigation Sub-Agent Dispatch" "$SKILL_FILE"); if grep -qE "MUST dispatch|YOU MUST dispatch" <<< "$_tmp"; then
        actual="present"
    else
        actual="missing"
    fi
    assert_eq "test_fix_bug_skill_step2_mandatory_dispatch_directive" "present" "$actual"
fi

print_summary
