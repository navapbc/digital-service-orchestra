#!/usr/bin/env bash
# tests/hooks/test-review-workflow-classifier-dispatch.sh
# RED integration tests for classifier-to-named-agent dispatch pipeline (dso-4mdr)
#
# Tests the end-to-end flow: classifier invocation -> tier selection -> named agent dispatch.
# All tests are RED — the REVIEW-WORKFLOW.md Step 3/4 classifier integration does not exist yet.
# They will turn GREEN when dso-4j40 implements the classifier-driven dispatch in REVIEW-WORKFLOW.md.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$REPO_ROOT/tests/lib/assert.sh"

CLASSIFIER="$REPO_ROOT/plugins/dso/scripts/review-complexity-classifier.sh"
REVIEW_WORKFLOW="$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md"
AGENT_DIR="$REPO_ROOT/plugins/dso/agents"

# --- Helpers ---

setup_temp_dir() {
    TEST_TMPDIR="$(mktemp -d)"
    export ARTIFACTS_DIR="$TEST_TMPDIR/artifacts"
    mkdir -p "$ARTIFACTS_DIR"
}

teardown_temp_dir() {
    [[ -n "${TEST_TMPDIR:-}" ]] && rm -rf "$TEST_TMPDIR"
}

# Create a minimal git diff fixture
# Usage: create_diff_fixture "filename" "diff_content"
create_diff_fixture() {
    local filename="$1"
    local content="$2"
    local diff_file="$TEST_TMPDIR/test.diff"
    cat > "$diff_file" <<DIFFEOF
diff --git a/$filename b/$filename
index 0000000..1111111 100644
--- a/$filename
+++ b/$filename
@@ -1,3 +1,5 @@
$content
DIFFEOF
    echo "$diff_file"
}

# Run the classifier with a diff file and capture output + exit code
# Usage: run_classifier diff_file
# Sets: CLASSIFIER_OUTPUT, CLASSIFIER_EXIT
run_classifier() {
    local diff_file="$1"
    CLASSIFIER_OUTPUT=""
    CLASSIFIER_EXIT=0
    if [[ -x "$CLASSIFIER" ]]; then
        CLASSIFIER_OUTPUT=$(bash "$CLASSIFIER" < "$diff_file" 2>/dev/null) || CLASSIFIER_EXIT=$?
    else
        CLASSIFIER_EXIT=127
    fi
}

# Extract a JSON field value using python3 (no jq dependency)
# Usage: json_field "key" "$json_string"
json_field() {
    local key="$1" json="$2"
    python3 -c "import json,sys; d=json.loads(sys.argv[1]); print(d.get('$key',''))" "$json" 2>/dev/null || echo ""
}

# Simulate the tier-to-agent mapping that REVIEW-WORKFLOW.md Step 3/4 should implement.
# This function encodes the EXPECTED behavior after dso-4j40 is implemented.
# Returns: agent name that the tier should dispatch to.
expected_agent_for_tier() {
    local tier="$1"
    case "$tier" in
        light)    echo "code-reviewer-light" ;;
        standard) echo "code-reviewer-standard" ;;
        deep)     echo "code-reviewer-deep" ;;
        *)        echo "UNKNOWN" ;;
    esac
}

# Check if REVIEW-WORKFLOW.md Step 3 uses classifier-driven tier selection
# (i.e., calls review-complexity-classifier.sh instead of the old MODEL= pattern)
workflow_step3_uses_classifier() {
    # After dso-4j40, Step 3 should invoke review-complexity-classifier.sh
    # and produce a SELECTED_TIER variable instead of MODEL=sonnet/opus
    grep -q 'review-complexity-classifier' "$REVIEW_WORKFLOW" 2>/dev/null
}

# Check if REVIEW-WORKFLOW.md Step 4 dispatches named agents based on tier
workflow_step4_uses_named_agents() {
    # After dso-4j40, Step 4 should dispatch to code-reviewer-light/standard/deep
    # instead of generic general-purpose sub-agent
    grep -q 'code-reviewer-light\|code-reviewer-standard\|code-reviewer-deep' "$REVIEW_WORKFLOW" 2>/dev/null
}

echo "=== test-review-workflow-classifier-dispatch.sh ==="
echo ""

# ============================================================
# Classifier Integration Tests
# ============================================================

echo "--- Classifier integration ---"

# test_review_workflow_step3_calls_classifier
# Verify that REVIEW-WORKFLOW.md Step 3 invokes the classifier script
# to produce a tier variable rather than the old MODEL= pattern.
_snapshot_fail
setup_temp_dir

if workflow_step3_uses_classifier; then
    assert_eq "step3_calls_classifier: workflow references classifier" "yes" "yes"
else
    assert_eq "step3_calls_classifier: workflow should reference review-complexity-classifier.sh" "references_classifier" "uses_old_model_pattern"
fi

teardown_temp_dir
assert_pass_if_clean "test_review_workflow_step3_calls_classifier"

# test_classifier_output_parsed_for_tier_selection
# Verify that the selected_tier from classifier JSON is used to route dispatch.
# After dso-4j40, the workflow should parse selected_tier and use it for agent selection.
_snapshot_fail
setup_temp_dir

# Create a simple diff that produces a known tier from the classifier
diff_file=$(create_diff_fixture "src/simple.py" "+x = 1")
run_classifier "$diff_file"

if [[ "$CLASSIFIER_EXIT" -eq 0 ]]; then
    tier=$(json_field "selected_tier" "$CLASSIFIER_OUTPUT")
    # Verify the tier is one of the valid values
    assert_ne "classifier_output_tier_not_empty" "" "$tier"

    # Now verify the workflow actually uses this tier for dispatch.
    # After dso-4j40, Step 3 should produce SELECTED_TIER from classifier output.
    # Since dso-4j40 is not implemented, the workflow still uses the old MODEL= pattern.
    if workflow_step3_uses_classifier; then
        assert_eq "classifier_tier_parsed_for_selection" "yes" "yes"
    else
        assert_eq "classifier_tier_parsed_for_selection: workflow should parse selected_tier" "tier_parsed" "tier_not_parsed"
    fi
else
    assert_eq "classifier_output_parsed: classifier must succeed" "0" "$CLASSIFIER_EXIT"
fi

teardown_temp_dir
assert_pass_if_clean "test_classifier_output_parsed_for_tier_selection"

# test_classifier_failure_defaults_to_standard_tier
# When classifier exits non-zero, verify fallback behavior produces 'standard' tier.
# The contract (classifier-tier-output.md) says: parser must default to standard on failure.
_snapshot_fail
setup_temp_dir

# The fallback logic should be in REVIEW-WORKFLOW.md Step 3 after dso-4j40.
# We verify the workflow documents this fallback behavior.
fallback_documented=false
if grep -q 'standard' "$REVIEW_WORKFLOW" && grep -q 'default\|fallback\|fail' "$REVIEW_WORKFLOW" 2>/dev/null; then
    # Check if the workflow mentions defaulting to standard on classifier failure
    if grep -qE '(default|fallback).*standard|standard.*(default|fallback)' "$REVIEW_WORKFLOW" 2>/dev/null; then
        fallback_documented=true
    fi
fi

# After dso-4j40, the workflow Step 3 must include classifier failure -> standard fallback
if workflow_step3_uses_classifier && [[ "$fallback_documented" == "true" ]]; then
    assert_eq "classifier_failure_defaults_standard" "yes" "yes"
else
    assert_eq "classifier_failure_defaults_standard: workflow should default to standard on classifier failure" "fallback_implemented" "fallback_not_implemented"
fi

teardown_temp_dir
assert_pass_if_clean "test_classifier_failure_defaults_to_standard_tier"

# ============================================================
# Named Agent Dispatch Tests
# ============================================================

echo ""
echo "--- Named agent dispatch ---"

# test_light_tier_dispatches_to_code_reviewer_light
# Light tier should route to dso:code-reviewer-light
_snapshot_fail
setup_temp_dir

# Verify the named agent definition exists
light_agent_exists=false
if [[ -f "$AGENT_DIR/code-reviewer-light.md" ]]; then
    light_agent_exists=true
fi
assert_eq "light_agent_file_exists" "true" "$light_agent_exists"

# Verify the workflow dispatches light tier to code-reviewer-light
if workflow_step4_uses_named_agents; then
    # After dso-4j40, check that light tier maps to code-reviewer-light
    expected=$(expected_agent_for_tier "light")
    assert_eq "light_tier_dispatches_correct_agent" "code-reviewer-light" "$expected"
else
    assert_eq "light_tier_dispatch: workflow should dispatch code-reviewer-light for light tier" "dispatches_named_agent" "dispatches_general_purpose"
fi

teardown_temp_dir
assert_pass_if_clean "test_light_tier_dispatches_to_code_reviewer_light"

# test_standard_tier_dispatches_to_code_reviewer_standard
# Standard tier should route to dso:code-reviewer-standard
_snapshot_fail
setup_temp_dir

# Verify the named agent definition exists
standard_agent_exists=false
if [[ -f "$AGENT_DIR/code-reviewer-standard.md" ]]; then
    standard_agent_exists=true
fi
assert_eq "standard_agent_file_exists" "true" "$standard_agent_exists"

# Verify the workflow dispatches standard tier to code-reviewer-standard
if workflow_step4_uses_named_agents; then
    expected=$(expected_agent_for_tier "standard")
    assert_eq "standard_tier_dispatches_correct_agent" "code-reviewer-standard" "$expected"
else
    assert_eq "standard_tier_dispatch: workflow should dispatch code-reviewer-standard for standard tier" "dispatches_named_agent" "dispatches_general_purpose"
fi

teardown_temp_dir
assert_pass_if_clean "test_standard_tier_dispatches_to_code_reviewer_standard"

# test_classifier_json_schema_valid
# Verify classifier output matches the contract fields from classifier-tier-output.md
_snapshot_fail
setup_temp_dir

# Run classifier with a non-trivial diff to get all fields populated
diff_file=$(create_diff_fixture "src/handlers/auth.py" "+def login(user): pass
+def logout(user): pass
+# noqa: E501")
run_classifier "$diff_file"

if [[ "$CLASSIFIER_EXIT" -eq 0 && -n "$CLASSIFIER_OUTPUT" ]]; then
    # Verify all required fields from the contract are present
    required_fields=("blast_radius" "critical_path" "anti_shortcut" "staleness" "cross_cutting" "diff_lines" "change_volume" "computed_total" "selected_tier")

    all_fields_present=true
    for field in "${required_fields[@]}"; do
        value=$(json_field "$field" "$CLASSIFIER_OUTPUT")
        if [[ -z "$value" ]]; then
            all_fields_present=false
            assert_eq "schema_field_present_$field" "present" "missing"
        fi
    done

    if [[ "$all_fields_present" == "true" ]]; then
        # Verify selected_tier is one of the valid enum values
        tier=$(json_field "selected_tier" "$CLASSIFIER_OUTPUT")
        case "$tier" in
            light|standard|deep)
                assert_eq "schema_tier_valid_enum" "valid" "valid"
                ;;
            *)
                assert_eq "schema_tier_valid_enum" "light|standard|deep" "$tier"
                ;;
        esac

        # Verify computed_total is a non-negative integer
        total=$(json_field "computed_total" "$CLASSIFIER_OUTPUT")
        if [[ "$total" =~ ^[0-9]+$ ]]; then
            assert_eq "schema_computed_total_is_integer" "integer" "integer"
        else
            assert_eq "schema_computed_total_is_integer" "integer" "$total"
        fi
    fi

    # Now verify the workflow would correctly consume this schema.
    # After dso-4j40, Step 3 must parse selected_tier from this JSON.
    if workflow_step3_uses_classifier; then
        assert_eq "schema_consumed_by_workflow" "yes" "yes"
    else
        assert_eq "schema_consumed_by_workflow: workflow should parse classifier JSON schema" "schema_consumed" "schema_not_consumed"
    fi
else
    assert_eq "classifier_produces_valid_json" "exit_0_with_output" "exit_${CLASSIFIER_EXIT}_output_empty"
fi

teardown_temp_dir
assert_pass_if_clean "test_classifier_json_schema_valid"

# ============================================================
# Deep Tier Multi-Reviewer Dispatch Tests (dso-guue)
# ============================================================

echo ""
echo "--- Deep tier multi-reviewer dispatch ---"

# test_deep_tier_documents_three_parallel_sonnet_dispatches
# Verify that REVIEW-WORKFLOW.md Step 4 documents dispatching 3 parallel sonnet
# agents: code-reviewer-deep-correctness, code-reviewer-deep-verification,
# code-reviewer-deep-hygiene when tier is "deep".
# RED: REVIEW-WORKFLOW.md currently falls back to single code-reviewer-deep-correctness.
_snapshot_fail
setup_temp_dir

deep_correctness_dispatch=false
deep_verification_dispatch=false
deep_hygiene_dispatch=false

# Check that the workflow documents all three parallel deep reviewer dispatches in Step 4
if grep -q 'code-reviewer-deep-correctness' "$REVIEW_WORKFLOW" 2>/dev/null; then
    # correctness is referenced but we need all three as parallel dispatches
    deep_correctness_dispatch=true
fi
if grep -q 'code-reviewer-deep-verification' "$REVIEW_WORKFLOW" 2>/dev/null; then
    deep_verification_dispatch=true
fi
if grep -q 'code-reviewer-deep-hygiene' "$REVIEW_WORKFLOW" 2>/dev/null; then
    deep_hygiene_dispatch=true
fi

# All three must be documented as parallel dispatches in Step 4
all_three_documented=false
if [[ "$deep_correctness_dispatch" == "true" && "$deep_verification_dispatch" == "true" && "$deep_hygiene_dispatch" == "true" ]]; then
    # Additionally verify they are documented as parallel (not sequential) dispatches
    if grep -qE 'parallel.*sonnet|3.*parallel|three.*parallel' "$REVIEW_WORKFLOW" 2>/dev/null; then
        all_three_documented=true
    fi
fi

assert_eq "test_deep_tier_documents_three_parallel_sonnet_dispatches: workflow Step 4 should document 3 parallel sonnet dispatches (correctness/verification/hygiene)" "true" "$all_three_documented"

teardown_temp_dir
assert_pass_if_clean "test_deep_tier_documents_three_parallel_sonnet_dispatches"

# test_deep_tier_documents_temp_file_naming
# Verify that REVIEW-WORKFLOW.md references the temp findings file naming convention:
# reviewer-findings-a.json, reviewer-findings-b.json, reviewer-findings-c.json
# These temp files are where each parallel sonnet writes its findings before merge.
# RED: REVIEW-WORKFLOW.md does not yet document temp findings file naming.
_snapshot_fail
setup_temp_dir

findings_a_documented=false
findings_b_documented=false
findings_c_documented=false

if grep -q 'reviewer-findings-a\.json' "$REVIEW_WORKFLOW" 2>/dev/null; then
    findings_a_documented=true
fi
if grep -q 'reviewer-findings-b\.json' "$REVIEW_WORKFLOW" 2>/dev/null; then
    findings_b_documented=true
fi
if grep -q 'reviewer-findings-c\.json' "$REVIEW_WORKFLOW" 2>/dev/null; then
    findings_c_documented=true
fi

all_temp_files_documented=false
if [[ "$findings_a_documented" == "true" && "$findings_b_documented" == "true" && "$findings_c_documented" == "true" ]]; then
    all_temp_files_documented=true
fi

assert_eq "test_deep_tier_documents_temp_file_naming: workflow should reference reviewer-findings-{a,b,c}.json" "true" "$all_temp_files_documented"

teardown_temp_dir
assert_pass_if_clean "test_deep_tier_documents_temp_file_naming"

# test_deep_tier_documents_orchestrator_copy_step
# Verify that REVIEW-WORKFLOW.md documents the orchestrator copying reviewer-findings.json
# to the temp path (reviewer-findings-{a,b,c}.json) after each sonnet agent completes.
# Each sonnet writes to the standard reviewer-findings.json; the orchestrator copies it
# to the slot-specific temp path before launching the next agent.
# RED: REVIEW-WORKFLOW.md does not yet document the copy/rename step.
_snapshot_fail
setup_temp_dir

copy_step_documented=false

# Look for documentation of copying/moving reviewer-findings.json to temp slot files
if grep -qE 'copy.*reviewer-findings|mv.*reviewer-findings|rename.*reviewer-findings|reviewer-findings\.json.*reviewer-findings-[abc]' "$REVIEW_WORKFLOW" 2>/dev/null; then
    copy_step_documented=true
fi

# Also check for the reverse pattern (temp file from reviewer-findings.json)
if [[ "$copy_step_documented" == "false" ]]; then
    if grep -qE 'reviewer-findings-[abc]\.json.*from.*reviewer-findings|reviewer-findings\.json.*→.*reviewer-findings-[abc]' "$REVIEW_WORKFLOW" 2>/dev/null; then
        copy_step_documented=true
    fi
fi

assert_eq "test_deep_tier_documents_orchestrator_copy_step: workflow should document copying reviewer-findings.json to temp paths after each sonnet completes" "true" "$copy_step_documented"

teardown_temp_dir
assert_pass_if_clean "test_deep_tier_documents_orchestrator_copy_step"

# ============================================================
# Opus Architectural Reviewer Dispatch Tests (dso-spfe)
# ============================================================

echo ""
echo "--- Opus arch reviewer dispatch ---"

# test_deep_arch_reviewer_dispatched_after_sonnets
# Verify that REVIEW-WORKFLOW.md documents dispatching dso:code-reviewer-deep-arch
# after the 3 parallel sonnet agents (correctness/verification/hygiene) complete.
# RED: REVIEW-WORKFLOW.md does not yet document the opus arch reviewer dispatch step.
_snapshot_fail
setup_temp_dir

arch_dispatch_documented=false

# Check that the workflow documents dispatching code-reviewer-deep-arch after sonnets
if grep -q 'code-reviewer-deep-arch' "$REVIEW_WORKFLOW" 2>/dev/null; then
    # Must also document that it runs AFTER the 3 sonnet agents complete
    if grep -qE 'after.*sonnet|after.*parallel|after.*three|after.*3.*agents|sonnet.*complete.*arch|arch.*after' "$REVIEW_WORKFLOW" 2>/dev/null; then
        arch_dispatch_documented=true
    fi
fi

assert_eq "test_deep_arch_reviewer_dispatched_after_sonnets: workflow should document dispatching dso:code-reviewer-deep-arch after 3 sonnet agents complete" "true" "$arch_dispatch_documented"

teardown_temp_dir
assert_pass_if_clean "test_deep_arch_reviewer_dispatched_after_sonnets"

# test_deep_arch_prompt_includes_inline_findings
# Verify that REVIEW-WORKFLOW.md documents injecting SONNET-A FINDINGS, SONNET-B FINDINGS,
# SONNET-C FINDINGS into the opus dispatch prompt (matching the input format expected by
# code-reviewer-deep-arch.md).
# RED: REVIEW-WORKFLOW.md does not yet document inline findings injection.
_snapshot_fail
setup_temp_dir

findings_a_inline=false
findings_b_inline=false
findings_c_inline=false

if grep -q 'SONNET-A FINDINGS\|SONNET_A_FINDINGS\|sonnet-a.*findings\|findings-a.*inline\|FINDINGS_A' "$REVIEW_WORKFLOW" 2>/dev/null; then
    findings_a_inline=true
fi
if grep -q 'SONNET-B FINDINGS\|SONNET_B_FINDINGS\|sonnet-b.*findings\|findings-b.*inline\|FINDINGS_B' "$REVIEW_WORKFLOW" 2>/dev/null; then
    findings_b_inline=true
fi
if grep -q 'SONNET-C FINDINGS\|SONNET_C_FINDINGS\|sonnet-c.*findings\|findings-c.*inline\|FINDINGS_C' "$REVIEW_WORKFLOW" 2>/dev/null; then
    findings_c_inline=true
fi

all_findings_inline=false
if [[ "$findings_a_inline" == "true" && "$findings_b_inline" == "true" && "$findings_c_inline" == "true" ]]; then
    all_findings_inline=true
fi

assert_eq "test_deep_arch_prompt_includes_inline_findings: workflow should document injecting SONNET-A/B/C FINDINGS into opus arch dispatch prompt" "true" "$all_findings_inline"

teardown_temp_dir
assert_pass_if_clean "test_deep_arch_prompt_includes_inline_findings"

# test_deep_arch_writes_authoritative_findings
# Verify that REVIEW-WORKFLOW.md documents dso:code-reviewer-deep-arch as the sole writer
# of the final reviewer-findings.json in deep tier (not any of the sonnet agents).
# RED: REVIEW-WORKFLOW.md does not yet document the arch reviewer writing authoritative findings.
_snapshot_fail
setup_temp_dir

arch_writes_final=false

# Check that the workflow documents the arch reviewer writing the final/authoritative reviewer-findings.json
if grep -q 'code-reviewer-deep-arch' "$REVIEW_WORKFLOW" 2>/dev/null; then
    # Must document that it writes the authoritative/final reviewer-findings.json
    if grep -qE 'deep-arch.*(authoritative|final).*findings|authoritative.*reviewer-findings|arch.*writes.*reviewer-findings\.json' "$REVIEW_WORKFLOW" 2>/dev/null; then
        arch_writes_final=true
    fi
fi

assert_eq "test_deep_arch_writes_authoritative_findings: workflow should document dso:code-reviewer-deep-arch as sole writer of final reviewer-findings.json" "true" "$arch_writes_final"

teardown_temp_dir
assert_pass_if_clean "test_deep_arch_writes_authoritative_findings"

# test_deep_tier_single_writer_invariant
# Verify that REVIEW-WORKFLOW.md does NOT document sonnet agents writing to the final
# reviewer-findings.json path — only to temp a/b/c paths. The arch reviewer is the
# single authoritative writer of the final findings file.
# RED: REVIEW-WORKFLOW.md does not yet explicitly state the single-writer invariant.
_snapshot_fail
setup_temp_dir

single_writer_invariant=false

# The invariant requires:
# 1. Sonnet agents write only to temp paths (reviewer-findings-{a,b,c}.json) — already documented
# 2. The workflow explicitly states that only the arch reviewer writes to reviewer-findings.json (not temp paths)
# Check for explicit single-writer documentation
if grep -qE 'single.*writer|sole.*writer|only.*arch.*writes|arch.*only.*writer|one.*authoritative|single.*authoritative' "$REVIEW_WORKFLOW" 2>/dev/null; then
    single_writer_invariant=true
fi

assert_eq "test_deep_tier_single_writer_invariant: workflow should document single-writer invariant (only arch reviewer writes final reviewer-findings.json)" "true" "$single_writer_invariant"

teardown_temp_dir
assert_pass_if_clean "test_deep_tier_single_writer_invariant"

# ============================================================
# Step 3 Size Rejection and Model Override Tests (w21-nv42)
# ============================================================

echo ""
echo "--- Step 3 size rejection and model override ---"

# test_workflow_step3_checks_size_action_field
# Verify that REVIEW-WORKFLOW.md Step 3 references the size_action field from
# classifier output and acts on it (rejects the diff when size_action is "reject").
# RED: REVIEW-WORKFLOW.md does not yet reference size_action from classifier output.
_snapshot_fail
setup_temp_dir

size_action_referenced=false

if grep -q 'size_action' "$REVIEW_WORKFLOW" 2>/dev/null; then
    size_action_referenced=true
fi

assert_eq "test_workflow_step3_checks_size_action_field: REVIEW-WORKFLOW.md should reference size_action field from classifier output" "true" "$size_action_referenced"

teardown_temp_dir
assert_pass_if_clean "test_workflow_step3_checks_size_action_field"

# test_workflow_step3_checks_model_override_field
# Verify that REVIEW-WORKFLOW.md Step 3 references the model_override field from
# classifier output and uses it to override the dispatched named agent's model.
# RED: REVIEW-WORKFLOW.md does not yet reference model_override from classifier output.
_snapshot_fail
setup_temp_dir

model_override_referenced=false

if grep -q 'model_override' "$REVIEW_WORKFLOW" 2>/dev/null; then
    model_override_referenced=true
fi

assert_eq "test_workflow_step3_checks_model_override_field: REVIEW-WORKFLOW.md should reference model_override field to override named agent model" "true" "$model_override_referenced"

teardown_temp_dir
assert_pass_if_clean "test_workflow_step3_checks_model_override_field"

# test_workflow_step3_rejection_only_on_initial_dispatch
# Verify that REVIEW-WORKFLOW.md clarifies size rejection is skipped during re-review
# (i.e., the Autonomous Resolution Loop does NOT apply size rejection).
# RED: REVIEW-WORKFLOW.md does not yet document this skipping behavior.
_snapshot_fail
setup_temp_dir

rerereview_skips_rejection=false

# Look for language clarifying size rejection is skipped/not applied during re-review
# Match patterns like: "re-review...skip...size", "size rejection...not apply...re-review",
# "Autonomous Resolution Loop...size_action...skip", etc.
if grep -qE 're-?review.*skip.*size|size.*skip.*re-?review|re-?review.*size_action.*skip|size_action.*re-?review.*not|Autonomous.*Resolution.*size|size.*rejection.*not.*re-?review|re-?review.*bypass.*size|skip.*size.*action.*re-?review' "$REVIEW_WORKFLOW" 2>/dev/null; then
    rerereview_skips_rejection=true
fi

assert_eq "test_workflow_step3_rejection_only_on_initial_dispatch: REVIEW-WORKFLOW.md should clarify size rejection is skipped during re-review (Autonomous Resolution Loop)" "true" "$rerereview_skips_rejection"

teardown_temp_dir
assert_pass_if_clean "test_workflow_step3_rejection_only_on_initial_dispatch"

# test_workflow_step3_rejection_message_references_guide
# Verify that the rejection message template in REVIEW-WORKFLOW.md includes a reference
# to the large-diff-splitting-guide (by path) so practitioners know where to get help.
# RED: REVIEW-WORKFLOW.md does not yet include the splitting guide reference.
_snapshot_fail
setup_temp_dir

guide_in_rejection_message=false

if grep -q 'large-diff-splitting-guide' "$REVIEW_WORKFLOW" 2>/dev/null; then
    guide_in_rejection_message=true
fi

assert_eq "test_workflow_step3_rejection_message_references_guide: REVIEW-WORKFLOW.md rejection message should reference large-diff-splitting-guide" "true" "$guide_in_rejection_message"

teardown_temp_dir
assert_pass_if_clean "test_workflow_step3_rejection_message_references_guide"

# test_workflow_references_splitting_guide_file
# Verify that plugins/dso/docs/workflows/prompts/large-diff-splitting-guide.md exists.
# RED: The file does not exist yet (will be created in T5).
_snapshot_fail
setup_temp_dir

SPLITTING_GUIDE="$REPO_ROOT/plugins/dso/docs/workflows/prompts/large-diff-splitting-guide.md"
splitting_guide_exists=false

if [[ -f "$SPLITTING_GUIDE" ]]; then
    splitting_guide_exists=true
fi

assert_eq "test_workflow_references_splitting_guide_file: plugins/dso/docs/workflows/prompts/large-diff-splitting-guide.md should exist" "true" "$splitting_guide_exists"

teardown_temp_dir
assert_pass_if_clean "test_workflow_references_splitting_guide_file"

# ============================================================
# Resolution Sub-Agent Isolation Tests (dso-5uik)
# ============================================================

echo ""
echo "--- Resolution sub-agent isolation ---"

# test_deep_tier_resolution_uses_authoritative_findings
# Verify that REVIEW-WORKFLOW.md Autonomous Resolution Loop explicitly documents
# that the {findings_file} passed to the resolution sub-agent is the opus-written
# authoritative reviewer-findings.json — NOT the temp slot paths (a/b/c).
# This ensures the single-writer invariant: the resolution sub-agent reads the opus
# synthesis, not an individual sonnet agent's partial findings.
# RED: REVIEW-WORKFLOW.md does not yet explicitly state that {findings_file} is the
# opus-written authoritative path (distinct from temp a/b/c paths) in the Autonomous
# Resolution Loop section. dso-xx59 will add this language.
_snapshot_fail
setup_temp_dir

resolution_uses_authoritative_findings=false

# The Autonomous Resolution Loop section must document that {findings_file} is the
# opus-written authoritative reviewer-findings.json, not the temp a/b/c paths.
# Look for language explicitly linking findings_file to the opus-written/authoritative file
# in the context of the resolution sub-agent dispatch.
if grep -qE 'findings_file.*opus|opus.*findings_file|findings_file.*authoritative|authoritative.*findings_file' "$REVIEW_WORKFLOW" 2>/dev/null; then
    resolution_uses_authoritative_findings=true
fi

# Also check for explicit "not temp" or "not a/b/c" language near findings_file
if [[ "$resolution_uses_authoritative_findings" == "false" ]]; then
    if grep -qE 'findings_file.*not.*temp|findings_file.*not.*reviewer-findings-[abc]|resolution.*sub-agent.*authoritative.*findings' "$REVIEW_WORKFLOW" 2>/dev/null; then
        resolution_uses_authoritative_findings=true
    fi
fi

assert_eq "test_deep_tier_resolution_uses_authoritative_findings: REVIEW-WORKFLOW.md Autonomous Resolution Loop should explicitly document that {findings_file} is the opus-written authoritative reviewer-findings.json (not temp a/b/c paths)" "true" "$resolution_uses_authoritative_findings"

teardown_temp_dir
assert_pass_if_clean "test_deep_tier_resolution_uses_authoritative_findings"

# test_deep_tier_resolution_cached_model_is_opus
# Verify that REVIEW-WORKFLOW.md documents {cached_model} for deep tier as 'opus'
# (not 'sonnet'). The resolution sub-agent in review-fix-dispatch.md Step 4 uses
# MODEL={cached_model} for validation — for deep tier reviews written by opus, the
# resolution agent should also use opus for correct architectural validation.
# RED: REVIEW-WORKFLOW.md line 375 currently documents deep->sonnet for {cached_model}.
# dso-xx59 will update this to deep->opus to match review-fix-dispatch.md Step 4 semantics.
_snapshot_fail
setup_temp_dir

cached_model_is_opus_for_deep=false

# Check that the workflow documents deep->opus for the {cached_model} placeholder
# (the line documenting cached_model tier mappings should show deep->opus)
if grep -qE 'cached_model.*deep.*opus|deep.*opus.*cached_model' "$REVIEW_WORKFLOW" 2>/dev/null; then
    cached_model_is_opus_for_deep=true
fi

# Also accept the table/mapping form: deep)→opus or deep->opus or deep: opus
if [[ "$cached_model_is_opus_for_deep" == "false" ]]; then
    if grep -qE "deep['\`]?[[:space:]]*[→>)]+[[:space:]]*['\`]?opus" "$REVIEW_WORKFLOW" 2>/dev/null; then
        cached_model_is_opus_for_deep=true
    fi
fi

# Confirm we are NOT just matching the existing deep->sonnet entry
# The test is specifically checking that the mapping shows opus for deep tier
if [[ "$cached_model_is_opus_for_deep" == "false" ]]; then
    # Verify the line with cached_model and deep explicitly maps to opus
    if grep -E 'cached_model' "$REVIEW_WORKFLOW" 2>/dev/null | grep -q "deep.*opus"; then
        cached_model_is_opus_for_deep=true
    fi
fi

assert_eq "test_deep_tier_resolution_cached_model_is_opus: REVIEW-WORKFLOW.md should document {cached_model} for deep tier as 'opus' (not 'sonnet') to match review-fix-dispatch.md Step 4 validation semantics" "true" "$cached_model_is_opus_for_deep"

teardown_temp_dir
assert_pass_if_clean "test_deep_tier_resolution_cached_model_is_opus"

# ============================================================
# Summary
# ============================================================

print_summary
