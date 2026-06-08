#!/usr/bin/env bash
# tests/workflows/test-review-convergence-wired.sh
#
# Regression guard for bug 2195 (epic 7412): review-convergence-check.sh was built and
# unit-tested but invoked NOWHERE, so the review loop had no oscillation/cycle-cap brake.
# This asserts the WIRING contract — that the ci.yml llm-review path actually invokes the
# convergence check, and that the referenced script exists and is executable.
#
# Per behavioral-testing-standard Rule 5, this is a referential-integrity structural
# assertion on a declarative workflow artifact (the invocation reference IS the
# integration interface), not a content change-detector. The workflow's own validity is
# covered by the Actionlint CI job; the check's logic is covered by
# tests/scripts/test-review-convergence-check.sh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
source "$REPO_ROOT/tests/lib/assert.sh"

CI_WORKFLOW="$REPO_ROOT/.github/workflows/ci.yml"
CONVERGENCE_SCRIPT="$REPO_ROOT/plugins/dso/scripts/ci/review-convergence-check.sh"
REL_REF="plugins/dso/scripts/ci/review-convergence-check.sh"

# The convergence check is invoked from the ci.yml review path (bug 2195 fix).
if grep -qF "$REL_REF" "$CI_WORKFLOW" 2>/dev/null; then
    assert_eq "test_convergence_check_wired_in_ci" "wired" "wired"
else
    assert_eq "test_convergence_check_wired_in_ci" "wired" "NOT_wired"
fi

# The referenced script exists and is executable (the test gate skips non-executable .sh).
assert_eq "test_convergence_script_exists" "yes" "$([ -f "$CONVERGENCE_SCRIPT" ] && echo yes || echo no)"
assert_eq "test_convergence_script_executable" "yes" "$([ -x "$CONVERGENCE_SCRIPT" ] && echo yes || echo no)"

print_summary
