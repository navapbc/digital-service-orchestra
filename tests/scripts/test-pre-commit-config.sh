#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-pre-commit-config.sh
# Tests for .pre-commit-config.yaml structure and required top-level keys.
#
# Tests:
#   test_pre_commit_fail_fast_enabled — asserts fail_fast: true is present
#
# Usage:
#   bash lockpick-workflow/tests/scripts/test-pre-commit-config.sh
#   bash lockpick-workflow/tests/scripts/test-pre-commit-config.sh test_pre_commit_fail_fast_enabled
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
CONFIG="$REPO_ROOT/.pre-commit-config.yaml"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# Locate a python3 with pyyaml available.
_find_python_with_yaml() {
    for candidate in \
        "$REPO_ROOT/app/.venv/bin/python3" \
        "$REPO_ROOT/.venv/bin/python3" \
        /usr/bin/python3 \
        /usr/local/bin/python3 \
        python3; do
        [[ -z "$candidate" ]] && continue
        if "$candidate" -c "import yaml" 2>/dev/null; then
            echo "$candidate"
            return 0
        fi
    done
    return 1
}

PYTHON=$(_find_python_with_yaml 2>/dev/null || echo "python3")

echo "=== test-pre-commit-config.sh ==="

# ============================================================================
# test_pre_commit_fail_fast_enabled
# ============================================================================
_run_test_pre_commit_fail_fast_enabled() {
    echo "=== test_pre_commit_fail_fast_enabled ==="
    _snapshot_fail

    FAIL_FAST_VAL=$("$PYTHON" -c "
import yaml, sys
data = yaml.safe_load(open('$CONFIG'))
val = data.get('fail_fast')
print('true' if val is True else str(val))
" 2>/dev/null || echo "error")

    assert_eq "fail_fast is true in .pre-commit-config.yaml" "true" "$FAIL_FAST_VAL"

    assert_pass_if_clean "test_pre_commit_fail_fast_enabled"
}

# Support running a single named test or all tests
if [[ "${1:-}" == "test_pre_commit_fail_fast_enabled" ]]; then
    _run_test_pre_commit_fail_fast_enabled
elif [[ -n "${1:-}" ]]; then
    echo "Unknown test: $1" >&2
    exit 1
else
    _run_test_pre_commit_fail_fast_enabled
fi

print_summary
