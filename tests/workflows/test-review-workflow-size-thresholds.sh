#!/usr/bin/env bash
# tests/workflows/test-review-workflow-size-thresholds.sh
# RED tests for size-based model upgrade and rejection branching in REVIEW-WORKFLOW.md Step 3.
#
# These tests define the EXPECTED behavior of Step 3 size threshold handling.
# They are RED until the implementation is added to REVIEW-WORKFLOW.md Step 3.
#
# Usage: bash tests/workflows/test-review-workflow-size-thresholds.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
WORKFLOW_FILE="$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-review-workflow-size-thresholds.sh ==="
echo ""

# ============================================================
# _simulate_step3_dispatch()
#
# Implements the Step 3 classifier-reading and size-threshold logic as a
# testable shell function. This function mirrors what REVIEW-WORKFLOW.md
# Step 3 bash blocks implement — tests here define the expected behavior spec.
#
# Inputs (environment variables):
#   CLASSIFIER_JSON   — JSON string from classifier (required)
#   REVIEW_PASS_NUM   — Review pass number; defaults to 1 (1=first pass, 2+=re-review)
#
# Outputs (environment variables set by this function):
#   REVIEW_AGENT      — Agent to dispatch (e.g., "dso:code-reviewer-light")
#   REVIEW_TIER       — Tier selected (light/standard/deep)
#   SIZE_ACTION       — size_action from classifier (none/upgrade/reject)
#   SIZE_REJECTION    — "1" if review is rejected due to size; "0" otherwise
#   SIZE_REJECTION_MSG — Human-readable rejection message (when SIZE_REJECTION=1)
# ============================================================
_simulate_step3_dispatch() {
    local classifier_json="${CLASSIFIER_JSON:-}"
    local review_pass_num="${REVIEW_PASS_NUM:-1}"

    # Reset output variables
    REVIEW_AGENT=""
    REVIEW_TIER=""
    SIZE_ACTION="none"
    SIZE_REJECTION="0"
    SIZE_REJECTION_MSG=""

    # Extract fields from classifier JSON
    if ! echo "$classifier_json" | python3 -c 'import json,sys; json.load(sys.stdin)' 2>/dev/null; then
        # Classifier JSON is invalid — default to standard
        REVIEW_TIER="standard"
        REVIEW_AGENT="dso:code-reviewer-standard"
        SIZE_ACTION="none"
        return 0
    fi

    REVIEW_TIER=$(echo "$classifier_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("selected_tier","standard"))' 2>/dev/null) || REVIEW_TIER="standard"
    SIZE_ACTION=$(echo "$classifier_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("size_action","none"))' 2>/dev/null) || SIZE_ACTION="none"
    local is_merge_commit
    is_merge_commit=$(echo "$classifier_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(str(d.get("is_merge_commit",False)).lower())' 2>/dev/null) || is_merge_commit="false"

    # Determine base agent from tier
    case "$REVIEW_TIER" in
        light)    REVIEW_AGENT="dso:code-reviewer-light" ;;
        standard) REVIEW_AGENT="dso:code-reviewer-standard" ;;
        deep)     REVIEW_AGENT="deep-multi-reviewer" ;;
        *)        REVIEW_TIER="standard"; REVIEW_AGENT="dso:code-reviewer-standard" ;;
    esac

    # Size threshold handling:
    # - merge commits bypass size limits entirely
    # - re-review passes (REVIEW_PASS_NUM >= 2) bypass size limits
    # - size_action=upgrade: upgrade agent to opus
    # - size_action=reject: reject with guidance
    # - size_action=none: no change

    # Bypass conditions
    if [[ "$is_merge_commit" == "true" ]] || [[ "$review_pass_num" -ge 2 ]] 2>/dev/null; then
        # Bypass size limits
        SIZE_ACTION="none"
        return 0
    fi

    # Apply size action
    case "$SIZE_ACTION" in
        upgrade)
            # Upgrade to opus for oversized but not rejected diffs
            REVIEW_AGENT="dso:code-reviewer-opus"
            ;;
        reject)
            # Reject the review — diff too large
            SIZE_REJECTION="1"
            SIZE_REJECTION_MSG="ERROR: Diff is too large for automated review. Split your changes into smaller commits before reviewing. See: large-diff-splitting-guide.md"
            ;;
        none|*)
            # No size change — keep tier-selected agent
            ;;
    esac

    return 0
}

# ============================================================
# Test functions (5 RED tests for Step 3 size-threshold behaviors)
# ============================================================

test_workflow_step3_upgrade_when_size_action_is_upgrade() {
    # Given classifier JSON with size_action: "upgrade" and REVIEW_TIER: "light",
    # assert that REVIEW_AGENT includes "opus" or upgrade logic is applied.
    _snapshot_fail
    CLASSIFIER_JSON='{"selected_tier":"light","size_action":"upgrade","is_merge_commit":false,"blast_radius":0,"computed_total":1}'
    REVIEW_PASS_NUM=1
    _simulate_step3_dispatch
    assert_contains "test_workflow_step3_upgrade_when_size_action_is_upgrade: REVIEW_AGENT contains opus when size_action=upgrade" \
        "opus" "$REVIEW_AGENT"
    assert_eq "test_workflow_step3_upgrade_when_size_action_is_upgrade: SIZE_REJECTION is 0 (not rejected)" \
        "0" "$SIZE_REJECTION"
    assert_pass_if_clean "test_workflow_step3_upgrade_when_size_action_is_upgrade: helper logic"

    # RED check: verify REVIEW-WORKFLOW.md Step 3 has the upgrade logic (fails until implemented)
    _snapshot_fail
    step3_has_upgrade_logic=0
    grep -qE 'size_action.*upgrade|upgrade.*opus|SIZE_ACTION.*upgrade' "$WORKFLOW_FILE" 2>/dev/null && step3_has_upgrade_logic=1
    assert_eq "test_workflow_step3_upgrade_when_size_action_is_upgrade: REVIEW-WORKFLOW.md Step 3 contains upgrade logic (RED until implemented)" \
        "1" "$step3_has_upgrade_logic"
    assert_pass_if_clean "test_workflow_step3_upgrade_when_size_action_is_upgrade"
}

test_workflow_step3_reject_when_size_action_is_reject() {
    # Given classifier JSON with size_action: "reject", assert the workflow outputs
    # a rejection message containing the path large-diff-splitting-guide.md and sets rejection flag.
    _snapshot_fail
    CLASSIFIER_JSON='{"selected_tier":"standard","size_action":"reject","is_merge_commit":false,"blast_radius":2,"computed_total":4}'
    REVIEW_PASS_NUM=1
    _simulate_step3_dispatch
    assert_eq "test_workflow_step3_reject_when_size_action_is_reject: SIZE_REJECTION is set to 1" \
        "1" "$SIZE_REJECTION"
    assert_contains "test_workflow_step3_reject_when_size_action_is_reject: rejection message contains large-diff-splitting-guide.md" \
        "large-diff-splitting-guide.md" "$SIZE_REJECTION_MSG"
    assert_pass_if_clean "test_workflow_step3_reject_when_size_action_is_reject: helper logic"

    # RED check: verify REVIEW-WORKFLOW.md Step 3 has the reject logic (fails until implemented)
    _snapshot_fail
    step3_has_reject_logic=0
    grep -qE 'size_action.*reject|large-diff-splitting-guide|SIZE_REJECTION' "$WORKFLOW_FILE" 2>/dev/null && step3_has_reject_logic=1
    assert_eq "test_workflow_step3_reject_when_size_action_is_reject: REVIEW-WORKFLOW.md Step 3 contains reject logic (RED until implemented)" \
        "1" "$step3_has_reject_logic"
    assert_pass_if_clean "test_workflow_step3_reject_when_size_action_is_reject"
}

test_workflow_step3_no_size_limit_on_repass() {
    # Given REVIEW_PASS_NUM=2 (re-review pass), assert size limits are bypassed even
    # when classifier returns size_action: "reject".
    _snapshot_fail
    CLASSIFIER_JSON='{"selected_tier":"standard","size_action":"reject","is_merge_commit":false,"blast_radius":2,"computed_total":4}'
    REVIEW_PASS_NUM=2
    _simulate_step3_dispatch
    assert_eq "test_workflow_step3_no_size_limit_on_repass: SIZE_REJECTION is 0 on re-review pass" \
        "0" "$SIZE_REJECTION"
    assert_ne "test_workflow_step3_no_size_limit_on_repass: REVIEW_AGENT is not empty on re-review pass" \
        "" "$REVIEW_AGENT"
    assert_pass_if_clean "test_workflow_step3_no_size_limit_on_repass: helper logic"

    # RED check: verify REVIEW-WORKFLOW.md Step 3 has the re-review bypass (fails until implemented)
    _snapshot_fail
    step3_has_repass_bypass=0
    grep -qE 'REVIEW_PASS_NUM|repass|re.review.*bypass|bypass.*re.review' "$WORKFLOW_FILE" 2>/dev/null && step3_has_repass_bypass=1
    assert_eq "test_workflow_step3_no_size_limit_on_repass: REVIEW-WORKFLOW.md Step 3 contains re-review bypass (RED until implemented)" \
        "1" "$step3_has_repass_bypass"
    assert_pass_if_clean "test_workflow_step3_no_size_limit_on_repass"
}

test_workflow_step3_merge_commit_bypass() {
    # Given classifier JSON with is_merge_commit: true, assert size limits are bypassed.
    _snapshot_fail
    CLASSIFIER_JSON='{"selected_tier":"light","size_action":"reject","is_merge_commit":true,"blast_radius":0,"computed_total":0}'
    REVIEW_PASS_NUM=1
    _simulate_step3_dispatch
    assert_eq "test_workflow_step3_merge_commit_bypass: SIZE_REJECTION is 0 for merge commits" \
        "0" "$SIZE_REJECTION"
    assert_ne "test_workflow_step3_merge_commit_bypass: REVIEW_AGENT is not empty for merge commits" \
        "" "$REVIEW_AGENT"
    assert_pass_if_clean "test_workflow_step3_merge_commit_bypass: helper logic"

    # RED check: verify REVIEW-WORKFLOW.md Step 3 has merge commit bypass (fails until implemented)
    _snapshot_fail
    step3_has_merge_bypass=0
    grep -qE 'is_merge_commit|merge_commit.*bypass|bypass.*merge' "$WORKFLOW_FILE" 2>/dev/null && step3_has_merge_bypass=1
    assert_eq "test_workflow_step3_merge_commit_bypass: REVIEW-WORKFLOW.md Step 3 contains merge commit bypass (RED until implemented)" \
        "1" "$step3_has_merge_bypass"
    assert_pass_if_clean "test_workflow_step3_merge_commit_bypass"
}

test_workflow_step3_no_change_when_size_action_none() {
    # Given size_action: "none", assert REVIEW_AGENT is unchanged from the tier-only value.
    _snapshot_fail
    # Test light tier with no size action
    CLASSIFIER_JSON='{"selected_tier":"light","size_action":"none","is_merge_commit":false,"blast_radius":0,"computed_total":1}'
    REVIEW_PASS_NUM=1
    _simulate_step3_dispatch
    assert_eq "test_workflow_step3_no_change_when_size_action_none: light tier stays light when size_action=none" \
        "dso:code-reviewer-light" "$REVIEW_AGENT"
    assert_eq "test_workflow_step3_no_change_when_size_action_none: SIZE_REJECTION is 0 when size_action=none" \
        "0" "$SIZE_REJECTION"
    # Test standard tier with no size action
    CLASSIFIER_JSON='{"selected_tier":"standard","size_action":"none","is_merge_commit":false,"blast_radius":1,"computed_total":3}'
    REVIEW_PASS_NUM=1
    _simulate_step3_dispatch
    assert_eq "test_workflow_step3_no_change_when_size_action_none: standard tier stays standard when size_action=none" \
        "dso:code-reviewer-standard" "$REVIEW_AGENT"
    assert_pass_if_clean "test_workflow_step3_no_change_when_size_action_none: helper logic"

    # RED check: verify REVIEW-WORKFLOW.md Step 3 reads size_action field at all (fails until implemented)
    _snapshot_fail
    step3_reads_size_action=0
    grep -q 'size_action' "$WORKFLOW_FILE" 2>/dev/null && step3_reads_size_action=1
    assert_eq "test_workflow_step3_no_change_when_size_action_none: REVIEW-WORKFLOW.md Step 3 reads size_action field (RED until implemented)" \
        "1" "$step3_reads_size_action"
    assert_pass_if_clean "test_workflow_step3_no_change_when_size_action_none"
}

# ============================================================
# Run all tests
# ============================================================
test_workflow_step3_upgrade_when_size_action_is_upgrade
echo ""
test_workflow_step3_reject_when_size_action_is_reject
echo ""
test_workflow_step3_no_size_limit_on_repass
echo ""
test_workflow_step3_merge_commit_bypass
echo ""
test_workflow_step3_no_change_when_size_action_none
echo ""
print_summary
