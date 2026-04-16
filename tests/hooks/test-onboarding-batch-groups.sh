#!/usr/bin/env bash
# tests/hooks/test-onboarding-batch-groups.sh
# Structural boundary test for batch group headers in onboarding SKILL.md.
#
# Per Behavioral Testing Standard Rule 5, this tests the structural interface
# contract of the onboarding skill — not its content. The batch group section
# headers (## Batch Group N: <name>) are the deterministic interface that agents
# and orchestrators use to locate and dispatch batch groups.
#
# What we test (structural boundary):
#   - Exactly 6 batch group headers exist (## Batch Group N:)
#   - Each header has a non-empty name after the colon
#   - No duplicate batch group names
#
# What we do NOT test (content assertions prohibited by Rule 5):
#   - The specific names of the batch groups
#   - The content or instructions within each group
#   - The ordering of phases within a batch group
#
# Usage:
#   bash tests/hooks/test-onboarding-batch-groups.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$PLUGIN_ROOT/plugins/dso/skills/onboarding/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-onboarding-batch-groups.sh ==="

# ===========================================================================
# test_onboarding_skill_file_exists
# The SKILL.md must exist before any structural checks can run.
# ===========================================================================
echo "--- test_onboarding_skill_file_exists ---"
if [[ -f "$SKILL_FILE" ]]; then
    assert_eq "test_onboarding_skill_file_exists: SKILL.md exists" "present" "present"
else
    assert_eq "test_onboarding_skill_file_exists: SKILL.md exists" "present" "missing"
    print_summary
    exit 1
fi

# ===========================================================================
# test_onboarding_has_exactly_6_batch_groups
# The SKILL.md must define exactly 6 batch groups via "## Batch Group N:"
# headers. Structural: agents locate batch groups by scanning for this header
# pattern — the count defines the execution contract.
# ===========================================================================
echo "--- test_onboarding_has_exactly_6_batch_groups ---"
_batch_group_count=$(grep -c "^## Batch Group [0-9]\+:" "$SKILL_FILE" 2>/dev/null || echo 0)
assert_eq "test_onboarding_has_exactly_6_batch_groups: exactly 6 batch group headers" "6" "$_batch_group_count"

# ===========================================================================
# test_onboarding_batch_group_names_non_empty
# Each batch group header must have a non-empty name after the colon.
# Structural: the name is used for display and logging — an empty name
# produces degenerate output that is hard to diagnose.
# ===========================================================================
echo "--- test_onboarding_batch_group_names_non_empty ---"
_empty_name_count=0
while IFS= read -r line; do
    # Extract everything after "## Batch Group N:" and trim whitespace
    _name="${line#*:}"
    _name="${_name#"${_name%%[![:space:]]*}"}"  # ltrim
    _name="${_name%"${_name##*[![:space:]]}"}"  # rtrim
    if [[ -z "$_name" ]]; then
        (( ++_empty_name_count ))
    fi
done < <(grep "^## Batch Group [0-9]\+:" "$SKILL_FILE" 2>/dev/null)
assert_eq "test_onboarding_batch_group_names_non_empty: all batch group headers have non-empty names" "0" "$_empty_name_count"

# ===========================================================================
# test_onboarding_batch_group_names_unique
# No two batch group headers may share the same name. Structural: duplicate
# names cause ambiguity when agents reference a group by name for dispatch
# or status reporting.
# ===========================================================================
echo "--- test_onboarding_batch_group_names_unique ---"
_names_raw=$(grep "^## Batch Group [0-9]\+:" "$SKILL_FILE" 2>/dev/null | sed 's/^## Batch Group [0-9]*: *//' | sed 's/[[:space:]]*$//')
_total_names=$(echo "$_names_raw" | grep -c '.' 2>/dev/null || echo 0)
_unique_names=$(echo "$_names_raw" | sort -u | grep -c '.' 2>/dev/null || echo 0)
assert_eq "test_onboarding_batch_group_names_unique: no duplicate batch group names" "$_total_names" "$_unique_names"

print_summary
