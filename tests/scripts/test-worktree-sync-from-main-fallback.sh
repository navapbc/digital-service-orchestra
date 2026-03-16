#!/usr/bin/env bash
# tests/scripts/test-worktree-sync-from-main-fallback.sh
# TDD tests for the tickets-only conflict guard and fallback auto-resolve logic
# in scripts/worktree-sync-from-main.sh.
#
# Tests:
#   1. test_fallback_guard_non_ticket_conflict — guard aborts when a non-ticket
#      file (e.g., src/foo.py) is also conflicted; asserts exit 1 + no MERGE_AUTO_RESOLVE
#   2. test_fallback_resolves_tickets_only_conflict — tickets-only conflict is
#      auto-resolved via merge-ticket-index.py; asserts exit 0 + MERGE_AUTO_RESOLVE emitted
#   3. test_fallback_aborts_when_index_json_missing — if only .tickets/foo.md is
#      conflicted (not .tickets/.index.json), fallback aborts and returns 1
#   4. test_static_merge_auto_resolve_emit — static check: script emits MERGE_AUTO_RESOLVE
#   5. test_static_layer_fallback_string — static check: layer=fallback present in script
#   6. test_static_tickets_path_guard — static check: .tickets/ guard present in script
#   7. test_static_merge_abort_present — static check: git merge --abort present
#   8. test_static_reset_head_present — static check: git reset HEAD cleanup present
#   9. test_static_index_json_check — static check: .index.json or .index referenced
#   10. test_static_merge_ticket_index_called — static check: merge-ticket-index called
#   11. test_static_git_show_merge_head — static check: git show MERGE_HEAD used for temp files
#   12. test_static_syntax_ok — bash -n syntax check
#   13. test_script_is_executable — file permissions
#   14. test_fallback_aborts_mixed_ticket_conflicts — guard aborts when both
#       .tickets/.index.json and .tickets/foo.md are conflicted
#
# Usage: bash tests/scripts/test-worktree-sync-from-main-fallback.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR" && git rev-parse --show-toplevel)"
SYNC_SCRIPT="$PLUGIN_ROOT/scripts/worktree-sync-from-main.sh"

source "$SCRIPT_DIR/../lib/assert.sh"

echo "=== test-worktree-sync-from-main-fallback.sh ==="
echo ""

# =============================================================================
# Static checks (fast — no git repo setup needed)
# =============================================================================

# Test 12: bash -n syntax check
echo "Test 12: bash syntax check"
SYNTAX_OK=0
bash -n "$SYNC_SCRIPT" 2>/dev/null && SYNTAX_OK=1
assert_eq "test_static_syntax_ok" "1" "$SYNTAX_OK"
[ "$SYNTAX_OK" -eq 1 ] && echo "  PASS: syntax ok" || echo "  FAIL: syntax error in $SYNC_SCRIPT" >&2

# Test 13: script is executable
echo "Test 13: script is executable"
EXEC_OK=0
[ -x "$SYNC_SCRIPT" ] && EXEC_OK=1
assert_eq "test_script_is_executable" "1" "$EXEC_OK"
[ "$EXEC_OK" -eq 1 ] && echo "  PASS: script is executable" || echo "  FAIL: script is not executable" >&2

# Test 4: MERGE_AUTO_RESOLVE emitted
echo "Test 4: MERGE_AUTO_RESOLVE string present in script"
HAS_MERGE_AUTO_RESOLVE=$(grep -c 'MERGE_AUTO_RESOLVE' "$SYNC_SCRIPT" || true)
assert_ne "test_static_merge_auto_resolve_emit" "0" "$HAS_MERGE_AUTO_RESOLVE"
[ "$HAS_MERGE_AUTO_RESOLVE" -gt 0 ] && echo "  PASS: MERGE_AUTO_RESOLVE found" || echo "  FAIL: MERGE_AUTO_RESOLVE missing" >&2

# Test 5: layer=fallback string present
echo "Test 5: layer=fallback string present in script"
HAS_LAYER_FALLBACK=$(grep -c 'layer=fallback' "$SYNC_SCRIPT" || true)
assert_ne "test_static_layer_fallback_string" "0" "$HAS_LAYER_FALLBACK"
[ "$HAS_LAYER_FALLBACK" -gt 0 ] && echo "  PASS: layer=fallback found" || echo "  FAIL: layer=fallback missing" >&2

# Test 6: .tickets/ guard present
echo "Test 6: .tickets/ guard present in script"
HAS_TICKETS_GUARD=$(grep -c '\.tickets/' "$SYNC_SCRIPT" || true)
assert_ne "test_static_tickets_path_guard" "0" "$HAS_TICKETS_GUARD"
[ "$HAS_TICKETS_GUARD" -gt 0 ] && echo "  PASS: .tickets/ guard found" || echo "  FAIL: .tickets/ guard missing" >&2

# Test 7: git merge --abort present
echo "Test 7: git merge --abort present in script"
HAS_MERGE_ABORT=$(grep -c 'git merge --abort' "$SYNC_SCRIPT" || true)
assert_ne "test_static_merge_abort_present" "0" "$HAS_MERGE_ABORT"
[ "$HAS_MERGE_ABORT" -gt 0 ] && echo "  PASS: git merge --abort found" || echo "  FAIL: git merge --abort missing" >&2

# Test 8: git reset HEAD cleanup present
echo "Test 8: git reset HEAD (or --mixed HEAD) cleanup present"
HAS_RESET_HEAD=$(grep -cE 'git reset HEAD|git reset --mixed HEAD' "$SYNC_SCRIPT" || true)
assert_ne "test_static_reset_head_present" "0" "$HAS_RESET_HEAD"
[ "$HAS_RESET_HEAD" -gt 0 ] && echo "  PASS: git reset HEAD found" || echo "  FAIL: git reset HEAD missing" >&2

# Test 9: .index.json or .index referenced
echo "Test 9: .index.json (or .index) referenced in script"
HAS_INDEX_JSON=$(grep -cE '\.index\.json|\.index' "$SYNC_SCRIPT" || true)
assert_ne "test_static_index_json_check" "0" "$HAS_INDEX_JSON"
[ "$HAS_INDEX_JSON" -gt 0 ] && echo "  PASS: .index.json referenced" || echo "  FAIL: .index.json not referenced" >&2

# Test 10: merge-ticket-index called
echo "Test 10: merge-ticket-index called in script"
HAS_MERGE_TICKET_INDEX=$(grep -c 'merge-ticket-index' "$SYNC_SCRIPT" || true)
assert_ne "test_static_merge_ticket_index_called" "0" "$HAS_MERGE_TICKET_INDEX"
[ "$HAS_MERGE_TICKET_INDEX" -gt 0 ] && echo "  PASS: merge-ticket-index called" || echo "  FAIL: merge-ticket-index not called" >&2

# Test 11: git show MERGE_HEAD used for temp files
echo "Test 11: git show MERGE_HEAD used for temp file extraction"
HAS_GIT_SHOW_MERGE_HEAD=$(grep -cE 'git show.*MERGE_HEAD|git show.*merge_head' "$SYNC_SCRIPT" || true)
assert_ne "test_static_git_show_merge_head" "0" "$HAS_GIT_SHOW_MERGE_HEAD"
[ "$HAS_GIT_SHOW_MERGE_HEAD" -gt 0 ] && echo "  PASS: git show MERGE_HEAD found" || echo "  FAIL: git show MERGE_HEAD missing" >&2

# =============================================================================
# Integration tests using a minimal real git repo
# =============================================================================

# Build a temp dir for integration tests, cleaned up on exit
_TMPDIR=$(mktemp -d)
trap 'rm -rf "$_TMPDIR"' EXIT

# Helper: Initialize a minimal git repo with user config
_init_repo() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -b main -q
    git -C "$dir" config user.email "test@test.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" config commit.gpgsign false
}

# Helper: Create a mock merge-ticket-index.py that writes a merged result
# The mock accepts (ancestor, ours, theirs) and produces a merged result.
# The 'ours' file may contain git conflict markers — the mock uses ancestor
# and theirs to produce a clean merge, writing back to ours_path.
_make_mock_merge_ticket_index() {
    local path="$1"
    cat > "$path" << 'PYEOF'
#!/usr/bin/env python3
"""Mock merge-ticket-index.py for testing.
Accepts: ancestor_path ours_path theirs_path
The ours_path may contain git conflict markers; we use ancestor + theirs
plus the ours content (extracted from theirs side of conflict markers or
directly if clean) to produce a merged result.
Writes merged result back to ours_path.
"""
import sys
import json
import re

if len(sys.argv) != 4:
    sys.exit(1)

ancestor_path, ours_path, theirs_path = sys.argv[1], sys.argv[2], sys.argv[3]

def load_json_or_empty(path):
    """Load JSON; if file has conflict markers, extract ours section."""
    with open(path) as f:
        content = f.read()
    # Check for conflict markers
    if '<<<<<<' in content:
        # Extract ours section (between <<<<<<< and =======)
        ours_match = re.search(r'<{7}.*?\n(.*?)\n={7}', content, re.DOTALL)
        if ours_match:
            content = ours_match.group(1)
        else:
            return {}
    try:
        return json.loads(content) if content.strip() else {}
    except json.JSONDecodeError:
        return {}

ancestor = load_json_or_empty(ancestor_path)
ours = load_json_or_empty(ours_path)

with open(theirs_path) as f:
    theirs = json.load(f)

# Simple merge: start with ours, add any theirs keys not in ancestor (new tickets)
merged = dict(ours)
for k, v in theirs.items():
    if k not in ancestor:
        # New ticket added by theirs — include it
        merged[k] = v

# Write merged result back to ours_path
with open(ours_path, 'w') as f:
    json.dump(merged, f, indent=2)

sys.exit(0)
PYEOF
    chmod +x "$path"
}

# =============================================================================
# Test 1: test_fallback_guard_non_ticket_conflict
# A non-ticket file (src/foo.py) is also conflicted → fallback must abort,
# return 1, and NOT emit MERGE_AUTO_RESOLVE.
# =============================================================================
echo ""
echo "Test 1: test_fallback_guard_non_ticket_conflict"

T1="$_TMPDIR/t1"
_init_repo "$T1"

# Create a mock scripts directory (for merge-ticket-index.py)
mkdir -p "$T1/scripts-mock"
_make_mock_merge_ticket_index "$T1/scripts-mock/merge-ticket-index.py"

# --- Create initial commit on main with .tickets/.index.json and src/foo.py ---
mkdir -p "$T1/.tickets" "$T1/src"
echo '{"v1": "ticket1"}' > "$T1/.tickets/.index.json"
echo 'def foo(): pass' > "$T1/src/foo.py"
git -C "$T1" add .
git -C "$T1" commit -q -m "initial"

# --- Create a feature branch with changes to both files ---
git -C "$T1" checkout -q -b feature
echo '{"v1": "ticket1", "v2": "feature-ticket"}' > "$T1/.tickets/.index.json"
echo 'def foo(): return 42' > "$T1/src/foo.py"
git -C "$T1" add .
git -C "$T1" commit -q -m "feature changes"

# --- On main, also change both files to create conflicts ---
git -C "$T1" checkout -q main
echo '{"v1": "ticket1", "v3": "main-ticket"}' > "$T1/.tickets/.index.json"
echo 'def foo(): return "main"' > "$T1/src/foo.py"
git -C "$T1" add .
git -C "$T1" commit -q -m "main changes"

# --- Switch to feature branch and attempt to merge main (will conflict) ---
git -C "$T1" checkout -q feature

# Source the sync script and call _worktree_sync_from_main
# We override git fetch to be a no-op since we already have the ref
# and override _SCRIPT_DIR to point to our mock scripts
T1_OUTPUT=""
T1_EXIT=0
T1_OUTPUT=$(
    cd "$T1"
    # Stub git fetch to be a no-op
    git() {
        if [[ "$1" == "fetch" ]]; then
            return 0
        fi
        command git "$@"
    }
    export -f git
    # Source the sync script and override _SCRIPT_DIR
    # shellcheck source=/dev/null
    source "$SYNC_SCRIPT"
    _SCRIPT_DIR="$T1/scripts-mock"
    _worktree_sync_from_main 2>&1
) || T1_EXIT=$?

# Assert: exit code must be 1 (abort)
assert_eq "test_fallback_guard_non_ticket_conflict_exit" "1" "$T1_EXIT"

# Assert: MERGE_AUTO_RESOLVE must NOT be in output
NO_AUTO_RESOLVE=1
echo "$T1_OUTPUT" | grep -q 'MERGE_AUTO_RESOLVE' && NO_AUTO_RESOLVE=0
assert_eq "test_fallback_guard_no_auto_resolve_emitted" "1" "$NO_AUTO_RESOLVE"

if [ "$T1_EXIT" -eq 1 ] && [ "$NO_AUTO_RESOLVE" -eq 1 ]; then
    echo "  PASS: guard aborted with exit 1 and did not emit MERGE_AUTO_RESOLVE"
elif [ "$T1_EXIT" -ne 1 ]; then
    echo "  FAIL: expected exit 1, got $T1_EXIT" >&2
    echo "  Output: $T1_OUTPUT" >&2
else
    echo "  FAIL: MERGE_AUTO_RESOLVE was emitted when it should not have been" >&2
    echo "  Output: $T1_OUTPUT" >&2
fi

# =============================================================================
# Test 3: test_fallback_aborts_when_index_json_missing
# Only .tickets/foo.md is conflicted (not .tickets/.index.json) → must abort.
# =============================================================================
echo ""
echo "Test 3: test_fallback_aborts_when_index_json_missing"

T3="$_TMPDIR/t3"
_init_repo "$T3"

mkdir -p "$T3/scripts-mock"
_make_mock_merge_ticket_index "$T3/scripts-mock/merge-ticket-index.py"

# Create initial commit with .tickets/foo.md (no .index.json conflict)
mkdir -p "$T3/.tickets"
echo '# ticket foo' > "$T3/.tickets/foo.md"
echo '{}' > "$T3/.tickets/.index.json"
git -C "$T3" add .
git -C "$T3" commit -q -m "initial"

# Feature branch: modify foo.md only
git -C "$T3" checkout -q -b feature
echo '# ticket foo - feature' > "$T3/.tickets/foo.md"
git -C "$T3" add .
git -C "$T3" commit -q -m "feature: update foo.md"

# Main: also modify foo.md → conflict; .index.json not conflicted
git -C "$T3" checkout -q main
echo '# ticket foo - main' > "$T3/.tickets/foo.md"
git -C "$T3" add .
git -C "$T3" commit -q -m "main: update foo.md"

git -C "$T3" checkout -q feature

T3_OUTPUT=""
T3_EXIT=0
T3_OUTPUT=$(
    cd "$T3"
    git() {
        if [[ "$1" == "fetch" ]]; then
            return 0
        fi
        command git "$@"
    }
    export -f git
    source "$SYNC_SCRIPT"
    _SCRIPT_DIR="$T3/scripts-mock"
    _worktree_sync_from_main 2>&1
) || T3_EXIT=$?

# Assert: must abort (exit 1) — only .tickets/foo.md conflicted, no .index.json
assert_eq "test_fallback_aborts_when_index_json_missing_exit" "1" "$T3_EXIT"

NO_AUTO_RESOLVE_T3=1
echo "$T3_OUTPUT" | grep -q 'MERGE_AUTO_RESOLVE' && NO_AUTO_RESOLVE_T3=0
assert_eq "test_fallback_aborts_no_auto_resolve" "1" "$NO_AUTO_RESOLVE_T3"

if [ "$T3_EXIT" -eq 1 ] && [ "$NO_AUTO_RESOLVE_T3" -eq 1 ]; then
    echo "  PASS: fallback aborted when .index.json not among conflicted files"
elif [ "$T3_EXIT" -ne 1 ]; then
    echo "  FAIL: expected exit 1, got $T3_EXIT" >&2
    echo "  Output: $T3_OUTPUT" >&2
else
    echo "  FAIL: MERGE_AUTO_RESOLVE emitted when only .tickets/foo.md conflicted" >&2
    echo "  Output: $T3_OUTPUT" >&2
fi

# =============================================================================
# Test 14: test_fallback_aborts_mixed_ticket_conflicts
# Both .tickets/.index.json AND .tickets/foo.md are conflicted → must abort
# because non-index ticket files cannot be auto-resolved.
# =============================================================================
echo ""
echo "Test 14: test_fallback_aborts_mixed_ticket_conflicts"

T14="$_TMPDIR/t14"
_init_repo "$T14"

mkdir -p "$T14/scripts-mock"
_make_mock_merge_ticket_index "$T14/scripts-mock/merge-ticket-index.py"

# Create initial commit with both .tickets/.index.json and .tickets/foo.md
mkdir -p "$T14/.tickets"
echo '{"v1": "ticket1"}' > "$T14/.tickets/.index.json"
echo '# ticket foo' > "$T14/.tickets/foo.md"
git -C "$T14" add .
git -C "$T14" commit -q -m "initial"

# Feature branch: modify both files
git -C "$T14" checkout -q -b feature
echo '{"v1": "ticket1", "v2": "feature-ticket"}' > "$T14/.tickets/.index.json"
echo '# ticket foo - feature version' > "$T14/.tickets/foo.md"
git -C "$T14" add .
git -C "$T14" commit -q -m "feature: update index and foo.md"

# Main: also modify both files → conflict on both
git -C "$T14" checkout -q main
echo '{"v1": "ticket1", "v3": "main-ticket"}' > "$T14/.tickets/.index.json"
echo '# ticket foo - main version' > "$T14/.tickets/foo.md"
git -C "$T14" add .
git -C "$T14" commit -q -m "main: update index and foo.md"

git -C "$T14" checkout -q feature

T14_OUTPUT=""
T14_EXIT=0
T14_OUTPUT=$(
    cd "$T14"
    git() {
        if [[ "$1" == "fetch" ]]; then
            return 0
        fi
        command git "$@"
    }
    export -f git
    source "$SYNC_SCRIPT"
    _SCRIPT_DIR="$T14/scripts-mock"
    _worktree_sync_from_main 2>&1
) || T14_EXIT=$?

# Assert: must abort (exit 1) — .tickets/foo.md can't be auto-resolved
assert_eq "test_fallback_aborts_mixed_ticket_conflicts_exit" "1" "$T14_EXIT"

NO_AUTO_RESOLVE_T14=1
echo "$T14_OUTPUT" | grep -q 'MERGE_AUTO_RESOLVE' && NO_AUTO_RESOLVE_T14=0
assert_eq "test_fallback_aborts_mixed_no_auto_resolve" "1" "$NO_AUTO_RESOLVE_T14"

if [ "$T14_EXIT" -eq 1 ] && [ "$NO_AUTO_RESOLVE_T14" -eq 1 ]; then
    echo "  PASS: fallback aborted when .tickets/.index.json + .tickets/foo.md both conflicted"
elif [ "$T14_EXIT" -ne 1 ]; then
    echo "  FAIL: expected exit 1, got $T14_EXIT" >&2
    echo "  Output: $T14_OUTPUT" >&2
else
    echo "  FAIL: MERGE_AUTO_RESOLVE emitted when non-index ticket file was conflicted" >&2
    echo "  Output: $T14_OUTPUT" >&2
fi

# =============================================================================
# Test 2: test_fallback_resolves_tickets_only_conflict
# Only .tickets/.index.json is conflicted → fallback calls merge-ticket-index.py,
# emits MERGE_AUTO_RESOLVE: path=.tickets/.index.json layer=fallback, exits 0.
#
# Setup: uses a bare repo as "origin" so git fetch/merge origin/main works.
# =============================================================================
echo ""
echo "Test 2: test_fallback_resolves_tickets_only_conflict"

T2_ORIGIN="$_TMPDIR/t2-origin.git"
T2="$_TMPDIR/t2"

# Create a bare repo as origin
git init -b main -q --bare "$T2_ORIGIN"

# Clone the bare repo as "main" repo, add initial commit
T2_MAIN="$_TMPDIR/t2-main"
git clone -q "$T2_ORIGIN" "$T2_MAIN"
git -C "$T2_MAIN" config user.email "test@test.com"
git -C "$T2_MAIN" config user.name "Test"
git -C "$T2_MAIN" config commit.gpgsign false

mkdir -p "$T2_MAIN/.tickets"
echo '{"v1": "ticket-a"}' > "$T2_MAIN/.tickets/.index.json"
git -C "$T2_MAIN" add .
git -C "$T2_MAIN" commit -q -m "initial"
git -C "$T2_MAIN" push -q origin HEAD:main

# Clone the repo as the "worktree" (feature branch)
git clone -q "$T2_ORIGIN" "$T2"
git -C "$T2" config user.email "test@test.com"
git -C "$T2" config user.name "Test"
git -C "$T2" config commit.gpgsign false

# Create feature branch and add a ticket
git -C "$T2" checkout -q -b feature
echo '{"v1": "ticket-a", "v2": "ticket-b"}' > "$T2/.tickets/.index.json"
git -C "$T2" add .
git -C "$T2" commit -q -m "feature: add ticket-b"

# On main repo, add a different ticket and push → this creates the divergence
git -C "$T2_MAIN" checkout -q main
echo '{"v1": "ticket-a", "v3": "ticket-c"}' > "$T2_MAIN/.tickets/.index.json"
git -C "$T2_MAIN" add .
git -C "$T2_MAIN" commit -q -m "main: add ticket-c"
git -C "$T2_MAIN" push -q origin main

# Place mock merge-ticket-index.py in the script dir location
mkdir -p "$T2/mock-scripts"
_make_mock_merge_ticket_index "$T2/mock-scripts/merge-ticket-index.py"

T2_OUTPUT=""
T2_EXIT=0
T2_OUTPUT=$(
    cd "$T2"
    source "$SYNC_SCRIPT"
    _SCRIPT_DIR="$T2/mock-scripts"
    _worktree_sync_from_main 2>&1
) || T2_EXIT=$?

# Assert: exit 0 (success)
assert_eq "test_fallback_resolves_tickets_only_conflict_exit" "0" "$T2_EXIT"

# Assert: MERGE_AUTO_RESOLVE emitted with correct path and layer
HAS_AUTO_RESOLVE_T2=0
echo "$T2_OUTPUT" | grep -q 'MERGE_AUTO_RESOLVE.*path=\.tickets/\.index\.json.*layer=fallback' && HAS_AUTO_RESOLVE_T2=1
assert_eq "test_fallback_resolves_emits_merge_auto_resolve" "1" "$HAS_AUTO_RESOLVE_T2"

if [ "$T2_EXIT" -eq 0 ] && [ "$HAS_AUTO_RESOLVE_T2" -eq 1 ]; then
    echo "  PASS: fallback resolved tickets-only conflict and emitted MERGE_AUTO_RESOLVE"
elif [ "$T2_EXIT" -ne 0 ]; then
    echo "  FAIL: expected exit 0, got $T2_EXIT" >&2
    echo "  Output: $T2_OUTPUT" >&2
else
    echo "  FAIL: MERGE_AUTO_RESOLVE not emitted (or wrong format)" >&2
    echo "  Output: $T2_OUTPUT" >&2
fi

# =============================================================================
# Summary
# =============================================================================
print_summary
