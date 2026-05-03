#!/usr/bin/env bash
set -uo pipefail
REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$REPO_ROOT/tests/lib/assert.sh"
REVIEWER_BASE="$REPO_ROOT/plugins/dso/docs/workflows/prompts/reviewer-base.md"
REVIEWER_DELTA_TQ="$REPO_ROOT/plugins/dso/docs/workflows/prompts/reviewer-delta-test-quality.md"

echo "=== test_not_flag_rules_section_exists ==="
if grep -q '^## NOT-Flag Auto-Downgrade Rules' "$REVIEWER_BASE"; then
    assert_eq "reviewer-base.md contains ## NOT-Flag Auto-Downgrade Rules section" "present" "present"
else
    assert_eq "reviewer-base.md contains ## NOT-Flag Auto-Downgrade Rules section" \
        "heading present" "heading not found"
fi

echo "=== test_not_flag_exemption_exists ==="
if grep -q '^## NOT-Flag' "$REVIEWER_DELTA_TQ"; then
    assert_eq "reviewer-delta-test-quality.md contains NOT-Flag exemption section" "present" "present"
else
    assert_eq "reviewer-delta-test-quality.md contains NOT-Flag exemption section" \
        "exemption present" "exemption not found"
fi

print_summary
