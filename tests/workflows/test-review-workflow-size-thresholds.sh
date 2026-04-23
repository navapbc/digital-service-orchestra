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

# ============================================================
# Test isolation helpers
# ============================================================

# setup_temp_dir — creates an isolated git repo in a temp dir and exports
# TEST_GIT_DIR so the classifier's _is_merge_commit reads from it rather
# than the real worktree's git state.  Without this, tests fail when run
# during a merge operation because MERGE_HEAD leaks from the real repo.
setup_temp_dir() {
    TEST_TMPDIR="$(mktemp -d)"
    git -C "$TEST_TMPDIR" init -q -b main 2>/dev/null
    git -C "$TEST_TMPDIR" config user.email "test@test" 2>/dev/null
    git -C "$TEST_TMPDIR" config user.name "test" 2>/dev/null
    git -C "$TEST_TMPDIR" config core.hooksPath /dev/null 2>/dev/null
    touch "$TEST_TMPDIR/.gitkeep"
    git -C "$TEST_TMPDIR" add -A 2>/dev/null
    git -C "$TEST_TMPDIR" commit -q -m "init" 2>/dev/null
    export TEST_GIT_DIR="$TEST_TMPDIR/.git"
}

teardown_temp_dir() {
    [[ -n "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
}

# Create a temp git dir with a fake MERGE_HEAD file for merge-state isolation.
# Returns the .git dir path on stdout.
make_merge_head_git_dir() {
    local tmpdir
    tmpdir="$(mktemp -d)"
    git -C "$tmpdir" init -q -b main 2>/dev/null
    git -C "$tmpdir" config user.email "test@test" 2>/dev/null
    git -C "$tmpdir" config user.name "test" 2>/dev/null
    git -C "$tmpdir" config core.hooksPath /dev/null 2>/dev/null
    touch "$tmpdir/.gitkeep"
    git -C "$tmpdir" add -A 2>/dev/null
    git -C "$tmpdir" commit -q -m "init" 2>/dev/null
    # Write a fake MERGE_HEAD that does NOT equal HEAD (to pass the MERGE_HEAD==HEAD guard)
    echo "0000000000000000000000000000000000000001" > "$tmpdir/.git/MERGE_HEAD"
    echo "$tmpdir/.git"
}

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
#   SIZE_ACTION       — size_action from classifier (none/upgrade/warn)
#   SIZE_WARNING_MSG  — Human-readable warning message (when SIZE_ACTION=warn; empty otherwise)
# ============================================================
_simulate_step3_dispatch() {
    local classifier_json="${CLASSIFIER_JSON:-}"
    local review_pass_num="${REVIEW_PASS_NUM:-1}"

    # Reset output variables
    REVIEW_AGENT=""
    REVIEW_TIER=""
    SIZE_ACTION="none"
    SIZE_REJECTION="0"
    SIZE_WARNING_MSG=""

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
    # - size_action=warn: emit SIZE_WARNING_MSG and continue (does not reject)
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
        warn)
            # Warn about large diff — does NOT reject, does NOT set SIZE_REJECTION=1
            SIZE_WARNING_MSG="WARNING: Diff is large (>=600 lines). Review quality may be reduced. Consider splitting your changes. See: large-diff-splitting-guide.md"
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
    # Regression guard: verify REVIEW-WORKFLOW.md Step 3b no longer contains reject logic.
    # The reject path was removed in favor of warn (epic 97fc-b2ca).
    step3_has_reject_logic=0
    grep -qE '"reject"|size_action.*reject|SIZE_REJECTION' "$WORKFLOW_FILE" 2>/dev/null && step3_has_reject_logic=1
    assert_eq "test_workflow_step3_reject_when_size_action_is_reject: REVIEW-WORKFLOW.md Step 3b has no reject logic (removed in 97fc-b2ca)" \
        "0" "$step3_has_reject_logic"
}

test_workflow_step3_warn_when_size_action_is_warn() {
    # Given classifier JSON with size_action: "warn", assert the workflow does NOT reject
    # the review (SIZE_REJECTION=0) and continues dispatching the tier-selected agent.
    _snapshot_fail
    CLASSIFIER_JSON='{"selected_tier":"standard","size_action":"warn","is_merge_commit":false,"blast_radius":2,"computed_total":4}'
    REVIEW_PASS_NUM=1
    _simulate_step3_dispatch
    assert_eq "test_workflow_step3_warn_when_size_action_is_warn: SIZE_REJECTION is 0 (warn does not reject)" \
        "0" "$SIZE_REJECTION"
    assert_ne "test_workflow_step3_warn_when_size_action_is_warn: REVIEW_AGENT is not empty (review proceeds)" \
        "" "$REVIEW_AGENT"
    assert_pass_if_clean "test_workflow_step3_warn_when_size_action_is_warn: helper logic"

    # RED check: verify REVIEW-WORKFLOW.md Step 3b contains warn logic (fails until implemented)
    _snapshot_fail
    step3_has_warn_logic=0
    grep -qE 'SIZE_ACTION.*warn|size_action.*warn|warn.*size' "$WORKFLOW_FILE" 2>/dev/null && step3_has_warn_logic=1
    assert_eq "test_workflow_step3_warn_when_size_action_is_warn: REVIEW-WORKFLOW.md Step 3b contains SIZE_ACTION.*warn (RED until implemented)" \
        "1" "$step3_has_warn_logic"
    assert_pass_if_clean "test_workflow_step3_warn_when_size_action_is_warn"
}

test_workflow_step3_no_size_limit_on_repass() {
    # Given REVIEW_PASS_NUM=2 (re-review pass), assert size limits are bypassed even
    # when classifier returns size_action: "warn".
    _snapshot_fail
    CLASSIFIER_JSON='{"selected_tier":"standard","size_action":"warn","is_merge_commit":false,"blast_radius":2,"computed_total":4}'
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
    CLASSIFIER_JSON='{"selected_tier":"light","size_action":"warn","is_merge_commit":true,"blast_radius":0,"computed_total":0}'
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
# Integration test helpers
# ============================================================

# _generate_diff_lines(n, file_path)
# Generates a minimal unified diff with exactly n added lines in a non-test source file.
_generate_diff_lines() {
    local n="$1"
    local file_path="${2:-src/feature.py}"
    printf 'diff --git a/%s b/%s\nnew file mode 100644\nindex 0000000..abc1234\n--- /dev/null\n+++ b/%s\n@@ -0,0 +1,%d @@\n' \
        "$file_path" "$file_path" "$file_path" "$n"
    local i
    for (( i=0; i<n; i++ )); do
        printf '+# line %d\n' "$i"
    done
}

# _simulate_step3b_from_classifier_json(classifier_json, review_pass_num)
# Implements Step 3b shell branching logic from REVIEW-WORKFLOW.md using the classifier JSON.
#
# Outputs (environment variables):
#   REVIEW_AGENT_OVERRIDE — set to opus agent when size_action=upgrade (non-merge, pass 1)
#   STEP3B_REVIEW_RESULT  — set to "warned" when size_action=warn (non-merge, pass 1); empty otherwise
#   STEP3B_REJECTION_MSG  — human-readable SIZE_WARNING message when STEP3B_REVIEW_RESULT=warned
_simulate_step3b_from_classifier_json() {
    local classifier_json="$1"
    local review_pass_num="${2:-1}"

    # Reset outputs
    REVIEW_AGENT_OVERRIDE=""
    STEP3B_REVIEW_RESULT=""
    STEP3B_REJECTION_MSG=""

    local size_action is_merge diff_size_lines
    size_action=$(echo "$classifier_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("size_action","none"))' 2>/dev/null || echo "none")
    is_merge=$(echo "$classifier_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(str(d.get("is_merge_commit",False)).lower())' 2>/dev/null || echo "false")
    diff_size_lines=$(echo "$classifier_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("diff_size_lines",0))' 2>/dev/null || echo "0")

    # Merge commits and re-review passes bypass size limits
    if [[ "$is_merge" != "true" ]] && [[ "$review_pass_num" -le 1 ]]; then
        if [[ "$size_action" == "upgrade" ]]; then
            REVIEW_AGENT_OVERRIDE="dso:code-reviewer-deep-arch"
        fi
        if [[ "$size_action" == "warn" ]]; then
            STEP3B_REVIEW_RESULT="warned"
            STEP3B_REJECTION_MSG="SIZE_WARNING: diff has ${diff_size_lines} scorable lines (>=600 threshold).
Large diffs may reduce review quality.
Consider splitting your changes.
Guidance: plugins/dso/docs/workflows/prompts/large-diff-splitting-guide.md"
        fi
    fi

    return 0
}

# ============================================================
# Integration test functions
# ============================================================

test_integration_merge_commit_bypass_end_to_end() {
    # End-to-end: pipe a 600-line diff with MOCK_MERGE_HEAD=1 through the classifier,
    # verify is_merge_commit=true in classifier output, and confirm Step 3b logic
    # does NOT set STEP3B_REVIEW_RESULT to rejected.
    _snapshot_fail

    local diff_input classifier_json is_merge_actual size_action_actual merge_git_dir
    diff_input=$(_generate_diff_lines 600)
    merge_git_dir=$(make_merge_head_git_dir)
    classifier_json=$(echo "$diff_input" | env _MERGE_STATE_GIT_DIR="$merge_git_dir" REPO_ROOT="$REPO_ROOT" "$REPO_ROOT/plugins/dso/scripts/review-complexity-classifier.sh")
    rm -rf "$(dirname "$merge_git_dir")" 2>/dev/null || true

    # Verify classifier produced valid JSON with is_merge_commit=true
    is_merge_actual=$(echo "$classifier_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(str(d.get("is_merge_commit",False)).lower())' 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "test_integration_merge_commit_bypass_end_to_end: classifier returns is_merge_commit=true with MOCK_MERGE_HEAD=1" \
        "true" "$is_merge_actual"

    # Verify size_action is none (merge bypass applied at classifier level)
    size_action_actual=$(echo "$classifier_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("size_action","MISSING"))' 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "test_integration_merge_commit_bypass_end_to_end: classifier returns size_action=none for merge commit (bypass at classifier)" \
        "none" "$size_action_actual"

    # Run Step 3b branching logic — merge commit must not be rejected
    _simulate_step3b_from_classifier_json "$classifier_json" 1
    assert_eq "test_integration_merge_commit_bypass_end_to_end: STEP3B_REVIEW_RESULT is not rejected for merge commit" \
        "" "$STEP3B_REVIEW_RESULT"
    assert_eq "test_integration_merge_commit_bypass_end_to_end: REVIEW_AGENT_OVERRIDE not set for merge commit" \
        "" "$REVIEW_AGENT_OVERRIDE"

    assert_pass_if_clean "test_integration_merge_commit_bypass_end_to_end"
}

test_integration_upgrade_path_end_to_end() {
    # End-to-end: pipe a 300-line non-test diff through the classifier,
    # capture size_action, then run Step 3b logic and assert REVIEW_AGENT_OVERRIDE
    # is set to the opus agent.
    _snapshot_fail

    local diff_input classifier_json size_action_actual
    diff_input=$(_generate_diff_lines 300)
    classifier_json=$(echo "$diff_input" | env _MERGE_STATE_GIT_DIR="${TEST_GIT_DIR:-}" REPO_ROOT="$REPO_ROOT" "$REPO_ROOT/plugins/dso/scripts/review-complexity-classifier.sh")

    # Verify classifier produced valid JSON with size_action=upgrade
    size_action_actual=$(echo "$classifier_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("size_action","MISSING"))' 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "test_integration_upgrade_path_end_to_end: classifier returns size_action=upgrade for 300-line diff" \
        "upgrade" "$size_action_actual"

    # Run Step 3b branching logic
    _simulate_step3b_from_classifier_json "$classifier_json" 1
    assert_eq "test_integration_upgrade_path_end_to_end: REVIEW_AGENT_OVERRIDE is set to opus agent" \
        "dso:code-reviewer-deep-arch" "$REVIEW_AGENT_OVERRIDE"
    assert_eq "test_integration_upgrade_path_end_to_end: STEP3B_REVIEW_RESULT is not rejected (upgrade path)" \
        "" "$STEP3B_REVIEW_RESULT"

    assert_pass_if_clean "test_integration_upgrade_path_end_to_end"
}

test_integration_reject_path_end_to_end() {
    # Regression guard: classifier must NOT emit size_action=reject for any diff size.
    # The reject path was removed in favor of warn (epic 97fc-b2ca).
    local diff_input classifier_json size_action_actual
    diff_input=$(_generate_diff_lines 600)
    classifier_json=$(echo "$diff_input" | env _MERGE_STATE_GIT_DIR="${TEST_GIT_DIR:-}" REPO_ROOT="$REPO_ROOT" "$REPO_ROOT/plugins/dso/scripts/review-complexity-classifier.sh")

    size_action_actual=$(echo "$classifier_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("size_action","MISSING"))' 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "test_integration_reject_path_end_to_end: classifier no longer returns size_action=reject for 600-line diff (removed in 97fc-b2ca)" \
        "warn" "$size_action_actual"

    assert_pass_if_clean "test_integration_reject_path_end_to_end"
}

test_integration_warn_path_end_to_end() {
    # End-to-end: pipe a 600-line diff through the classifier (when classifier emits warn),
    # run Step 3b logic, assert review is NOT rejected (SIZE_REJECTION=0) and proceeds.
    # RED: classifier still emits "reject" at 600 lines — this test fails until source change.
    _snapshot_fail

    local diff_input classifier_json size_action_actual
    diff_input=$(_generate_diff_lines 600)
    classifier_json=$(echo "$diff_input" | env _MERGE_STATE_GIT_DIR="${TEST_GIT_DIR:-}" REPO_ROOT="$REPO_ROOT" "$REPO_ROOT/plugins/dso/scripts/review-complexity-classifier.sh")

    # Verify classifier produced valid JSON with size_action=warn (RED until source change)
    size_action_actual=$(echo "$classifier_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d.get("size_action","MISSING"))' 2>/dev/null || echo "PARSE_ERROR")
    assert_eq "test_integration_warn_path_end_to_end: classifier returns size_action=warn for 600-line diff" \
        "warn" "$size_action_actual"

    # Run Step 3b branching logic — warn sets STEP3B_REVIEW_RESULT to "warned" (not "rejected")
    _simulate_step3b_from_classifier_json "$classifier_json" 1
    assert_eq "test_integration_warn_path_end_to_end: STEP3B_REVIEW_RESULT is warned (not rejected)" \
        "warned" "$STEP3B_REVIEW_RESULT"
    assert_eq "test_integration_warn_path_end_to_end: SIZE_REJECTION is 0 (warn does not exit-1)" \
        "0" "${SIZE_REJECTION:-0}"

    assert_pass_if_clean "test_integration_warn_path_end_to_end"
}

# ============================================================
# Run all tests
# ============================================================
test_workflow_step3_upgrade_when_size_action_is_upgrade
echo ""
test_workflow_step3_reject_when_size_action_is_reject
echo ""
test_workflow_step3_warn_when_size_action_is_warn
echo ""
test_workflow_step3_no_size_limit_on_repass
echo ""
test_workflow_step3_merge_commit_bypass
echo ""
test_workflow_step3_no_change_when_size_action_none
echo ""
setup_temp_dir
test_integration_merge_commit_bypass_end_to_end
echo ""
test_integration_upgrade_path_end_to_end
echo ""
test_integration_reject_path_end_to_end
echo ""
test_integration_warn_path_end_to_end
echo ""
teardown_temp_dir
print_summary
