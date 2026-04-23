#!/usr/bin/env bash
# tests/skills/test-brainstorm-tag-writer.sh
# Tests for the Phase 3 tag-write step in plugins/dso/skills/brainstorm/SKILL.md.
#
# Validates:
#   test_phase3_tag_write_step_exists — structural: ### Step 3a: heading exists between
#       ### Step 3: Validate Ticket Health and ### Step 3b: Write Brainstorm Completion Sentinel
#       RED — fails before the GREEN task adds Step 3a to SKILL.md
#
# Usage: bash tests/skills/test-brainstorm-tag-writer.sh
# Returns: exit 0 if all assertions pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SKILL_MD="$REPO_ROOT/plugins/dso/skills/brainstorm/SKILL.md"

source "$REPO_ROOT/tests/lib/assert.sh"

echo "=== test-brainstorm-tag-writer.sh ==="

# ---------------------------------------------------------------------------
# test_phase3_tag_write_step_exists
# Structural boundary test: ### Step 3a: must appear in SKILL.md between
# ### Step 3: Validate Ticket Health and ### Step 3b: Write Brainstorm Completion Sentinel.
#
# RED — this test fails before Task 2 adds the Step 3a heading.
# ---------------------------------------------------------------------------
test_phase3_tag_write_step_exists() {
    _snapshot_fail
    local step3_line step3b_line step3a_line result
    step3_line=$(grep -n "^### Step 3: Validate Ticket Health" "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1)
    step3b_line=$(grep -n "^### Step 3b: Write Brainstorm Completion Sentinel" "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1)
    step3a_line=$(grep -n "^### Step 3a:" "$SKILL_MD" 2>/dev/null | head -1 | cut -d: -f1)

    result="missing"
    if [[ -n "$step3_line" && -n "$step3b_line" && -n "$step3a_line" ]]; then
        if [[ "$step3a_line" -gt "$step3_line" && "$step3a_line" -lt "$step3b_line" ]]; then
            result="found"
        fi
    fi
    assert_eq "test_phase3_tag_write_step_exists" "found" "$result"
    assert_pass_if_clean "test_phase3_tag_write_step_exists"
}

# --- run tests ---
test_phase3_tag_write_step_exists

print_summary
