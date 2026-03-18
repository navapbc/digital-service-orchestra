#!/usr/bin/env bash
# tests/scripts/test-skip-review-check.sh
# Tests for scripts/skip-review-check.sh extraction from COMMIT-WORKFLOW.md.
#
# Usage: bash tests/scripts/test-skip-review-check.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DSO_PLUGIN_DIR="$PLUGIN_ROOT/plugins/dso"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
CANONICAL_SCRIPT="$DSO_PLUGIN_DIR/scripts/skip-review-check.sh"
WRAPPER_SCRIPT="$DSO_PLUGIN_DIR/scripts/skip-review-check.sh"
WORKFLOW_FILE="$DSO_PLUGIN_DIR/docs/workflows/COMMIT-WORKFLOW.md"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

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
grep -q 'scripts/skip-review-check.sh' "$WRAPPER_SCRIPT" 2>/dev/null && wrapper_delegates=1
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

# ── test_skip_review_check_reads_from_allowlist ──────────────────────────────
# The script must read classification patterns from the shared allowlist file.
_snapshot_fail

# Sub-test 1: .tickets/ file → exit 0 (allowlist covers it)
allowlist_tickets=1
printf '.tickets/some-ticket.md\n' | bash "$CANONICAL_SCRIPT" 2>/dev/null && allowlist_tickets=0
assert_eq "test_skip_review_check_reads_from_allowlist: .tickets/ file exits 0" "0" "$allowlist_tickets"

# Sub-test 2: docs/ file → exit 0 (allowlist covers it)
allowlist_docs=1
printf 'docs/architecture.md\n' | bash "$CANONICAL_SCRIPT" 2>/dev/null && allowlist_docs=0
assert_eq "test_skip_review_check_reads_from_allowlist: docs/ file exits 0" "0" "$allowlist_docs"

# Sub-test 3: *.png file → exit 0 (allowlist covers it)
allowlist_png=1
printf 'assets/image.png\n' | bash "$CANONICAL_SCRIPT" 2>/dev/null && allowlist_png=0
assert_eq "test_skip_review_check_reads_from_allowlist: *.png file exits 0" "0" "$allowlist_png"

# Sub-test 4: src/main.py → exit 1 (not in allowlist)
allowlist_code_nonzero=0
{ printf 'src/main.py\n' | bash "$CANONICAL_SCRIPT" 2>/dev/null; test $? -ne 0; } && allowlist_code_nonzero=1
assert_eq "test_skip_review_check_reads_from_allowlist: src/main.py exits 1" "1" "$allowlist_code_nonzero"

# Sub-test 5: script references the allowlist file
allowlist_ref=0
grep -q 'review-gate-allowlist' "$CANONICAL_SCRIPT" 2>/dev/null && allowlist_ref=1
assert_eq "test_skip_review_check_reads_from_allowlist: script references allowlist" "1" "$allowlist_ref"

assert_pass_if_clean "test_skip_review_check_reads_from_allowlist"

# ── test_skip_review_check_allowlist_graceful_degradation ────────────────────
# When the allowlist file is missing, the script must still work (fallback).
_snapshot_fail
fallback_exit=1
printf '.tickets/x.md\n' | ALLOWLIST_OVERRIDE=/tmp/nonexistent-allowlist-$$ bash "$CANONICAL_SCRIPT" 2>/dev/null && fallback_exit=0
assert_eq "test_skip_review_check_allowlist_graceful_degradation: falls back when allowlist missing" "0" "$fallback_exit"
assert_pass_if_clean "test_skip_review_check_allowlist_graceful_degradation"

# ── test_skip_review_check_allowlist_behavioral_equivalence ──────────────────
# All previously-hardcoded patterns must produce the same classification result
# when driven from the allowlist. This ensures no silent regression.
_snapshot_fail

# Files that should skip review (exit 0) — matching old hardcoded patterns
equiv_pass=1
for f in \
    ".tickets/abc.md" \
    ".sync-state.json" \
    "screenshot.png" \
    "photo.jpg" \
    "photo.jpeg" \
    "anim.gif" \
    "icon.svg" \
    "favicon.ico" \
    "hero.webp" \
    "manual.pdf" \
    "report.docx" \
    ".claude/session-logs/2024-01-01.log" \
    ".claude/docs/GUIDE.md" \
    "docs/README.md"; do
    printf '%s\n' "$f" | bash "$CANONICAL_SCRIPT" 2>/dev/null
    if [[ $? -ne 0 ]]; then
        equiv_pass=0
        echo "  regression: $f should skip review but got exit 1" >&2
    fi
done
assert_eq "test_skip_review_check_allowlist_behavioral_equivalence: all non-reviewable files skip review" "1" "$equiv_pass"

# Files that should require review (exit 1) — safeguards + code
equiv_block=1
for f in \
    "CLAUDE.md" \
    "hooks/some-hook.sh" \
    "skills/my-skill.md" \
    "docs/workflows/WF.md" \
    ".claude/hooks/hook.sh" \
    "app/src/main.py"; do
    printf '%s\n' "$f" | bash "$CANONICAL_SCRIPT" 2>/dev/null
    if [[ $? -eq 0 ]]; then
        equiv_block=0
        echo "  regression: $f should require review but got exit 0" >&2
    fi
done
assert_eq "test_skip_review_check_allowlist_behavioral_equivalence: all reviewable files require review" "1" "$equiv_block"

assert_pass_if_clean "test_skip_review_check_allowlist_behavioral_equivalence"

print_summary
