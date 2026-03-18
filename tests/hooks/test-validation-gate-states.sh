#!/usr/bin/env bash
# tests/hooks/test-validation-gate-states.sh
# Validates that hook_validation_gate has been fully removed from pre-bash-functions.sh.
#
# This test previously tested hook_validation_gate behavioral states. The function
# was removed as part of the validation gate refactoring (validation-gate logic
# moved to validate.sh state files). See test-validation-gate-removed.sh for the
# comprehensive removal checks.
#
# Usage: bash tests/hooks/test-validation-gate-states.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(git rev-parse --show-toplevel)"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo ""
echo "=== test-validation-gate-states.sh ==="

echo ""
echo "=== Group 1: hook_validation_gate removed ==="

# Verify the function is no longer defined after sourcing pre-bash-functions.sh
_snapshot_fail
source "$DSO_PLUGIN_DIR/hooks/lib/pre-bash-functions.sh"
if type hook_validation_gate &>/dev/null; then
    actual_defined="still_defined"
else
    actual_defined="removed"
fi
assert_eq "hook_validation_gate is removed from pre-bash-functions.sh" "removed" "$actual_defined"
assert_pass_if_clean "hook_validation_gate is removed from pre-bash-functions.sh"

# Verify no references to the function in the hooks lib directory
_snapshot_fail
refs_in_hooks=$(grep -r 'hook_validation_gate' "$DSO_PLUGIN_DIR/hooks/" 2>/dev/null | grep -v '^\s*#' | wc -l | tr -d ' ')
assert_eq "no non-comment references to hook_validation_gate in hooks/" "0" "$refs_in_hooks"
assert_pass_if_clean "no non-comment references to hook_validation_gate in hooks/"

# Verify no dispatcher calls the function
_snapshot_fail
dispatcher_refs=$(grep -r 'hook_validation_gate' "$DSO_PLUGIN_DIR/hooks/dispatchers/" 2>/dev/null | wc -l | tr -d ' ')
assert_eq "no dispatcher references to hook_validation_gate" "0" "$dispatcher_refs"
assert_pass_if_clean "no dispatcher references to hook_validation_gate"

print_summary
