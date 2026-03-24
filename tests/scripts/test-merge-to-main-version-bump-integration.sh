#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-version-bump-integration.sh
#
# Integration test: sequential two-worktree merges produce correct version increments.
#
# Verifies the core epic success criterion:
#   "Two worktree sessions that both modify code files can merge to main
#    sequentially: both merges exit 0, the version file contains no conflict
#    markers, and the final version is exactly two patch increments above the
#    pre-merge baseline."
#
# Test approach (no network calls, no full merge-to-main.sh invocation):
#   1. Create a baseline plugin.json with version 0.1.0
#   2. Simulate worktree-a merge: call bump-version.sh --patch on the file
#      → expect 0.1.1
#   3. Simulate worktree-b merge (sequential, after worktree-a's push):
#      call bump-version.sh --patch on the post-a file
#      → expect 0.1.2
#   4. Assert final version == 0.1.2 (exactly two patch increments above baseline)
#   5. Assert no conflict markers (<<<<<<, =======, >>>>>>) in the version file
#
# Test list:
#   1. test_sequential_merges_produce_two_increments
#   2. test_worktree_a_increments_once
#   3. test_worktree_b_increments_from_post_a_version
#   4. test_no_conflict_markers_in_version_file_after_baseline
#   5. test_no_conflict_markers_in_version_file_after_worktree_a
#   6. test_no_conflict_markers_in_version_file_after_worktree_b
#
# Usage: bash tests/scripts/test-merge-to-main-version-bump-integration.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUMP_SCRIPT="$PLUGIN_ROOT/plugins/dso/scripts/bump-version.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# =============================================================================
# Guard: bump-version.sh must exist and be executable
# =============================================================================
if [[ ! -x "$BUMP_SCRIPT" ]]; then
    echo "FATAL: bump-version.sh not found or not executable: $BUMP_SCRIPT" >&2
    exit 1
fi

# =============================================================================
# Helper: create a minimal dso-config.conf pointing at the given version file
# =============================================================================
_write_config() {
    local config_path="$1"
    local version_file_path="$2"
    printf 'version.file_path=%s\n' "$version_file_path" > "$config_path"
}

# =============================================================================
# Helper: read the version field from a plugin.json file
# =============================================================================
_read_version() {
    local json_file="$1"
    python3 -c "import json,sys; print(json.load(open(sys.argv[1]))['version'])" "$json_file" 2>/dev/null
}

# =============================================================================
# Helper: check for conflict markers in a file (returns 0 if ANY found)
# =============================================================================
_has_conflict_markers() {
    local file="$1"
    grep -qE '^(<{7}|={7}|>{7})' "$file" 2>/dev/null
}

# =============================================================================
# Fixture setup
# =============================================================================
BASELINE_VERSION="0.1.0"

TEST_BASE=$(mktemp -d)
trap 'rm -rf "$TEST_BASE"' EXIT

# Create a shared plugin.json at baseline
PLUGIN_JSON="$TEST_BASE/plugin.json"
python3 -c "
import json
data = {'name': 'dso', 'version': '$BASELINE_VERSION', 'description': 'test fixture'}
with open('$PLUGIN_JSON', 'w') as f:
    json.dump(data, f, indent=2)
    f.write('\n')
"

# Write a dso-config.conf for bump-version.sh to read
CONFIG_FILE="$TEST_BASE/dso-config.conf"
_write_config "$CONFIG_FILE" "$PLUGIN_JSON"

echo "=== Integration test: sequential two-worktree version bumps ==="
echo "Baseline: $BASELINE_VERSION  File: $PLUGIN_JSON"
echo ""

# =============================================================================
# Verify baseline: no conflict markers present before any merge
# =============================================================================
echo "--- test_no_conflict_markers_in_version_file_after_baseline ---"
_snapshot_fail

if _has_conflict_markers "$PLUGIN_JSON"; then
    BASELINE_CONFLICT="yes"
else
    BASELINE_CONFLICT="no"
fi
assert_eq "test_no_conflict_markers_in_version_file_after_baseline" "no" "$BASELINE_CONFLICT"

assert_pass_if_clean "test_no_conflict_markers_in_version_file_after_baseline"

# =============================================================================
# Step 1 — Simulate worktree-a merge: bump-version.sh --patch
# Expected: 0.1.0 → 0.1.1
# =============================================================================
echo ""
echo "--- test_worktree_a_increments_once ---"
_snapshot_fail

WORKTREE_A_RC=0
WORKTREE_A_OUT=$(bash "$BUMP_SCRIPT" --patch --config "$CONFIG_FILE" 2>&1) || WORKTREE_A_RC=$?

assert_eq "test_worktree_a_bump_exits_0" "0" "$WORKTREE_A_RC"

VERSION_AFTER_A=$(_read_version "$PLUGIN_JSON")
assert_eq "test_worktree_a_increments_once" "0.1.1" "$VERSION_AFTER_A"

assert_pass_if_clean "test_worktree_a_increments_once"

# =============================================================================
# Verify no conflict markers after worktree-a merge
# =============================================================================
echo ""
echo "--- test_no_conflict_markers_in_version_file_after_worktree_a ---"
_snapshot_fail

if _has_conflict_markers "$PLUGIN_JSON"; then
    AFTER_A_CONFLICT="yes"
else
    AFTER_A_CONFLICT="no"
fi
assert_eq "test_no_conflict_markers_in_version_file_after_worktree_a" "no" "$AFTER_A_CONFLICT"

assert_pass_if_clean "test_no_conflict_markers_in_version_file_after_worktree_a"

# =============================================================================
# Step 2 — Simulate worktree-b merge (sequential, reads post-a file):
# bump-version.sh --patch
# Expected: 0.1.1 → 0.1.2
# =============================================================================
echo ""
echo "--- test_worktree_b_increments_from_post_a_version ---"
_snapshot_fail

WORKTREE_B_RC=0
WORKTREE_B_OUT=$(bash "$BUMP_SCRIPT" --patch --config "$CONFIG_FILE" 2>&1) || WORKTREE_B_RC=$?

assert_eq "test_worktree_b_bump_exits_0" "0" "$WORKTREE_B_RC"

VERSION_AFTER_B=$(_read_version "$PLUGIN_JSON")
assert_eq "test_worktree_b_increments_from_post_a_version" "0.1.2" "$VERSION_AFTER_B"

assert_pass_if_clean "test_worktree_b_increments_from_post_a_version"

# =============================================================================
# Verify no conflict markers after worktree-b merge
# =============================================================================
echo ""
echo "--- test_no_conflict_markers_in_version_file_after_worktree_b ---"
_snapshot_fail

if _has_conflict_markers "$PLUGIN_JSON"; then
    AFTER_B_CONFLICT="yes"
else
    AFTER_B_CONFLICT="no"
fi
assert_eq "test_no_conflict_markers_in_version_file_after_worktree_b" "no" "$AFTER_B_CONFLICT"

assert_pass_if_clean "test_no_conflict_markers_in_version_file_after_worktree_b"

# =============================================================================
# Final assertion: two sequential merges produce exactly two patch increments
# above the baseline.  0.1.0 + 2 patches = 0.1.2
# =============================================================================
echo ""
echo "--- test_sequential_merges_produce_two_increments ---"
_snapshot_fail

FINAL_VERSION=$(_read_version "$PLUGIN_JSON")

# Behavioral assertion: final version is exactly two patch increments above baseline
assert_eq "test_sequential_merges_produce_two_increments" "0.1.2" "$FINAL_VERSION"

# Confirm baseline was where we started (so "two above 0.1.0" is verifiable)
assert_ne "test_final_version_differs_from_baseline" "$BASELINE_VERSION" "$FINAL_VERSION"

assert_pass_if_clean "test_sequential_merges_produce_two_increments"

echo ""
echo "Final version in $PLUGIN_JSON: $FINAL_VERSION"
echo "(Baseline: $BASELINE_VERSION  →  After worktree-a: $VERSION_AFTER_A  →  After worktree-b: $FINAL_VERSION)"

# =============================================================================
print_summary
