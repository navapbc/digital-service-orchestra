#!/usr/bin/env bash
# lockpick-workflow/tests/skills/test-design-review-config-ref.sh
# Tests that design-review SKILL.md references design.design_notes_path from config
#
# Validates:
#   - SKILL.md contains read-config.sh reference for design_notes_path
#   - SKILL.md references design.design_notes_path config key
#   - .claude/skills/design-review is a symlink to lockpick-workflow/skills/design-review
#
# Usage: bash lockpick-workflow/tests/skills/test-design-review-config-ref.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
SKILL_MD="$REPO_ROOT/lockpick-workflow/skills/design-review/SKILL.md"
SYMLINK_PATH="$REPO_ROOT/.claude/skills/design-review"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-design-review-config-ref.sh ==="

# test_skill_md_exists: SKILL.md must exist
_fail_before=$FAIL
if [[ -f "$SKILL_MD" ]]; then
    skill_exists="exists"
else
    skill_exists="missing"
fi
assert_eq "test_skill_md_exists" "exists" "$skill_exists"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_skill_md_exists ... PASS"
fi

# test_skill_references_read_config: SKILL.md must reference read-config.sh
_fail_before=$FAIL
if grep -q "read-config" "$SKILL_MD" 2>/dev/null; then
    has_read_config="has_read_config"
else
    has_read_config="missing_read_config"
fi
assert_eq "test_skill_references_read_config" "has_read_config" "$has_read_config"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_skill_references_read_config ... PASS"
fi

# test_skill_references_design_notes_path: SKILL.md must reference design.design_notes_path
_fail_before=$FAIL
if grep -q "design.design_notes_path\|design_notes_path" "$SKILL_MD" 2>/dev/null; then
    has_dnp="has_design_notes_path"
else
    has_dnp="missing_design_notes_path"
fi
assert_eq "test_skill_references_design_notes_path" "has_design_notes_path" "$has_dnp"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_skill_references_design_notes_path ... PASS"
fi

# test_symlink_exists: .claude/skills/design-review must be a symlink
_fail_before=$FAIL
if [[ -L "$SYMLINK_PATH" ]]; then
    is_symlink="is_symlink"
else
    is_symlink="not_symlink"
fi
assert_eq "test_symlink_exists" "is_symlink" "$is_symlink"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_symlink_exists ... PASS"
fi

# test_symlink_target: symlink must point to lockpick-workflow/skills/design-review
_fail_before=$FAIL
symlink_target=$(readlink "$SYMLINK_PATH" 2>/dev/null || echo "no_target")
assert_eq "test_symlink_target" "../../lockpick-workflow/skills/design-review" "$symlink_target"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_symlink_target ... PASS"
fi

# test_no_project_level_duplicate: .claude/skills/design-review must NOT be a real directory
_fail_before=$FAIL
if [[ -L "$SYMLINK_PATH" ]]; then
    not_real_dir="symlink"
elif [[ -d "$SYMLINK_PATH" ]]; then
    not_real_dir="real_directory"
else
    not_real_dir="missing"
fi
assert_eq "test_no_project_level_duplicate" "symlink" "$not_real_dir"
if [[ "$FAIL" -eq "$_fail_before" ]]; then
    echo "test_no_project_level_duplicate ... PASS"
fi

print_summary
