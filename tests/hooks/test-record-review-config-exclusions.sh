#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-record-review-config-exclusions.sh
# Tests that record-review.sh uses config-derived exclusion paths
# instead of hardcoded app/tests/e2e/snapshots/ and app/tests/unit/templates/snapshots/*.html.
#
# Usage: bash lockpick-workflow/tests/hooks/test-record-review-config-exclusions.sh
# Exit code: 0 if all pass, 1 if any fail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$REPO_ROOT/lockpick-workflow/hooks/record-review.sh"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

# Helper: check if a pattern exists in the hook file
_hook_has() { grep -q "$1" "$HOOK" 2>/dev/null && echo "yes" || echo "no"; }

# ============================================================================
# test_record_review_no_hardcoded_e2e_snapshot_path
# ============================================================================
echo "=== test_record_review_no_hardcoded_e2e_snapshot_path ==="
assert_eq "no hardcoded app/tests/e2e/snapshots in record-review.sh" "no" "$(_hook_has 'app/tests/e2e/snapshots')"

# ============================================================================
# test_record_review_no_hardcoded_unit_snapshot_path
# ============================================================================
echo "=== test_record_review_no_hardcoded_unit_snapshot_path ==="
assert_eq "no hardcoded app/tests/unit/templates/snapshots in record-review.sh" "no" "$(_hook_has 'app/tests/unit/templates/snapshots')"

# ============================================================================
# test_record_review_sources_config_paths
# ============================================================================
echo "=== test_record_review_sources_config_paths ==="
assert_eq "record-review.sh sources config-paths.sh" "yes" "$(_hook_has 'config-paths.sh')"

# ============================================================================
# test_record_review_uses_cfg_visual_baseline_path
# ============================================================================
echo "=== test_record_review_uses_cfg_visual_baseline_path ==="
assert_eq "record-review.sh uses CFG_VISUAL_BASELINE_PATH" "yes" "$(_hook_has 'CFG_VISUAL_BASELINE_PATH')"

# ============================================================================
# test_record_review_uses_cfg_unit_snapshot_path
# ============================================================================
echo "=== test_record_review_uses_cfg_unit_snapshot_path ==="
assert_eq "record-review.sh uses CFG_UNIT_SNAPSHOT_PATH" "yes" "$(_hook_has 'CFG_UNIT_SNAPSHOT_PATH')"

print_summary
