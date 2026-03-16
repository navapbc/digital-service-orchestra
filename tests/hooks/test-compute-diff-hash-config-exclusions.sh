#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-compute-diff-hash-config-exclusions.sh
# Tests that compute-diff-hash.sh uses config-derived exclusion paths
# instead of hardcoded app/tests/e2e/snapshots/ and app/tests/unit/templates/snapshots/*.html.
#
# Usage: bash lockpick-workflow/tests/hooks/test-compute-diff-hash-config-exclusions.sh
# Exit code: 0 if all pass, 1 if any fail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOK="$PLUGIN_ROOT/hooks/compute-diff-hash.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Helper: check if a pattern exists in the hook file
_hook_has() { grep -q "$1" "$HOOK" 2>/dev/null && echo "yes" || echo "no"; }

# ============================================================================
# test_compute_diff_hash_no_hardcoded_e2e_snapshot_path
# ============================================================================
echo "=== test_compute_diff_hash_no_hardcoded_e2e_snapshot_path ==="
assert_eq "no hardcoded app/tests/e2e/snapshots in compute-diff-hash.sh" "no" "$(_hook_has 'app/tests/e2e/snapshots')"

# ============================================================================
# test_compute_diff_hash_no_hardcoded_unit_snapshot_path
# ============================================================================
echo "=== test_compute_diff_hash_no_hardcoded_unit_snapshot_path ==="
assert_eq "no hardcoded app/tests/unit/templates/snapshots in compute-diff-hash.sh" "no" "$(_hook_has 'app/tests/unit/templates/snapshots')"

# ============================================================================
# test_compute_diff_hash_sources_config_paths
# ============================================================================
echo "=== test_compute_diff_hash_sources_config_paths ==="
assert_eq "compute-diff-hash.sh sources config-paths.sh" "yes" "$(_hook_has 'config-paths.sh')"

# ============================================================================
# test_compute_diff_hash_uses_cfg_visual_baseline_path
# ============================================================================
echo "=== test_compute_diff_hash_uses_cfg_visual_baseline_path ==="
assert_eq "compute-diff-hash.sh uses CFG_VISUAL_BASELINE_PATH" "yes" "$(_hook_has 'CFG_VISUAL_BASELINE_PATH')"

# ============================================================================
# test_compute_diff_hash_uses_cfg_unit_snapshot_path
# ============================================================================
echo "=== test_compute_diff_hash_uses_cfg_unit_snapshot_path ==="
assert_eq "compute-diff-hash.sh uses CFG_UNIT_SNAPSHOT_PATH" "yes" "$(_hook_has 'CFG_UNIT_SNAPSHOT_PATH')"

print_summary
