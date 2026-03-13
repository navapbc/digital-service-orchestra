#!/usr/bin/env bash
# lockpick-workflow/tests/scripts/test-skip-review-check.sh
# Tests for lockpick-workflow/scripts/skip-review-check.sh extraction from COMMIT-WORKFLOW.md.
#
# Usage: bash lockpick-workflow/tests/scripts/test-skip-review-check.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CANONICAL_SCRIPT="$REPO_ROOT/lockpick-workflow/scripts/skip-review-check.sh"
WRAPPER_SCRIPT="$REPO_ROOT/scripts/skip-review-check.sh"
WORKFLOW_FILE="$REPO_ROOT/lockpick-workflow/docs/workflows/COMMIT-WORKFLOW.md"

source "$REPO_ROOT/lockpick-workflow/tests/lib/assert.sh"

echo "=== test-skip-review-check.sh ==="

# ── test_skip_review_check_script_exists_and_executable ─────────────────────
# The canonical script must exist and be executable.
_snapshot_fail
script_exists=0
{ test -x "$CANONICAL_SCRIPT"; } && script_exists=1
assert_eq "test_skip_review_check_script_exists_and_executable: canonical script is executable" "1" "$script_exists"
assert_pass_if_clean "test_skip_review_check_script_exists_and_executable"

# ── test_skip_review_check_wrapper_exists ────────────────────────────────────
# The backward-compat exec wrapper at scripts/ must exist.
_snapshot_fail
wrapper_exists=0
{ test -f "$WRAPPER_SCRIPT"; } && wrapper_exists=1
assert_eq "test_skip_review_check_wrapper_exists: scripts/ wrapper exists" "1" "$wrapper_exists"
assert_pass_if_clean "test_skip_review_check_wrapper_exists"

# ── test_skip_review_check_wrapper_delegates ─────────────────────────────────
# The wrapper must delegate to the canonical script (exec pattern).
_snapshot_fail
wrapper_delegates=0
grep -q 'lockpick-workflow/scripts/skip-review-check.sh' "$WRAPPER_SCRIPT" 2>/dev/null && wrapper_delegates=1
assert_eq "test_skip_review_check_wrapper_delegates: wrapper delegates to canonical" "1" "$wrapper_delegates"
assert_pass_if_clean "test_skip_review_check_wrapper_delegates"

# ── test_commit_workflow_references_skip_review_check ───────────────────────
# COMMIT-WORKFLOW.md must reference skip-review-check.sh.
_snapshot_fail
workflow_ref=0
grep -q 'skip-review-check\.sh' "$WORKFLOW_FILE" 2>/dev/null && workflow_ref=1
assert_eq "test_commit_workflow_references_skip_review_check: COMMIT-WORKFLOW.md references skip-review-check.sh" "1" "$workflow_ref"
assert_pass_if_clean "test_commit_workflow_references_skip_review_check"

# ── test_skip_review_check_tickets_only_exits_zero ───────────────────────────
# Script exits 0 when only non-reviewable files are passed (tickets and sync-state).
_snapshot_fail
tickets_exit=1
printf '.tickets/abc.md\n.sync-state.json\n' | bash "$CANONICAL_SCRIPT" 2>/dev/null && tickets_exit=0
assert_eq "test_skip_review_check_tickets_only_exits_zero: exits 0 for tickets-only files" "0" "$tickets_exit"
assert_pass_if_clean "test_skip_review_check_tickets_only_exits_zero"

# ── test_skip_review_check_code_file_exits_nonzero ───────────────────────────
# Script exits non-zero when reviewable files (code) are present.
_snapshot_fail
code_exit=0
printf 'app/src/main.py\n' | bash "$CANONICAL_SCRIPT" 2>/dev/null && code_exit=0 || code_exit=$?
# We want non-zero — if it returns 0 that means incorrectly skipping review
reviewable_nonzero=0
{ printf 'app/src/main.py\n' | bash "$CANONICAL_SCRIPT" 2>/dev/null; test $? -ne 0; } && reviewable_nonzero=1
assert_eq "test_skip_review_check_code_file_exits_nonzero: exits non-zero for code files" "1" "$reviewable_nonzero"
assert_pass_if_clean "test_skip_review_check_code_file_exits_nonzero"

# ── test_skip_review_check_safeguard_files_exits_nonzero ─────────────────────
# Safeguard files (.claude/skills/*) must require review even though docs/* is exempt.
_snapshot_fail
safeguard_nonzero=0
{ printf '.claude/skills/my-skill.md\n' | bash "$CANONICAL_SCRIPT" 2>/dev/null; test $? -ne 0; } && safeguard_nonzero=1
assert_eq "test_skip_review_check_safeguard_files_exits_nonzero: safeguard files require review" "1" "$safeguard_nonzero"
assert_pass_if_clean "test_skip_review_check_safeguard_files_exits_nonzero"

# ── test_skip_review_check_image_files_exits_zero ────────────────────────────
# Image files should skip review.
_snapshot_fail
image_exit=1
printf 'docs/screenshot.png\n' | bash "$CANONICAL_SCRIPT" 2>/dev/null && image_exit=0
assert_eq "test_skip_review_check_image_files_exits_zero: image files skip review" "0" "$image_exit"
assert_pass_if_clean "test_skip_review_check_image_files_exits_zero"

# ── test_skip_review_check_claude_md_exits_nonzero ───────────────────────────
# CLAUDE.md must require review.
_snapshot_fail
claude_md_nonzero=0
{ printf 'CLAUDE.md\n' | bash "$CANONICAL_SCRIPT" 2>/dev/null; test $? -ne 0; } && claude_md_nonzero=1
assert_eq "test_skip_review_check_claude_md_exits_nonzero: CLAUDE.md requires review" "1" "$claude_md_nonzero"
assert_pass_if_clean "test_skip_review_check_claude_md_exits_nonzero"

print_summary
