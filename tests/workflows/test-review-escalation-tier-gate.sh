#!/usr/bin/env bash
# tests/workflows/test-review-escalation-tier-gate.sh
# Bug b5e2-56ad: Verify that REVIEW-WORKFLOW.md and sprint SKILL.md
# structure tier escalation as a hard gate before user escalation.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REVIEW_WF="$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md"
SPRINT_SKILL="$REPO_ROOT/plugins/dso/skills/sprint/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-review-escalation-tier-gate.sh ==="
echo ""

# Defect A: REVIEW-WORKFLOW.md must have tier upgrade as a STOP/DO NOT gate
# before user escalation — not a trailing qualifier
test_review_wf_tier_gate_before_user_escalation() {
    _snapshot_fail
    if [[ ! -f "$REVIEW_WF" ]]; then
        (( ++FAIL ))
        printf "FAIL: REVIEW-WORKFLOW.md not found\n" >&2
        assert_pass_if_clean "test_review_wf_tier_gate_before_user_escalation"
        return
    fi
    # The max attempts section must have STOP/DO NOT PROCEED language
    # that blocks user escalation until tier upgrade is completed
    local _section
    _section=$(sed -n '/Max attempts/,/^[0-9]\+\./p' "$REVIEW_WF" 2>/dev/null)
    local _has_hard_gate=0
    if echo "$_section" | grep -qiE '(STOP|DO NOT PROCEED|MUST.*(first|before)|BLOCKED).*(tier|deep|upgrade)'; then
        _has_hard_gate=1
    fi
    assert_eq "REVIEW-WORKFLOW.md has hard gate (STOP/DO NOT PROCEED) for tier upgrade before user escalation (bug b5e2-56ad)" "1" "$_has_hard_gate"
    assert_pass_if_clean "test_review_wf_tier_gate_before_user_escalation"
}

# Defect B: Sprint SKILL.md cached summary must mention tier upgrade
test_sprint_summary_mentions_tier_upgrade() {
    _snapshot_fail
    if [[ ! -f "$SPRINT_SKILL" ]]; then
        (( ++FAIL ))
        printf "FAIL: sprint SKILL.md not found\n" >&2
        assert_pass_if_clean "test_sprint_summary_mentions_tier_upgrade"
        return
    fi
    # The "Autonomous resolution" line must mention tier/deep upgrade
    local _summary_line
    _summary_line=$(grep -i 'autonomous resolution' "$SPRINT_SKILL" 2>/dev/null || echo "")
    local _mentions_tier=0
    if echo "$_summary_line" | grep -qiE '(tier|deep|upgrade|light.*standard.*deep|escalat.*tier)'; then
        _mentions_tier=1
    fi
    assert_eq "sprint SKILL.md cached summary mentions tier upgrade in autonomous resolution (bug b5e2-56ad)" "1" "$_mentions_tier"
    assert_pass_if_clean "test_sprint_summary_mentions_tier_upgrade"
}

# Verify escalation table routes ALL tiers (not just deep) to full deep path at PASS_NUM 3+
test_escalation_table_all_tiers_full_deep() {
    _snapshot_fail
    if [[ ! -f "$REVIEW_WF" ]]; then
        (( ++FAIL ))
        printf "FAIL: REVIEW-WORKFLOW.md not found\n" >&2
        assert_pass_if_clean "test_escalation_table_all_tiers_full_deep"
        return
    fi
    # The PASS_NUM 3+ row must NOT route light/standard to deep-arch alone
    # It must route ALL tiers to the full deep-multi-reviewer path
    local _table_row
    _table_row=$(grep -A1 '3+' "$REVIEW_WF" | grep -i 'upgrade\|light.*standard' 2>/dev/null || echo "")
    local _routes_all_to_full=0
    # The row should mention all tiers going to full deep path, not deep-arch alone for light/standard
    if echo "$_table_row" | grep -qiE 'light/standard/deep.*full deep|all.*full deep'; then
        _routes_all_to_full=1
    fi
    assert_eq "escalation table routes ALL tiers to full deep path at PASS_NUM 3+ (not deep-arch alone)" "1" "$_routes_all_to_full"
    assert_pass_if_clean "test_escalation_table_all_tiers_full_deep"
}

echo "--- test_escalation_table_all_tiers_full_deep ---"
test_escalation_table_all_tiers_full_deep
echo ""

echo "--- test_review_wf_tier_gate_before_user_escalation ---"
test_review_wf_tier_gate_before_user_escalation
echo ""

echo "--- test_sprint_summary_mentions_tier_upgrade ---"
test_sprint_summary_mentions_tier_upgrade
echo ""

print_summary
