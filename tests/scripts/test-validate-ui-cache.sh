#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-validate-ui-cache.sh
# TDD tests for validate-ui-cache.sh extraction from ui-discover/SKILL.md:
#   1. lockpick-workflow/scripts/validate-ui-cache.sh exists and is executable
#   2. scripts/validate-ui-cache.sh wrapper exists and delegates to canonical
#   3. ui-discover/SKILL.md inline block replaced with a one-liner
#   4. All 6 cache validation steps present in the extracted script
#
# Usage: bash lockpick-workflow/tests/scripts/test-validate-ui-cache.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
CANONICAL_SCRIPT="$PLUGIN_ROOT/scripts/validate-ui-cache.sh"
WRAPPER_SCRIPT="$REPO_ROOT/scripts/validate-ui-cache.sh"
SKILL_FILE="$PLUGIN_ROOT/skills/ui-discover/SKILL.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

echo "=== test-validate-ui-cache.sh ==="

# ── test_canonical_script_exists ─────────────────────────────────────────────
# lockpick-workflow/scripts/validate-ui-cache.sh must exist
_snapshot_fail
if [[ -f "$CANONICAL_SCRIPT" ]]; then
    assert_eq "test_canonical_script_exists: file exists" "yes" "yes"
else
    assert_eq "test_canonical_script_exists: file exists" "yes" "no"
fi
assert_pass_if_clean "test_canonical_script_exists"

# ── test_canonical_script_is_executable ──────────────────────────────────────
# lockpick-workflow/scripts/validate-ui-cache.sh must be executable
_snapshot_fail
if [[ -x "$CANONICAL_SCRIPT" ]]; then
    assert_eq "test_canonical_script_is_executable: executable" "yes" "yes"
else
    assert_eq "test_canonical_script_is_executable: executable" "yes" "no"
fi
assert_pass_if_clean "test_canonical_script_is_executable"

# ── test_wrapper_script_exists ────────────────────────────────────────────────
# scripts/validate-ui-cache.sh backward-compat exec wrapper must exist
_snapshot_fail
if [[ -f "$WRAPPER_SCRIPT" ]]; then
    assert_eq "test_wrapper_script_exists: file exists" "yes" "yes"
else
    assert_eq "test_wrapper_script_exists: file exists" "yes" "no"
fi
assert_pass_if_clean "test_wrapper_script_exists"

# ── test_wrapper_delegates_to_canonical ──────────────────────────────────────
# scripts/validate-ui-cache.sh must reference the canonical script path
_snapshot_fail
if grep -q 'lockpick-workflow/scripts/validate-ui-cache.sh' "$WRAPPER_SCRIPT" 2>/dev/null; then
    assert_eq "test_wrapper_delegates_to_canonical: references canonical path" "yes" "yes"
else
    assert_eq "test_wrapper_delegates_to_canonical: references canonical path" "yes" "no"
fi
assert_pass_if_clean "test_wrapper_delegates_to_canonical"

# ── test_skill_references_script ─────────────────────────────────────────────
# SKILL.md must contain a reference to validate-ui-cache.sh
_snapshot_fail
if grep -q 'validate-ui-cache.sh' "$SKILL_FILE" 2>/dev/null; then
    assert_eq "test_skill_references_script: SKILL.md references script" "yes" "yes"
else
    assert_eq "test_skill_references_script: SKILL.md references script" "yes" "no"
fi
assert_pass_if_clean "test_skill_references_script"

# ── test_inline_block_removed ─────────────────────────────────────────────────
# The 173-line inline bash block must NOT be present verbatim in SKILL.md
# (checking for the CACHED_COMMIT=.*SHORT_SHA placeholder which is unique to the block)
_snapshot_fail
if grep -q 'CACHED_COMMIT=.*SHORT_SHA' "$SKILL_FILE" 2>/dev/null; then
    assert_eq "test_inline_block_removed: CACHED_COMMIT placeholder absent in SKILL.md" "absent" "present"
else
    assert_eq "test_inline_block_removed: CACHED_COMMIT placeholder absent in SKILL.md" "absent" "absent"
fi
assert_pass_if_clean "test_inline_block_removed"

# ── test_all_six_steps_present ────────────────────────────────────────────────
# The extracted script must contain all 6 cache validation steps
_snapshot_fail
all_steps_present=true
for step in 'Step 1' 'Step 2' 'Step 3' 'Step 4' 'Step 5' 'Step 6'; do
    if grep -q "$step" "$CANONICAL_SCRIPT" 2>/dev/null; then
        : # step found
    else
        all_steps_present=false
        printf "FAIL: step '%s' not found in %s\n" "$step" "$CANONICAL_SCRIPT" >&2
        (( ++FAIL ))
    fi
done
if $all_steps_present; then
    assert_eq "test_all_six_steps_present: all steps found" "yes" "yes"
fi
assert_pass_if_clean "test_all_six_steps_present"

# ── test_canonical_has_shebang ────────────────────────────────────────────────
# The canonical script must have a proper bash shebang
_snapshot_fail
if head -1 "$CANONICAL_SCRIPT" 2>/dev/null | grep -q '#!/usr/bin/env bash'; then
    assert_eq "test_canonical_has_shebang: has bash shebang" "yes" "yes"
else
    assert_eq "test_canonical_has_shebang: has bash shebang" "yes" "no"
fi
assert_pass_if_clean "test_canonical_has_shebang"

print_summary
