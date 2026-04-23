#!/usr/bin/env bash
# tests/scripts/test-ci-no-v2-paths.sh
# Assert that no .tickets/ path-ignore or exclude patterns exist in CI workflows
# and example config files. These patterns were required under the v2 ticket
# system (file-per-ticket in .tickets/); the v3 event-sourced system mounts the
# tickets branch as a worktree at .tickets-tracker/, so .tickets/ no longer
# needs special treatment in CI or pre-commit configs.
#
# Tests covered:
#   1. test_ci_yml_no_tickets_paths
#   2. test_ci_example_yml_no_tickets_paths
#   3. test_precommit_example_no_tickets_exclude
#
# Usage: bash tests/scripts/test-ci-no-v2-paths.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail
#
# RED state: this test FAILS until Task 2 removes the .tickets/ patterns.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-ci-no-v2-paths.sh ==="

CI_YML="$REPO_ROOT/.github/workflows/ci.yml"
CI_EXAMPLE_YML="$REPO_ROOT/plugins/dso/docs/examples/ci.example.yml"
PRECOMMIT_EXAMPLE="$REPO_ROOT/plugins/dso/docs/examples/pre-commit-config.example.yaml"

# ── test_ci_yml_no_tickets_paths ─────────────────────────────────────────────
# .github/workflows/ci.yml must contain no .tickets/ path-ignore entries.
# Under v3, CI triggers on .tickets-tracker/ (the worktree mount), not .tickets/.
_snapshot_fail
count=0
count=$(grep -c '\.tickets' "$CI_YML" 2>/dev/null || true)
assert_eq "test_ci_yml_no_tickets_paths" "0" "$count"
assert_pass_if_clean "test_ci_yml_no_tickets_paths"

# ── test_ci_example_yml_no_tickets_paths ─────────────────────────────────────
# examples/ci.example.yml must contain no .tickets/ path-ignore entries.
# If the file does not exist, the test passes (no references possible).
# Stack-specific examples (ci.example.python-poetry.yml, ci.example.node-npm.yml)
# superseded the generic ci.example.yml; an absent file means 0 references.
_snapshot_fail
count=0
if [[ -f "$CI_EXAMPLE_YML" ]]; then
    count=$(grep -c '\.tickets' "$CI_EXAMPLE_YML" 2>/dev/null || true)
fi
assert_eq "test_ci_example_yml_no_tickets_paths" "0" "$count"
assert_pass_if_clean "test_ci_example_yml_no_tickets_paths"

# ── test_precommit_example_no_tickets_exclude ─────────────────────────────────
# examples/pre-commit-config.example.yaml must contain no .tickets/ exclude entries.
_snapshot_fail
count=0
count=$(grep -c '\.tickets' "$PRECOMMIT_EXAMPLE" 2>/dev/null || true)
assert_eq "test_precommit_example_no_tickets_exclude" "0" "$count"
assert_pass_if_clean "test_precommit_example_no_tickets_exclude"

print_summary
