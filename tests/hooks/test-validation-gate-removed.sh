#!/usr/bin/env bash
# lockpick-workflow/tests/hooks/test-validation-gate-removed.sh
# Verifies that hook_validation_gate has been fully removed from all dispatchers
# and function libraries.

set -euo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
HOOKS_DIR="$REPO_ROOT/lockpick-workflow/hooks"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo ""
echo "=== Test: hook_validation_gate removed from all dispatchers ==="

# Test 1: No references to hook_validation_gate in hooks/ (excluding tests)
REFS=$(grep -rn 'hook_validation_gate' "$HOOKS_DIR/" \
    --include='*.sh' \
    | grep -v 'test-validation-gate-removed' \
    | grep -v 'test-validation-gate.sh' \
    || true)
assert_eq "No references to hook_validation_gate in hooks/" "" "$REFS"

# Test 2: Function not defined after sourcing pre-bash-functions.sh
FUNC_CHECK=$(bash -c "source '$HOOKS_DIR/lib/pre-bash-functions.sh' && type hook_validation_gate" 2>&1 || true)
assert_contains "hook_validation_gate not defined in pre-bash-functions.sh" \
    "not found" "$FUNC_CHECK"

# Test 3: Function not exposed via pre-edit-write-functions.sh
FUNC_CHECK2=$(bash -c "source '$HOOKS_DIR/lib/pre-edit-write-functions.sh' && type hook_validation_gate" 2>&1 || true)
assert_contains "hook_validation_gate not exposed via pre-edit-write-functions.sh" \
    "not found" "$FUNC_CHECK2"

# Test 4: pre-bash.sh dispatch loop does not contain hook_validation_gate
DISPATCH_REF=$(grep 'hook_validation_gate' "$HOOKS_DIR/dispatchers/pre-bash.sh" || true)
assert_eq "pre-bash.sh dispatch loop clean" "" "$DISPATCH_REF"

# Test 5: pre-edit.sh dispatch loop does not contain hook_validation_gate
EDIT_REF=$(grep 'hook_validation_gate' "$HOOKS_DIR/dispatchers/pre-edit.sh" || true)
assert_eq "pre-edit.sh dispatch loop clean" "" "$EDIT_REF"

# Test 6: pre-write.sh dispatch loop does not contain hook_validation_gate
WRITE_REF=$(grep 'hook_validation_gate' "$HOOKS_DIR/dispatchers/pre-write.sh" || true)
assert_eq "pre-write.sh dispatch loop clean" "" "$WRITE_REF"

# Test 7: Old test file deleted
if [[ -f "$REPO_ROOT/lockpick-workflow/tests/hooks/test-validation-gate.sh" ]]; then
    (( ++FAIL ))
    echo "FAIL: Old test file test-validation-gate.sh still exists" >&2
else
    (( ++PASS ))
fi

# Test 8: Header comments updated (no mention of hook_validation_gate)
PRE_BASH_HEADER=$(head -20 "$HOOKS_DIR/dispatchers/pre-bash.sh" | grep 'validation_gate' || true)
assert_eq "pre-bash.sh header clean" "" "$PRE_BASH_HEADER"

PRE_EDIT_HEADER=$(head -20 "$HOOKS_DIR/dispatchers/pre-edit.sh" | grep 'validation_gate' || true)
assert_eq "pre-edit.sh header clean" "" "$PRE_EDIT_HEADER"

PRE_WRITE_HEADER=$(head -20 "$HOOKS_DIR/dispatchers/pre-write.sh" | grep 'validation_gate' || true)
assert_eq "pre-write.sh header clean" "" "$PRE_WRITE_HEADER"

FUNCTIONS_HEADER=$(head -25 "$HOOKS_DIR/lib/pre-edit-write-functions.sh" | grep 'validation_gate' || true)
assert_eq "pre-edit-write-functions.sh header clean" "" "$FUNCTIONS_HEADER"

BASH_FUNCTIONS_HEADER=$(head -25 "$HOOKS_DIR/lib/pre-bash-functions.sh" | grep 'validation_gate' || true)
assert_eq "pre-bash-functions.sh header clean" "" "$BASH_FUNCTIONS_HEADER"

# Test 9: Standalone validation-gate.sh wrapper removed or cleaned
if [[ -f "$HOOKS_DIR/validation-gate.sh" ]]; then
    VG_REF=$(grep 'hook_validation_gate' "$HOOKS_DIR/validation-gate.sh" || true)
    assert_eq "validation-gate.sh does not call hook_validation_gate" "" "$VG_REF"
fi

print_summary
