#!/usr/bin/env bash
# tests/workflows/test-per-branch-review.sh
# Structural deployment tests for .github/workflows/per-branch-review.yml.
#
# Scope (behavioral-testing-standard Rule 3 / Rule 5): this file is restricted
# to file-system structural checks — workflow file presence, resolver script
# presence and executable bit. Content-level YAML semantics (triggers, job
# dependencies, concurrency keys, embedded references, suspicious-diff
# warnings, etc.) are NOT asserted here: GitHub Actions runtime validates
# the YAML on every workflow invocation, and actionlint runs as a required
# CI check that statically validates structure and job graph. Tests that
# grep the workflow source would inspect text rather than behavior — that
# is the source-file-grepping anti-pattern this file used to exhibit and
# was cleaned up under bug da45-7d92-6c86-42bc / 1c80-f777-d96e-4df7.
#
# Usage: bash tests/workflows/test-per-branch-review.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
WORKFLOW_FILE="$REPO_ROOT/.github/workflows/per-branch-review.yml"
RESOLVE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/resolve-per-branch-review-base.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-per-branch-review.sh ==="

# ── test_workflow_file_exists ─────────────────────────────────────────────────
# The workflow YAML file must exist under .github/workflows/. Deployment-only
# check (file presence on disk); does NOT inspect file contents.
_snapshot_fail
file_exists=0
[[ -f "$WORKFLOW_FILE" ]] && file_exists=1
assert_eq "test_workflow_file_exists: .github/workflows/per-branch-review.yml exists" "1" "$file_exists"
assert_pass_if_clean "test_workflow_file_exists"

# ── test_resolve_base_script_present_and_executable ──────────────────────────
# The diff-base resolver script (referenced by per-branch-review.yml) must
# exist and be executable. Behavioral semantics of the resolver are covered
# in tests/scripts/test-resolve-per-branch-review-base.sh — this is a thin
# deployment-only check on file permissions.
_snapshot_fail
script_present=0
[[ -f "$RESOLVE_SCRIPT" && -x "$RESOLVE_SCRIPT" ]] && script_present=1
assert_eq "test_resolve_base_script_present_and_executable: resolver script exists and is executable" "1" "$script_present"
assert_pass_if_clean "test_resolve_base_script_present_and_executable"

print_summary
