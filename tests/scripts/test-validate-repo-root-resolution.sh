#!/usr/bin/env bash
# tests/scripts/test-validate-repo-root-resolution.sh
# TDD tests for validate.sh REPO_ROOT resolution (bug 8229-e80e-4df6-4509).
#
# Canonical pattern (check-persistence-coverage.sh):
#   REPO_ROOT="${PROJECT_ROOT:-$(git rev-parse --show-toplevel)}"
#
# Bug: the else-branch fallback silently resolved to $SCRIPT_DIR/..
# (the plugin cache root) when invoked outside a git repo without PROJECT_ROOT.
# Fix: fail explicitly when git rev-parse fails and PROJECT_ROOT is unset;
# use PROJECT_ROOT when provided.
#
# Usage: bash tests/scripts/test-validate-repo-root-resolution.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
VALIDATE_SH="$PLUGIN_ROOT/plugins/dso/scripts/validate.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-validate-repo-root-resolution.sh ==="

# Create a temp dir that is outside any git repo (used as cwd)
TMPDIR_OUTSIDE="$(mktemp -d "${TMPDIR:-/tmp}/test-validate-repo-root.XXXXXX")"
trap 'rm -rf "$TMPDIR_OUTSIDE"' EXIT

# Confirm the temp dir is not inside a git repo (sanity check)
if git -C "$TMPDIR_OUTSIDE" rev-parse --show-toplevel >/dev/null 2>&1; then
    echo "SKIP: cannot create a directory outside a git repo on this system" >&2
    print_summary
fi

# -- test_no_git_no_project_root_exits_nonzero --------------------------------
# When cwd is outside a git repo and PROJECT_ROOT is unset, validate.sh must
# exit non-zero (not silently proceed with plugin-cache REPO_ROOT).
_snapshot_fail
output=$(cd "$TMPDIR_OUTSIDE" && PROJECT_ROOT="" bash "$VALIDATE_SH" --help 2>&1) || rc=$?
rc=${rc:-0}
assert_ne "no-git-no-project-root: exit code should be nonzero" "0" "$rc"
assert_contains "no-git-no-project-root: ERROR message in output" "ERROR" "$output"
assert_pass_if_clean "test_no_git_no_project_root_exits_nonzero"

# -- test_no_git_with_project_root_resolves_ok --------------------------------
# When PROJECT_ROOT is set to a real directory, REPO_ROOT is resolved from it
# and validate.sh proceeds (exits 0 from --help).
_snapshot_fail
# Use PLUGIN_ROOT as a stand-in for a valid project root (has .claude/ or is
# at minimum a directory that exists). The --help path exits 0 after printing.
output2=$(cd "$TMPDIR_OUTSIDE" && PROJECT_ROOT="$PLUGIN_ROOT" bash "$VALIDATE_SH" --help 2>&1)
rc2=$?
assert_eq "with-project-root: exit code should be 0 (--help success)" "0" "$rc2"
assert_contains "with-project-root: Usage in output" "Usage" "$output2"
assert_pass_if_clean "test_no_git_with_project_root_resolves_ok"

print_summary
