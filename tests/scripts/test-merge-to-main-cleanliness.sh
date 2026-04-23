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
#   4. test_worktree_dirty_tickets_committed_before_merge — uncommitted .tickets-tracker
#      event files on the worktree are auto-committed before merge starts
#   5. test_worktree_untracked_tickets_committed_before_merge — new (untracked)
#      .tickets-tracker event files on the worktree are auto-committed before merge starts
#   6. test_worktree_clean_after_merge — after a successful merge, the worktree
#      has no dirty or untracked files (including .tickets-tracker/)
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

# Prevent PROJECT_ROOT from leaking into temp-repo merge-to-main.sh invocations.
# The dso shim exports PROJECT_ROOT; if inherited, merge-to-main.sh uses the
# actual project root instead of the temp repo, causing false dirty-worktree failures.
unset PROJECT_ROOT

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

# ── Helper: create a minimal v3 ticket event file ────────────────────────────
# v3 ticket system stores events as JSON files in .tickets-tracker/<id>/*.json
# and maintains an index at .tickets-tracker/.index.json
make_ticket_file() {
    local dir="$1"
    local ticket_id="$2"
    local tickets_subdir="${3:-.tickets-tracker}"
    mkdir -p "$dir/$tickets_subdir/$ticket_id"
    cat > "$dir/$tickets_subdir/$ticket_id/00-create.json" <<EOF
{"type":"create","id":"$ticket_id","ticket_type":"task","title":"Ticket $ticket_id","priority":2,"status":"open","created":"2026-01-01T00:00:00Z"}
EOF
    # Also update the index file
    local index_file="$dir/$tickets_subdir/.index.json"
    if [ -f "$index_file" ]; then
        # Append to existing index (simple JSON merge for test purposes)
        python3 -c "
import json, sys
with open('$index_file') as f:
    idx = json.load(f)
idx['$ticket_id'] = {'id': '$ticket_id', 'status': 'open', 'type': 'task'}
with open('$index_file', 'w') as f:
    json.dump(idx, f)
" 2>/dev/null || true
    else
        echo "{\"$ticket_id\":{\"id\":\"$ticket_id\",\"status\":\"open\",\"type\":\"task\"}}" > "$index_file"
    fi
}

# ── Helper: create a minimal dso-config.conf ─────────────────────────────────
make_minimal_config() {
    local dir="$1"
    local tickets_dir="${2:-.tickets-tracker}"
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
    local tickets_dir="${1:-.tickets-tracker}"
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
TMPENV1=$(setup_env ".tickets-tracker")
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
if [[ "$MERGE_OUTPUT1" =~ ERROR.*dirty|ERROR.*clean|ERROR.*leftover ]]; then
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
TMPENV2=$(setup_env ".tickets-tracker")
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
if [[ "$MERGE_OUTPUT2" == *artifact.log* ]] || [[ "$MERGE_OUTPUT2" =~ untracked.*main|ERROR.*clean ]]; then
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
TMPENV3=$(setup_env ".tickets-tracker")
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

# Check main is clean (no dirty files excluding .tickets-tracker/)
MAIN3_DIRTY=$(cd "$MAIN3" && git diff --name-only -- ':!.tickets-tracker/' 2>/dev/null || true)
MAIN3_UNTRACKED=$(cd "$MAIN3" && git ls-files --others --exclude-standard -- ':!.tickets-tracker/' 2>/dev/null || true)
MAIN3_STAGED=$(cd "$MAIN3" && git diff --cached --name-only -- ':!.tickets-tracker/' 2>/dev/null || true)

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
TMPENV4=$(setup_env ".tickets-tracker")
WT4=$(cd "$TMPENV4/worktree" && pwd -P)
MAIN4="$TMPENV4/main-clone"

# Make a committed change on the feature branch (real code change)
echo "feature content 4" > "$WT4/feature4.txt"
(cd "$WT4" && git add feature4.txt && git commit -q -m "feat: add feature4")

# Now modify an existing .tickets-tracker event file WITHOUT committing it.
# This simulates a ticket command updating a ticket status during end-session.
# The seed-init ticket was created by make_ticket_file in setup_env.
echo '{"type":"transition","id":"seed-init","from":"open","to":"closed","ts":"2026-01-01T00:01:00Z"}' \
    > "$WT4/.tickets-tracker/seed-init/01-transition.json"

# Verify the worktree IS dirty with .tickets-tracker changes
WT4_UNTRACKED_BEFORE=$(cd "$WT4" && git ls-files --others --exclude-standard -- .tickets-tracker/ 2>/dev/null || true)
assert_contains "test_worktree_has_dirty_tickets_before_merge" ".tickets-tracker/seed-init/01-transition.json" "$WT4_UNTRACKED_BEFORE"

# Run merge — it should auto-commit the .tickets-tracker changes, then merge successfully
MERGE_OUTPUT4=$(cd "$WT4" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# Merge should succeed
assert_contains "test_dirty_tickets_merge_succeeds" "DONE" "$MERGE_OUTPUT4"

# The ticket event file should have made it to main (via auto-commit + merge)
TICKET_ON_MAIN4=$(cd "$MAIN4" && git show HEAD:.tickets-tracker/seed-init/01-transition.json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('to','NOT_FOUND'))" 2>/dev/null || echo "NOT_FOUND")
assert_contains "test_dirty_ticket_reached_main" "closed" "$TICKET_ON_MAIN4"

# Worktree should be clean after merge (no dirty .tickets-tracker files left behind)
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
TMPENV5=$(setup_env ".tickets-tracker")
WT5=$(cd "$TMPENV5/worktree" && pwd -P)
MAIN5="$TMPENV5/main-clone"

# Make a committed change on the feature branch
echo "feature content 5" > "$WT5/feature5.txt"
(cd "$WT5" && git add feature5.txt && git commit -q -m "feat: add feature5")

# Create a NEW .tickets-tracker event directory (untracked) — simulates tk create during end-session
make_ticket_file "$WT5" "new-bug-from-session" ".tickets-tracker"

# Verify the worktree has untracked .tickets-tracker files
WT5_UNTRACKED_BEFORE=$(cd "$WT5" && git ls-files --others --exclude-standard -- .tickets-tracker/ 2>/dev/null || true)
assert_contains "test_worktree_has_untracked_tickets_before_merge" ".tickets-tracker/new-bug-from-session/00-create.json" "$WT5_UNTRACKED_BEFORE"

# Run merge — it should auto-commit the new .tickets-tracker files, then merge successfully
MERGE_OUTPUT5=$(cd "$WT5" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# Merge should succeed
assert_contains "test_untracked_tickets_merge_succeeds" "DONE" "$MERGE_OUTPUT5"

# The new ticket event file should have made it to main
TICKET_ON_MAIN5=$(cd "$MAIN5" && git show HEAD:.tickets-tracker/new-bug-from-session/00-create.json 2>/dev/null | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('type','NOT_FOUND'))" 2>/dev/null || echo "NOT_FOUND")
assert_eq "test_untracked_ticket_reached_main" "create" "$TICKET_ON_MAIN5"

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
TMPENV6=$(setup_env ".tickets-tracker")
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
# Test 7: _phase_sync clears staged files after merge (2613-a2eb)
#
# Pre-commit hooks (e.g., ruff auto-formatting) can restage files in the
# worktree index during the merge commit. If _phase_sync does not clear these
# restaged files, the top-level dirty-check (DIRTY_CACHED) will see them on
# --resume and exit 1, creating an unrecoverable loop.
#
# Fix: add 'git reset HEAD --quiet || true' after the merge in _phase_sync.
#
# This is a structural test: extract _phase_sync and verify that
# 'git reset HEAD' appears AFTER 'git merge origin/main' in the function body.
# RED: before the fix, 'git reset HEAD' is absent → test FAILS.
# GREEN: after adding the reset, the ordering check passes.
# =============================================================================
echo "--- Test 7: _phase_sync clears staged files after merge (2613-a2eb) ---"

# Helper: extract a named function body from merge-to-main.sh
_extract_fn7() {
    local fn_name="$1"
    awk "/^${fn_name}\\(\\)/{found=1} found{print; if(/^\\}$/){exit}}" "$MERGE_SCRIPT"
}

_SYNC_BODY=$(_extract_fn7 "_phase_sync" 2>/dev/null || echo "")

# Check that 'git reset HEAD' appears in _phase_sync
_SYNC_HAS_RESET="no"
if echo "$_SYNC_BODY" | grep -qE 'git reset HEAD'; then
    _SYNC_HAS_RESET="yes"
fi

# Check that 'git reset HEAD' appears AFTER 'git merge origin/main' in the function
_MERGE_LINE=$(echo "$_SYNC_BODY" | grep -n 'git merge origin/main' | head -1 | cut -d: -f1)
_RESET_LINE=$(echo "$_SYNC_BODY" | grep -n 'git reset HEAD' | head -1 | cut -d: -f1)

_RESET_AFTER_MERGE="no"
if [[ -n "$_MERGE_LINE" && -n "$_RESET_LINE" ]]; then
    if [[ "$_RESET_LINE" -gt "$_MERGE_LINE" ]]; then
        _RESET_AFTER_MERGE="yes"
    fi
fi

assert_eq "test_sync_phase_has_git_reset_head" "yes" "$_SYNC_HAS_RESET"
assert_eq "test_sync_phase_clears_staged_files_after_merge" "yes" "$_RESET_AFTER_MERGE"

# =============================================================================
# Test 8: merge succeeds when main has dirty tracked files (0444-8a59)
#
# When CLAUDE_PLUGIN_ROOT points to the main repo, hook scripts can leave
# dirty tracked files on main. Without a pre-merge stash, git merge fails with
# "Your local changes to the following files would be overwritten by merge".
# Fix: _phase_merge stashes dirty files before merging and pops after.
#
# RED: before the fix, the merge exits non-zero and output contains "overwrite"
# GREEN: after the fix, the merge succeeds (output contains "Merged" or "DONE")
# and the dirty file still has the pre-merge content (stash popped).
# =============================================================================
echo "--- Test 8: merge succeeds with dirty tracked files on main (0444-8a59) ---"
TMPENV8=$(setup_env ".tickets-tracker")
WT8=$(cd "$TMPENV8/worktree" && pwd -P)
MAIN8="$TMPENV8/main-clone"

# Commit a shared file on main (and origin) that BOTH the feature branch and
# the dirty-main scenario will touch — triggering the "overwrite" error.
echo "original content" > "$MAIN8/tracked-hook-lib.sh"
(cd "$MAIN8" && git add tracked-hook-lib.sh && git commit -q -m "add hook lib" && git push -q origin main)

# Rebase worktree so it includes the hook-lib file
(cd "$WT8" && git rebase origin/main -q 2>/dev/null || true)

# Make the feature branch also modify tracked-hook-lib.sh (creates the overwrite condition)
echo "feature version of hook lib" > "$WT8/tracked-hook-lib.sh"
echo "feature content 8" > "$WT8/feature8.txt"
(cd "$WT8" && git add tracked-hook-lib.sh feature8.txt && git commit -q -m "feat: update hook lib + feature8")

# Simulate a hook script dirtying tracked-hook-lib.sh on main (not staged).
# Because the feature branch also modified this file, git merge would fail
# with "Your local changes to tracked-hook-lib.sh would be overwritten by merge"
# without the pre-merge stash fix.
echo "hook-modified content" > "$MAIN8/tracked-hook-lib.sh"

# Run merge — with the fix, stash shields the dirty file and merge succeeds
MERGE_OUTPUT8=$(cd "$WT8" && unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE && \
    bash "$MERGE_SCRIPT" 2>&1 || true)

# Merge should succeed
MERGE8_SUCCESS="false"
if echo "$MERGE_OUTPUT8" | grep -qiE "OK: Merged|DONE"; then
    MERGE8_SUCCESS="true"
fi
assert_eq "test_merge_succeeds_with_dirty_main" "true" "$MERGE8_SUCCESS"

# After successful merge, tracked-hook-lib.sh should have the feature branch content
# (stash was dropped since merge brought in conflicting content)
MERGED_CONTENT8=$(cat "$MAIN8/tracked-hook-lib.sh" 2>/dev/null || echo "missing")
CONTENT8_VALID="false"
if [[ "$MERGED_CONTENT8" == "feature version of hook lib" || "$MERGED_CONTENT8" == "hook-modified content" ]]; then
    CONTENT8_VALID="true"
fi
assert_eq "test_dirty_file_has_valid_content_after_merge" "true" "$CONTENT8_VALID"

cleanup_env "$TMPENV8"

# =============================================================================
print_summary
