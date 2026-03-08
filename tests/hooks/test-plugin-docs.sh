#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-plugin-docs.sh
# Verifies that the 7 reference docs and 2 workflow docs have been copied
# to the correct locations inside lockpick-workflow/.
#
# Usage:
#   bash lockpick-workflow/tests/hooks/test-plugin-docs.sh

REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

PLUGIN_DOCS="$REPO_ROOT/lockpick-workflow/docs"
PLUGIN_WORKFLOWS="$REPO_ROOT/lockpick-workflow/docs/workflows"

# test_plugin_reference_docs_exist
# All 7 reference docs must exist at lockpick-workflow/docs/.
reference_docs=(
    "MODEL-TIERS.md"
    "WORKTREE-GUIDE.md"
    "PLAN-APPROVAL-WORKFLOW.md"
    "DEPENDENCY-GUIDANCE.md"
    "INCIDENT-TEMPLATE.md"
    "TOOL-ERROR-TEMPLATE.md"
    "REVIEW-SCHEMA.md"
)

for doc in "${reference_docs[@]}"; do
    if [[ -f "$PLUGIN_DOCS/$doc" ]]; then
        actual="exists"
    else
        actual="missing"
    fi
    assert_eq "test_plugin_reference_docs_exist: $doc" "exists" "$actual"
done

# test_plugin_workflow_docs_exist
# COMMIT-WORKFLOW.md and REVIEW-WORKFLOW.md must exist at lockpick-workflow/docs/workflows/.
workflow_docs=(
    "COMMIT-WORKFLOW.md"
    "REVIEW-WORKFLOW.md"
)

for doc in "${workflow_docs[@]}"; do
    if [[ -f "$PLUGIN_WORKFLOWS/$doc" ]]; then
        actual="exists"
    else
        actual="missing"
    fi
    assert_eq "test_plugin_workflow_docs_exist: $doc" "exists" "$actual"
done

print_summary
