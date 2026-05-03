#!/usr/bin/env bash
# tests/docs/test-reviewer-severity-calibration.sh
#
# Structural boundary test: reviewer-base.md must contain a
# "## Severity Calibration Rubric" section.
#
# This is a design-contract test: the section heading IS the structural
# boundary — its presence ensures reviewers have explicit calibration
# guidance for severity assignments (critical/important/minor), preventing
# severity inflation or deflation.
#
# Observable behavior tested:
#   1. reviewer-base.md contains the heading "## Severity Calibration Rubric"
#
# RED phase: test FAILS because the heading does not yet exist in reviewer-base.md.

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
ASSERT_LIB="$REPO_ROOT/tests/lib/assert.sh"
# shellcheck source=../lib/assert.sh
source "$ASSERT_LIB"

REVIEWER_BASE="$REPO_ROOT/plugins/dso/docs/workflows/prompts/reviewer-base.md"

# ---------------------------------------------------------------------------
# test_severity_calibration_rubric_section_exists
#
# Verifies that reviewer-base.md contains a "## Severity Calibration Rubric"
# section heading. The presence of this section ensures that reviewer agents
# have explicit calibration guidance for assigning severity levels.
# ---------------------------------------------------------------------------
echo "=== test_severity_calibration_rubric_section_exists ==="

if grep -q '^## Severity Calibration Rubric' "$REVIEWER_BASE"; then
    assert_eq \
        "reviewer-base.md contains ## Severity Calibration Rubric section" \
        "present" \
        "present"
else
    assert_eq \
        "reviewer-base.md contains ## Severity Calibration Rubric section" \
        "## Severity Calibration Rubric heading present" \
        "heading not found — section does not exist yet"
fi

print_summary
