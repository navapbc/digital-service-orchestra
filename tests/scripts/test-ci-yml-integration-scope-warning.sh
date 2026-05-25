#!/usr/bin/env bash
# tests/scripts/test-ci-yml-integration-scope-warning.sh
# F6 of bug db71-e078-ec99-4fbf: ci.yml emits a GitHub Actions ::warning::
# when INTEGRATION_SCOPE_EMPTY=true AND the PR has more than one non-merge
# commit (i.e. it is plausibly a multi-story session PR with missing
# trailers, not a single trivial change).
#
# Structural assertions (not change-detector):
#   I1: ci.yml contains a `::warning::` emission near the
#       INTEGRATION_SCOPE_EMPTY=true block.
#   I2: That warning cites bug db71.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
CI="$REPO_ROOT/.github/workflows/ci.yml"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-ci-yml-integration-scope-warning.sh ==="

if [[ ! -f "$CI" ]]; then
    echo "FAIL: ci.yml not found at $CI" >&2
    (( ++FAIL ))
    print_summary
fi

# Extract a window: 30 lines following the first occurrence of
# INTEGRATION_SCOPE_EMPTY=true emission.
_WINDOW=$(awk '
    /INTEGRATION_SCOPE_EMPTY=true/ { hit=1; count=0 }
    hit { print; count++; if (count >= 40) exit }
' "$CI")

# I1: window contains '::warning::'.
_snapshot_fail
if [[ "$_WINDOW" == *"::warning::"* ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: I1_ci_integration_scope_empty_emits_warning" >&2
fi
assert_pass_if_clean "I1_ci_integration_scope_empty_emits_warning"

# I2: warning cites db71 (durable cross-reference to the bug).
_snapshot_fail
if [[ "$_WINDOW" == *"db71"* ]]; then
    (( ++PASS ))
else
    (( ++FAIL ))
    echo "FAIL: I2_ci_warning_cites_bug_db71" >&2
fi
assert_pass_if_clean "I2_ci_warning_cites_bug_db71"

print_summary
