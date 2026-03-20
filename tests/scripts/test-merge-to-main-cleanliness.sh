#!/usr/bin/env bash
# tests/scripts/test-merge-to-main-cleanliness.sh
# RED tests for dso-z6zi: verify merge-to-main.sh leaves main clean after merge.
#
# Tests:
#   1. test_validate_fails_on_remaining_dirty — _phase_validate exits non-zero
#      when non-ticket dirty files exist on main after merge
#   2. test_validate_detects_untracked_files — _phase_validate detects untracked
#      files on main (not just modified tracked files)
#   3. test_main_clean_after_successful_merge — after a successful full merge,
#      main has no dirty or untracked files (excluding tickets dir)
#   4. test_worktree_dirty_tickets_committed_before_merge — uncommitted .tickets
#      files on the worktree are auto-committed before merge starts
#   5. test_worktree_untracked_tickets_committed_before_merge — new (untracked)
#      .tickets files on the worktree are auto-committed before merge starts
#   6. test_worktree_clean_after_merge — after a successful merge, the worktree
#      has no dirty or untracked files (including .tickets/)
#
# Usage: bash tests/scripts/test-merge-to-main-cleanliness.sh
# Returns: exit 0 if all tests pass, exit 1 if any fail

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
MERGE_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main.sh"

source "$PLUGIN_ROOT/tests/lib/assert.sh"

# Temp dir cleanup on exit
_CLEANUP_DIRS=()
_cleanup() { for d in "${_CLEANUP_DIRS[@]}"; do rm -rf "$d"; done; }
trap _cleanup EXIT

# ── Ensure read-config.sh can find a python3 with pyyaml ─────────────────────
if [[ -z "${CLAUDE_PLUGIN_PYTHON:-}" ]]; then
    for _py_candidate in \
            "$REPO_ROOT/app/.venv/bin/python3" \
            "$REPO_ROOT/.venv/bin/python3" \
            "/usr/bin/python3" \
            "python3"; do
        [[ -z "$_py_candidate" ]] && continue
        if "$_py_candidate" -c "import yaml" 2>/dev/null; then
            export CLAUDE_PLUGIN_PYTHON="$_py_candidate"
            break
        fi
    done
fi

# ── Helper: create a minimal ticket file ─────────────────────────────────────
make_ticket_file() {
    local dir="$1"
    local ticket_id="$2"
    local tickets_subdir="${3:-.tickets}"
    mkdir -p "$dir/$tickets_subdir"
    cat > "$dir/$tickets_subdir/${ticket_id}.md" <<EOF
---
id: $ticket_id
status: open
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: task
priority: 2
---
# Ticket $ticket_id
EOF
}

# ── Helper: create a minimal dso-config.conf ─────────────────────────────────
make_minimal_config() {
    local dir="$1"
    local tickets_dir="${2:-.tickets}"
    mkdir -p "$dir/.claude"
    cat > "$dir/.claude/dso-config.conf" <<CONF
tickets.directory=$tickets_dir
CONF
}

# ── Helper: set up a merge-to-main test environment ──────────────────────────
# Creates:
#   $REALENV/bare.git       — bare repo acting as "origin"
#   $REALENV/main-clone/    — main repo cloned from bare (main checked out)
#   $REALENV/worktree/      — worktree linked from main-clone on a feature branch
setup_env() {
    local tickets_dir="${1:-.tickets}"
    local tmpdir
    tmpdir=$(mktemp -d)
    _CLEANUP_DIRS+=("$tmpdir")
    local REALENV
    REALENV=$(cd "$tmpdir" && pwd -P)

    # 1. Seed repo with initial commit
    git init -q -b main "$REALENV/seed"
    git -C "$REALENV/seed" config user.email "test@test.com"
    git -C "$REALENV/seed" config user.name "Test"
    echo "initial" > "$REALENV/seed/README.md"
    make_ticket_file "$REALENV/seed" "seed-init" "$tickets_dir"
    make_minimal_config "$REALENV/seed" "$tickets_dir"
    git -C "$REALENV/seed" add -A
    git -C "$REALENV/seed" commit -q -m "init"

    # 2. Bare repo cloned from seed (acts as origin)
    git clone --bare -q "$REALENV/seed" "$REALENV/bare.git"

    # 3. Clone bare into main-clone
    git clone -q "$REALENV/bare.git" "$REALENV/main-clone"
    git -C "$REALENV/main-clone" config user.email "test@test.com"
    git -C "$REALENV/main-clone" config user.name "Test"

    # 4. Create a feature branch worktree
    git -C "$REALENV/main-clone" branch feature-branch 2>/dev/null || true
    git -C "$REALENV/main-clone" worktree add -q "$REALENV/worktree" feature-branch 2>/dev/null
    git -C "$REALENV/worktree" config user.email "test@test.com"
    git -C "$REALENV/worktree" config user.name "Test"

    echo "$REALENV"
}

# ── Helper: cleanup ──────────────────────────────────────────────────────────
cleanup_env() {
    local env_dir="$1"
    git -C "$env_dir/main-clone" worktree remove --force "$env_dir/worktree" 2>/dev/null || true
    rm -rf "$env_dir"
}

echo "=== test-merge-to-main-cleanliness.sh ==="

# =============================================================================
# Test 1: _phase_validate fails on remaining dirty files
# After merge, if non-ticket dirty files exist on main, the script should
# exit non-zero (ERROR), not just print a WARNING.
# =============================================================================
echo "--- Test 1: validate fails on remaining dirty ---"
TMPENV1=$(setup_env ".tickets")
WT1=$(cd "$TMPENV1/worktree" && pwd -P)
MAIN1="$TMPENV1/main-clone"

# Make a committed change on the feature branch
echo "feature content" > "$WT1/feature.txt"
(cd "$WT1" && git add feature.txt && git commit -q -m "feat: add feature")

# Create a dirty tracked file on main that will persist after merge.
# The merge brings in feature.txt, but leftover.txt is already on main as
# a dirty (modified but not staged) file.
echo "base content" > "$MAIN1/leftover.txt"
(cd "$MAIN1" && git add leftover.txt && git commit -q -m "add leftover" && git push -q origin main)
# Now modify it without staging — this creates a dirty tracked file on main
echo "modified content" > "$MAIN1/leftover.txt"

# Run merge — it should detect the dirty file on main and fail (not just warn)
MERGE_OUTPUT1=$(cd "$WT1" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# The merge script should report an ERROR, not just a WARNING
HAS_ERROR1="false"
if echo "$MERGE_OUTPUT1" | grep -q "ERROR.*dirty\|ERROR.*clean\|ERROR.*leftover"; then
    HAS_ERROR1="true"
fi
# Currently this is a WARNING, so this test should FAIL (RED)
assert_eq "test_validate_fails_on_remaining_dirty" "true" "$HAS_ERROR1"

cleanup_env "$TMPENV1"

# =============================================================================
# Test 2: _phase_validate detects untracked files on main
# After merge, if untracked (non-ticket) files exist on main, the script
# should detect and report them.
# =============================================================================
echo "--- Test 2: validate detects untracked files ---"
TMPENV2=$(setup_env ".tickets")
WT2=$(cd "$TMPENV2/worktree" && pwd -P)
MAIN2="$TMPENV2/main-clone"

# Make a committed change on the feature branch
echo "feature content 2" > "$WT2/feature2.txt"
(cd "$WT2" && git add feature2.txt && git commit -q -m "feat: add feature2")

# Create an untracked file on main (not in .tickets/)
echo "untracked artifact" > "$MAIN2/artifact.log"

# Run merge — it should detect the untracked file on main and fail
MERGE_OUTPUT2=$(cd "$WT2" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# The merge script should report the untracked file
HAS_UNTRACKED_DETECTION2="false"
if echo "$MERGE_OUTPUT2" | grep -q "artifact.log\|untracked.*main\|ERROR.*clean"; then
    HAS_UNTRACKED_DETECTION2="true"
fi
# Currently untracked files are NOT detected, so this test should FAIL (RED)
assert_eq "test_validate_detects_untracked_on_main" "true" "$HAS_UNTRACKED_DETECTION2"

cleanup_env "$TMPENV2"

# =============================================================================
# Test 3: Main is clean after successful merge (no dirty or untracked files)
# After a normal successful merge, main should have zero dirty/untracked files
# (excluding the tickets directory).
# =============================================================================
echo "--- Test 3: main clean after successful merge ---"
TMPENV3=$(setup_env ".tickets")
WT3=$(cd "$TMPENV3/worktree" && pwd -P)
MAIN3="$TMPENV3/main-clone"

# Make a committed change on the feature branch
echo "clean feature" > "$WT3/clean-feature.txt"
(cd "$WT3" && git add clean-feature.txt && git commit -q -m "feat: clean feature")

# Run merge
MERGE_OUTPUT3=$(cd "$WT3" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# Merge should succeed
assert_contains "test_clean_merge_succeeds" "DONE" "$MERGE_OUTPUT3"

# Check main is clean (no dirty files excluding .tickets/)
MAIN3_DIRTY=$(cd "$MAIN3" && git diff --name-only -- ':!.tickets/' 2>/dev/null || true)
MAIN3_UNTRACKED=$(cd "$MAIN3" && git ls-files --others --exclude-standard -- ':!.tickets/' 2>/dev/null || true)
MAIN3_STAGED=$(cd "$MAIN3" && git diff --cached --name-only -- ':!.tickets/' 2>/dev/null || true)

MAIN3_IS_CLEAN="true"
if [ -n "$MAIN3_DIRTY" ] || [ -n "$MAIN3_UNTRACKED" ] || [ -n "$MAIN3_STAGED" ]; then
    MAIN3_IS_CLEAN="false"
    echo "  Dirty: $MAIN3_DIRTY"
    echo "  Untracked: $MAIN3_UNTRACKED"
    echo "  Staged: $MAIN3_STAGED"
fi
assert_eq "test_main_clean_after_merge" "true" "$MAIN3_IS_CLEAN"

cleanup_env "$TMPENV3"

# =============================================================================
# Test 4: Uncommitted (modified) .tickets files on worktree are auto-committed
# before the merge starts, so they appear in the merge on main.
# =============================================================================
echo "--- Test 4: worktree dirty tickets auto-committed ---"
TMPENV4=$(setup_env ".tickets")
WT4=$(cd "$TMPENV4/worktree" && pwd -P)
MAIN4="$TMPENV4/main-clone"

# Make a committed change on the feature branch (real code change)
echo "feature content 4" > "$WT4/feature4.txt"
(cd "$WT4" && git add feature4.txt && git commit -q -m "feat: add feature4")

# Now modify an existing .tickets file WITHOUT committing it.
# This simulates tk close/status updating a ticket during end-session.
echo "---
id: seed-init
status: closed
deps: []
links: []
created: 2026-01-01T00:00:00Z
type: task
priority: 2
---
# Ticket seed-init (closed)" > "$WT4/.tickets/seed-init.md"

# Verify the worktree IS dirty with .tickets changes
WT4_DIRTY_BEFORE=$(cd "$WT4" && git diff --name-only 2>/dev/null || true)
assert_contains "test_worktree_has_dirty_tickets_before_merge" ".tickets/seed-init.md" "$WT4_DIRTY_BEFORE"

# Run merge — it should auto-commit the .tickets changes, then merge successfully
MERGE_OUTPUT4=$(cd "$WT4" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# Merge should succeed
assert_contains "test_dirty_tickets_merge_succeeds" "DONE" "$MERGE_OUTPUT4"

# The ticket change should have made it to main (via auto-commit + merge)
TICKET_ON_MAIN4=$(cd "$MAIN4" && git show HEAD:.tickets/seed-init.md 2>/dev/null | grep "status:" || echo "NOT_FOUND")
assert_contains "test_dirty_ticket_reached_main" "closed" "$TICKET_ON_MAIN4"

# Worktree should be clean after merge (no dirty .tickets files left behind)
WT4_PORCELAIN=$(cd "$WT4" && git status --porcelain 2>/dev/null || true)
WT4_IS_CLEAN="true"
if [ -n "$WT4_PORCELAIN" ]; then
    WT4_IS_CLEAN="false"
    echo "  Worktree dirty after merge: $WT4_PORCELAIN"
fi
assert_eq "test_worktree_clean_after_dirty_tickets_merge" "true" "$WT4_IS_CLEAN"

cleanup_env "$TMPENV4"

# =============================================================================
# Test 5: New (untracked) .tickets files on worktree are auto-committed
# before the merge starts.
# =============================================================================
echo "--- Test 5: worktree untracked tickets auto-committed ---"
TMPENV5=$(setup_env ".tickets")
WT5=$(cd "$TMPENV5/worktree" && pwd -P)
MAIN5="$TMPENV5/main-clone"

# Make a committed change on the feature branch
echo "feature content 5" > "$WT5/feature5.txt"
(cd "$WT5" && git add feature5.txt && git commit -q -m "feat: add feature5")

# Create a NEW .tickets file (untracked) — simulates tk create during end-session
make_ticket_file "$WT5" "new-bug-from-session" ".tickets"

# Verify the worktree has an untracked .tickets file
WT5_UNTRACKED_BEFORE=$(cd "$WT5" && git ls-files --others --exclude-standard 2>/dev/null || true)
assert_contains "test_worktree_has_untracked_tickets_before_merge" ".tickets/new-bug-from-session.md" "$WT5_UNTRACKED_BEFORE"

# Run merge — it should auto-commit the new .tickets file, then merge successfully
MERGE_OUTPUT5=$(cd "$WT5" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# Merge should succeed
assert_contains "test_untracked_tickets_merge_succeeds" "DONE" "$MERGE_OUTPUT5"

# The new ticket should have made it to main
TICKET_ON_MAIN5=$(cd "$MAIN5" && git show HEAD:.tickets/new-bug-from-session.md 2>/dev/null | head -1 || echo "NOT_FOUND")
assert_eq "test_untracked_ticket_reached_main" "---" "$TICKET_ON_MAIN5"

# Worktree should be clean
WT5_PORCELAIN=$(cd "$WT5" && git status --porcelain 2>/dev/null || true)
WT5_IS_CLEAN="true"
if [ -n "$WT5_PORCELAIN" ]; then
    WT5_IS_CLEAN="false"
    echo "  Worktree dirty after merge: $WT5_PORCELAIN"
fi
assert_eq "test_worktree_clean_after_untracked_tickets_merge" "true" "$WT5_IS_CLEAN"

cleanup_env "$TMPENV5"

# =============================================================================
# Test 6: Worktree is fully clean after a normal successful merge
# (no dirty or untracked files, including .tickets/)
# =============================================================================
echo "--- Test 6: worktree fully clean after merge ---"
TMPENV6=$(setup_env ".tickets")
WT6=$(cd "$TMPENV6/worktree" && pwd -P)

# Make a committed change on the feature branch
echo "clean feature 6" > "$WT6/clean-feature6.txt"
(cd "$WT6" && git add clean-feature6.txt && git commit -q -m "feat: clean feature6")

# Run merge
MERGE_OUTPUT6=$(cd "$WT6" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# Merge should succeed
assert_contains "test_clean_merge6_succeeds" "DONE" "$MERGE_OUTPUT6"

# Worktree should be fully clean (git status --porcelain should be empty)
WT6_PORCELAIN=$(cd "$WT6" && git status --porcelain 2>/dev/null || true)
WT6_IS_CLEAN="true"
if [ -n "$WT6_PORCELAIN" ]; then
    WT6_IS_CLEAN="false"
    echo "  Worktree not clean: $WT6_PORCELAIN"
fi
assert_eq "test_worktree_fully_clean_after_merge" "true" "$WT6_IS_CLEAN"

cleanup_env "$TMPENV6"

# =============================================================================
print_summary
