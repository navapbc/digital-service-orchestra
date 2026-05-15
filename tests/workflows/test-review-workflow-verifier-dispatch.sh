#!/usr/bin/env bash
# tests/workflows/test-review-workflow-verifier-dispatch.sh
# RED structural tests for REVIEW-WORKFLOW.md verifier dispatch step.
# Testing Mode: RED — fails until S5 T2 adds verifier step to REVIEW-WORKFLOW.md

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

REVIEW_WORKFLOW="$PLUGIN_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md"

# test_review_workflow_verifier_step_documented
# REVIEW-WORKFLOW.md must contain a dedicated verifier dispatch step
echo "--- test_review_workflow_verifier_step_documented ---"
_snapshot_fail
grep -qi "verifier dispatch\|verifier agent\|Step 4\.5\|dispatch.*verifier" "$REVIEW_WORKFLOW" 2>/dev/null
assert_eq "test_review_workflow_verifier_step_documented: verifier dispatch step present" "0" "$?"
assert_pass_if_clean "test_review_workflow_verifier_step_documented"

# test_review_workflow_bounded_bash_allowlist_documented
# Verifier uses bounded bash allowlist: grep, stat, ls, file
echo "--- test_review_workflow_bounded_bash_allowlist_documented ---"
_snapshot_fail
grep -qE "bounded.*bash|bash.*allowlist|allowlist.*grep|verifier.*grep.*stat|grep.*stat.*ls.*file" "$REVIEW_WORKFLOW" 2>/dev/null
assert_eq "test_review_workflow_bounded_bash_allowlist_documented: bounded bash allowlist documented" "0" "$?"
assert_pass_if_clean "test_review_workflow_bounded_bash_allowlist_documented"

# test_review_workflow_git_show_sha_reads_documented
# Document that verifier uses git show <reviewed_sha>:<path>
echo "--- test_review_workflow_git_show_sha_reads_documented ---"
_snapshot_fail
grep -q "reviewed_sha\|git show.*sha" "$REVIEW_WORKFLOW" 2>/dev/null
assert_eq "test_review_workflow_git_show_sha_reads_documented: git show sha pattern documented" "0" "$?"
assert_pass_if_clean "test_review_workflow_git_show_sha_reads_documented"

# test_review_workflow_minor_findings_bypass_documented
# Minor findings must bypass the verifier
echo "--- test_review_workflow_minor_findings_bypass_documented ---"
_snapshot_fail
grep -qi "minor.*bypass\|bypass.*minor\|skip.*minor.*verifier\|minor.*skip.*verifier\|verifier.*minor" "$REVIEW_WORKFLOW" 2>/dev/null
assert_eq "test_review_workflow_minor_findings_bypass_documented: minor findings bypass documented" "0" "$?"
assert_pass_if_clean "test_review_workflow_minor_findings_bypass_documented"

# test_review_workflow_confirm_ruling_documented
# verifier confirm ruling semantics must be documented
echo "--- test_review_workflow_confirm_ruling_documented ---"
_snapshot_fail
grep -qi "verifier.*confirm\|confirm.*ruling\|ruling.*confirm" "$REVIEW_WORKFLOW" 2>/dev/null
assert_eq "test_review_workflow_confirm_ruling_documented: verifier confirm ruling documented" "0" "$?"
assert_pass_if_clean "test_review_workflow_confirm_ruling_documented"

# test_review_workflow_drop_ruling_documented
# verifier drop ruling semantics must be documented
echo "--- test_review_workflow_drop_ruling_documented ---"
_snapshot_fail
grep -qi "verifier.*drop\|drop.*ruling\|ruling.*drop" "$REVIEW_WORKFLOW" 2>/dev/null
assert_eq "test_review_workflow_drop_ruling_documented: verifier drop ruling documented" "0" "$?"
assert_pass_if_clean "test_review_workflow_drop_ruling_documented"

print_summary
