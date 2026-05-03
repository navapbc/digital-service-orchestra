#!/usr/bin/env bash
# tests/docs/test-reviewer-diff-boundary.sh
# Structural boundary tests for the Diff-Boundary Discipline section in reviewer-base.md.
#
# Tests covered:
#   1. test_diff_boundary_section_exists — reviewer-base.md contains ## Diff-Boundary Discipline heading
#
# Usage: bash tests/docs/test-reviewer-diff-boundary.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

REVIEWER_BASE="$REPO_ROOT/plugins/dso/docs/workflows/prompts/reviewer-base.md"

echo "=== test-reviewer-diff-boundary.sh ==="

# ── test_diff_boundary_section_exists ─────────────────────────────────────────
# Given: reviewer-base.md exists
# When:  grepped for the Diff-Boundary Discipline section heading
# Then:  heading is present
_snapshot_fail
if grep -q '^## Diff-Boundary Discipline' "$REVIEWER_BASE"; then
    assert_eq "test_diff_boundary_section_exists" "present" "present"
else
    assert_eq "test_diff_boundary_section_exists" "heading present" "heading not found"
fi
assert_pass_if_clean "test_diff_boundary_section_exists"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
