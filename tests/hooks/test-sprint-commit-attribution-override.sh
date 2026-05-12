#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT=$(git rev-parse --show-toplevel)
source "$REPO_ROOT/tests/lib/assert.sh"

_wf="$REPO_ROOT/plugins/dso/docs/workflows/COMMIT-WORKFLOW.md"
_script="$REPO_ROOT/plugins/dso/scripts/apply-attribution-trailers.sh"

_wf_content=$(cat "$_wf")
_script_content=$(cat "$_script")

assert_contains "COMMIT-WORKFLOW.md: DSO_SPRINT_MODE override documented" \
    "DSO_SPRINT_MODE" "$_wf_content"
assert_contains "apply-attribution-trailers.sh: DSO_SPRINT_MODE bypass present" \
    "DSO_SPRINT_MODE" "$_script_content"

print_summary
