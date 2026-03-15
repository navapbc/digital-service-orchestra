#!/usr/bin/env bash
# lockpick-workflow/tests/skills/test-end-session-sentinel-write.sh
# Tests for Step 3.25 sentinel write in lockpick-workflow/skills/end-session/SKILL.md
#
# Validates that:
#   1. Step 3.25 heading exists in the skill file
#   2. sentinel write (touch .disable-precompact-checkpoint) appears in Step 3.25 section,
#      before Step 4 merge section
#   3. a session-scoped safety note exists in the skill file
#   4. sentinel cleanup (rm -f .disable-precompact-checkpoint) does NOT appear in Step 3.25
#      section (cleanup belongs in Step 4.75)
#
# Usage: bash lockpick-workflow/tests/skills/test-end-session-sentinel-write.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SKILL_FILE="$REPO_ROOT/lockpick-workflow/skills/end-session/SKILL.md"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-end-session-sentinel-write.sh ==="

# ---------------------------------------------------------------------------
# test_end_skill_sentinel_write_before_merge
# Validates all four sentinel-write requirements in the skill file.
# ---------------------------------------------------------------------------
_snapshot_fail

# (1) Step 3.25 heading exists
heading_found="no"
if grep -q '### 3\.25\.' "$SKILL_FILE" 2>/dev/null; then
    heading_found="yes"
fi
assert_eq "test_end_skill_sentinel_write_before_merge__step_375_heading_exists" "yes" "$heading_found"

# (2) sentinel write (touch .disable-precompact-checkpoint) appears in Step 3.25 section,
#     before Step 4 merge section (Step 4 heading is "### 4. Sync Tickets")
sentinel_write_before_merge="no"
if awk '/touch.*disable-precompact-checkpoint/{p=NR} /### 4\. /{q=NR} END{exit (p>0 && q>0 && p<q) ? 0 : 1}' "$SKILL_FILE" 2>/dev/null; then
    sentinel_write_before_merge="yes"
fi
assert_eq "test_end_skill_sentinel_write_before_merge__touch_before_step4" "yes" "$sentinel_write_before_merge"

# (3) a note about session-scoped safety exists (safe to delete manually if /end interrupted)
safety_note_found="no"
if grep -qE 'session-scoped|safe to delete manually|interrupted' "$SKILL_FILE" 2>/dev/null; then
    safety_note_found="yes"
fi
assert_eq "test_end_skill_sentinel_write_before_merge__safety_note_exists" "yes" "$safety_note_found"

# (4) rm -f .disable-precompact-checkpoint does NOT appear in the Step 3.25 section
#     (cleanup belongs in Step 4.75, owned by a different task)
cleanup_in_375="no"
if awk '/### 3\.25\./,/### 4\./' "$SKILL_FILE" 2>/dev/null | grep -q 'rm -f.*disable-precompact'; then
    cleanup_in_375="yes"
fi
assert_eq "test_end_skill_sentinel_write_before_merge__no_cleanup_in_375" "no" "$cleanup_in_375"

assert_pass_if_clean "test_end_skill_sentinel_write_before_merge"

print_summary
