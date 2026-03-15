#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-pre-commit-config.sh
# Tests for .pre-commit-config.yaml structure and required top-level keys.
#
# Tests:
#   test_pre_commit_fail_fast_enabled — asserts fail_fast: true is present
#   test_combined_hook_runs_both_checks — asserts exactly one combined format+lint hook exists
#
# Usage:
#   bash lockpick-workflow/tests/scripts/test-pre-commit-config.sh
#   bash lockpick-workflow/tests/scripts/test-pre-commit-config.sh test_pre_commit_fail_fast_enabled
#   bash lockpick-workflow/tests/scripts/test-pre-commit-config.sh test_combined_hook_runs_both_checks
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

# ============================================================================
# test_combined_hook_runs_both_checks
# ============================================================================
_run_test_combined_hook_runs_both_checks() {
    echo "=== test_combined_hook_runs_both_checks ==="
    _snapshot_fail

    # 1. Count hooks whose id contains 'format' or 'lint' at the commit stage.
    #    There should be exactly 1 (the combined format-and-lint hook).
    HOOK_COUNT=$("$PYTHON" -c "
import yaml, sys
data = yaml.safe_load(open('$CONFIG'))
hooks = [h for r in data.get('repos', []) for h in r.get('hooks', [])]
commit_hooks = [h for h in hooks if not h.get('stages') or 'commit' in h.get('stages', [])]
matching = [h for h in commit_hooks if 'format' in h.get('id','') or 'lint' in h.get('id','')]
print(len(matching))
" 2>/dev/null || echo "error")

    assert_eq "exactly one combined format+lint hook in .pre-commit-config.yaml" "1" "$HOOK_COUNT"

    # 2. The combined hook id must be 'format-and-lint'.
    HOOK_ID=$("$PYTHON" -c "
import yaml, sys
data = yaml.safe_load(open('$CONFIG'))
hooks = [h for r in data.get('repos', []) for h in r.get('hooks', [])]
commit_hooks = [h for h in hooks if not h.get('stages') or 'commit' in h.get('stages', [])]
matching = [h for h in commit_hooks if 'format' in h.get('id','') or 'lint' in h.get('id','')]
print(matching[0]['id'] if matching else 'none')
" 2>/dev/null || echo "error")

    assert_eq "combined hook id is format-and-lint" "format-and-lint" "$HOOK_ID"

    # 3. The combined hook script must pass bash -n (syntax check).
    SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/format-and-lint.sh"
    if [[ -f "$SCRIPT" ]]; then
        bash -n "$SCRIPT" 2>/dev/null
        SYNTAX_EXIT=$?
        assert_eq "format-and-lint.sh passes bash -n" "0" "$SYNTAX_EXIT"
    else
        (( ++FAIL ))
        printf "FAIL: format-and-lint.sh does not exist at %s\n" "$SCRIPT" >&2
    fi

    assert_pass_if_clean "test_combined_hook_runs_both_checks"
}

# Support running a single named test or all tests
if [[ "${1:-}" == "test_pre_commit_fail_fast_enabled" ]]; then
    _run_test_pre_commit_fail_fast_enabled
elif [[ "${1:-}" == "test_combined_hook_runs_both_checks" ]]; then
    _run_test_combined_hook_runs_both_checks
elif [[ -n "${1:-}" ]]; then
    echo "Unknown test: $1" >&2
    exit 1
else
    _run_test_pre_commit_fail_fast_enabled
    _run_test_combined_hook_runs_both_checks
fi

print_summary
