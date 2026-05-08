#!/usr/bin/env bash
# tests/hooks/test-workflow-doc-wrapping.sh
# Doc-conformance tests: verify commit-step wrapper patterns in workflow docs (epic 750c, story 7020)
#
# All 5 tests should PASS immediately — the docs were updated by T3.
#
# REVIEW-DEFENSE (PR #78 finding 7): these are doc-conformance tests, not behavioral
# code tests. The story requirement (7020) was that workflow documentation be updated
# to wrap commands with commit-step. The observable outcome of that requirement IS the
# presence of specific text patterns in the doc files. For doc-conformance verification,
# grep against source files is the appropriate tool — the source-code-grepping
# anti-pattern applies to tests that assert function names or code structure exist
# instead of testing observable behavior. Here the subject IS the document text, and
# grep is the correct assertion mechanism.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git -C "$SCRIPT_DIR" rev-parse --show-toplevel)"
source "$REPO_ROOT/tests/lib/assert.sh"

VALIDATION_DOC="$REPO_ROOT/plugins/dso/docs/workflows/commit-workflow-validation.md"
REVIEW_DOC="$REPO_ROOT/plugins/dso/docs/workflows/REVIEW-WORKFLOW.md"

# test_commit_workflow_test_wrapped
# commit-workflow-validation.md must reference the commit-step test wrapper.
_snapshot_fail
found="no"
grep -q "commit-step test" "$VALIDATION_DOC" && found="yes"
assert_eq "commit_workflow_test_wrapped" "yes" "$found"
assert_pass_if_clean "test_commit_workflow_test_wrapped"

# test_commit_workflow_lint_wrapped
# commit-workflow-validation.md must reference the commit-step lint wrapper.
_snapshot_fail
found="no"
grep -q "commit-step lint" "$VALIDATION_DOC" && found="yes"
assert_eq "commit_workflow_lint_wrapped" "yes" "$found"
assert_pass_if_clean "test_commit_workflow_lint_wrapped"

# test_commit_workflow_format_wrapped
# commit-workflow-validation.md must reference the commit-step format wrapper.
_snapshot_fail
found="no"
grep -q "commit-step format" "$VALIDATION_DOC" && found="yes"
assert_eq "commit_workflow_format_wrapped" "yes" "$found"
assert_pass_if_clean "test_commit_workflow_format_wrapped"

# test_review_workflow_classifier_wrapped
# REVIEW-WORKFLOW.md must reference the commit-step classifier-dispatch wrapper.
_snapshot_fail
found="no"
grep -q "commit-step classifier-dispatch" "$REVIEW_DOC" && found="yes"
assert_eq "review_workflow_classifier_wrapped" "yes" "$found"
assert_pass_if_clean "test_review_workflow_classifier_wrapped"

# test_review_workflow_reviewer_record_wrapped
# REVIEW-WORKFLOW.md must reference the commit-step reviewer-record wrapper.
_snapshot_fail
found="no"
grep -q "commit-step reviewer-record" "$REVIEW_DOC" && found="yes"
assert_eq "review_workflow_reviewer_record_wrapped" "yes" "$found"
assert_pass_if_clean "test_review_workflow_reviewer_record_wrapped"

print_summary
