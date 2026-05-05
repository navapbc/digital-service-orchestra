#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031  # PATH/env modifications in subshells are intentional test isolation
# tests/scripts/test-ci-llm-review-runner.sh
# Shim contract tests for plugins/dso/scripts/ci-llm-review-runner.sh
#
# Tests covered:
#   1. test_runner_exits_one_for_unknown_flag  — shim exits 1 for unrecognized CLI flag
#   2. test_shim_sets_pythonpath               — PYTHONPATH is exported before exec
#   3. test_shim_delegates_to_python_module    — shim delegates to python3 -m dso_ci_review.runner
#
# Usage: bash tests/scripts/test-ci-llm-review-runner.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

RUNNER="$REPO_ROOT/plugins/dso/scripts/ci-llm-review-runner.sh"

# Track temp dirs for cleanup
_TEST_TMPDIRS=()
cleanup() {
    for d in "${_TEST_TMPDIRS[@]:-}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap cleanup EXIT

# ── test_runner_exits_one_for_unknown_flag ─────────────────────────────────────
# Given: a valid environment but an unknown flag --unknown-flag
# When:  shim is invoked
# Then:  exit code is 1
_snapshot_fail
unknown_flag_exit=0
( bash "$RUNNER" --unknown-flag < /dev/null ) 2>/dev/null || unknown_flag_exit=$?
assert_eq "test_runner_exits_one_for_unknown_flag: exits 1 for unknown flag" "1" "$unknown_flag_exit"
assert_pass_if_clean "test_runner_exits_one_for_unknown_flag"

# ── test_shim_sets_pythonpath ──────────────────────────────────────────────────
# Given: a mock python3 that prints PYTHONPATH then exits 0
# Then:  PYTHONPATH contains the scripts directory
_snapshot_fail
_mock_dir=$(mktemp -d /tmp/test-ci-shim-pythonpath.XXXXXX)
_TEST_TMPDIRS+=("$_mock_dir")

# Mock python3 that prints PYTHONPATH and exits 0
cat > "$_mock_dir/python3" <<'MOCKEOF'
#!/usr/bin/env bash
echo "PYTHONPATH=$PYTHONPATH"
exit 0
MOCKEOF
chmod +x "$_mock_dir/python3"

_pythonpath_out=""
_pythonpath_exit=0
_pythonpath_out=$(
    PATH="$_mock_dir:$PATH"
    PYTHON="$_mock_dir/python3"
    bash "$RUNNER" < /dev/null 2>&1
) || _pythonpath_exit=$?

assert_eq "test_shim_sets_pythonpath: mock python3 exits 0" "0" "$_pythonpath_exit"
assert_contains "test_shim_sets_pythonpath: PYTHONPATH exported with scripts path" "scripts" "$_pythonpath_out"
assert_pass_if_clean "test_shim_sets_pythonpath"

# ── test_shim_delegates_to_python_module ──────────────────────────────────────
# Given: a mock python3 that prints the module argument and exits
# When:  shim is invoked with no flags
# Then:  python3 is called with -m dso_ci_review.runner
_snapshot_fail
_mock_dir2=$(mktemp -d /tmp/test-ci-shim-delegate.XXXXXX)
_TEST_TMPDIRS+=("$_mock_dir2")

# Mock python3 that captures args and exits 0
cat > "$_mock_dir2/python3" <<'MOCKEOF'
#!/usr/bin/env bash
echo "ARGS: $*"
exit 0
MOCKEOF
chmod +x "$_mock_dir2/python3"

_delegate_out=""
_delegate_exit=0
_delegate_out=$(
    PATH="$_mock_dir2:$PATH"
    PYTHON="$_mock_dir2/python3"
    bash "$RUNNER" < /dev/null 2>&1
) || _delegate_exit=$?

assert_eq "test_shim_delegates_to_python_module: mock python3 exits 0" "0" "$_delegate_exit"
assert_contains "test_shim_delegates_to_python_module: called with -m flag" "-m" "$_delegate_out"
assert_contains "test_shim_delegates_to_python_module: called with dso_ci_review.runner" "dso_ci_review.runner" "$_delegate_out"
assert_pass_if_clean "test_shim_delegates_to_python_module"

# ── Summary ───────────────────────────────────────────────────────────────────
print_summary
