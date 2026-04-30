#!/usr/bin/env bash
# tests/skills/test-implementation-plan-visual-verification.sh
# Structural boundary test: implementation-plan SKILL.md must publish the
# requires_visual_verification token. Sprint and fix-bug consume this metadata
# field on task descriptions to decide whether a Playwright check is required.
#
# Per behavioral-testing-standard.md Rule 5: only the binding contract token
# (the field name) is asserted — heading text, UI patterns, and tool names
# are not binding callers and are not asserted.
#
# Story 2d82-f15f / ticket c621-a025
#
# Usage:
#   bash tests/skills/test-implementation-plan-visual-verification.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_FILE="$REPO_ROOT/plugins/dso/skills/implementation-plan/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-implementation-plan-visual-verification.sh ==="
echo ""

# ===========================================================================
# test_visual_verification_metadata_field_present
#
# Binding caller: sprint and fix-bug key on the requires_visual_verification
# metadata token in generated task descriptions. The literal token must appear
# in SKILL.md so task descriptions include it.
# ===========================================================================
test_visual_verification_metadata_field_present() {
  local _found=0
  grep -q 'requires_visual_verification' "$SKILL_FILE" && _found=1

  assert_eq \
    "test_visual_verification_metadata_field_present: SKILL.md must publish the requires_visual_verification token" \
    "1" "$_found"
}

test_visual_verification_metadata_field_present

print_summary
