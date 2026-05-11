#!/usr/bin/env bash
# tests/scripts/test-detect-session-leakage.sh
# Behavioral RED tests for plugins/dso/scripts/detect-session-leakage.sh
#
# The script-under-test does not exist yet — all tests are expected to FAIL (RED phase).
#
# detect-session-leakage.sh scans non-merge commits on the session branch (since
# divergence from main) and routes each commit based on its DSO-* trailers:
#   1. DSO-Story trailer (open story) → cherry-pick to story/<epic>/<story-id>
#   2. DSO-Task/DSO-Bug trailer, no DSO-Story → cherry-pick to story/orphan-<session>
#   3. No DSO-* trailer → exit 1 + "manual attribution" + SHA on stderr
#   4. DSO-Story trailer (closed story) → exit 1 + --force-route-to + candidates on stderr
#   4b. --force-route-to=<id> when branch doesn't exist → exit 1 + branch-not-found + SHA
#   5. Cherry-pick conflict on valid story route → abort cherry-pick + exit 1 + SHA + paths
#
# Observable surfaces tested: exit code, stderr content, git log of target branch,
# git repository clean state after conflict.
#
# RED MARKER: All test cases fail until detect-session-leakage.sh is implemented.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

_SCRIPT="$REPO_ROOT/plugins/dso/scripts/detect-session-leakage.sh"

source "$REPO_ROOT/tests/lib/assert.sh"

# ── Cleanup on exit ──────────────────────────────────────────────────────────
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    local d
    for d in "${_TEST_TMPDIRS[@]+"${_TEST_TMPDIRS[@]}"}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# ── Helper: create scratch git repo with shared ancestor on main ──────────────
# Sets up: main branch with one ancestor commit, ready for session branch divergence.
# Prints the repo directory path on stdout.
make_git_repo() {
    local tmpdir
    tmpdir=$(mktemp -d)
    _TEST_TMPDIRS+=("$tmpdir")
    git -C "$tmpdir" init -q
    git -C "$tmpdir" config user.email "test@test.com"
    git -C "$tmpdir" config user.name "Test"
    git -C "$tmpdir" config commit.gpgsign false
    printf '# test repo\n' > "$tmpdir/README.md"
    git -C "$tmpdir" add README.md
    git -C "$tmpdir" commit -q -m "init: shared ancestor"
    printf "%s" "$tmpdir"
}

# ── Exit gate: count all 6 test functions as FAIL if script is missing ─────────
if [[ ! -f "$_SCRIPT" ]]; then
    printf "FAIL: detect-session-leakage.sh not found — expected at %s\n" "$_SCRIPT" >&2
    printf "  All 6 behavioral cases counted as FAIL (RED phase — script not yet written)\n" >&2
    (( FAIL += 6 ))
    print_summary
fi

# ══════════════════════════════════════════════════════════════════════════════
# Case 1 — Valid open DSO-Story trailer → commit cherry-picked to story branch
# ══════════════════════════════════════════════════════════════════════════════
# Given: scratch repo; non-merge commit on session branch with
#        "DSO-Story: Open Story Title" trailer; story/e1/s1 branch exists;
#        stub CLI returns open story with ticket_id=s1, parent_id=e1
# When:  detect-session-leakage.sh invoked (no flags)
# Then:  exits 0; commit SHA appears in git log of story/e1/s1
echo "--- test_valid_open_story_trailer_cherry_picks_to_story_branch ---"
_repo1=$(make_git_repo)

# Create story target branch from shared ancestor
git -C "$_repo1" checkout -q -b story/e1/s1
git -C "$_repo1" checkout -q main

# Diverge: create session branch with a commit bearing a valid DSO-Story trailer
git -C "$_repo1" checkout -q -b session/test-20260511
printf "feature work\n" > "$_repo1/feature.txt"
git -C "$_repo1" add feature.txt
git -C "$_repo1" commit -q -m "$(printf 'add feature\n\nDSO-Story: Open Story Title')"
_session_sha1=$(git -C "$_repo1" log --format="%H" -1)

# Create stub CLI returning open story s1 under epic e1
_tmpdir1=$(mktemp -d); _TEST_TMPDIRS+=("$_tmpdir1")
cat > "$_tmpdir1/dso" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "ticket list --type=story")
    printf '[{"ticket_id":"s1","title":"Open Story Title","status":"open","parent_id":"e1"}]\n'
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$_tmpdir1/dso"

_exit1=0
_stderr1=$(
    cd "$_repo1"
    DSO_TICKET_CLI="$_tmpdir1/dso" bash "$_SCRIPT" 2>&1 >/dev/null
) || _exit1=$?

assert_eq \
    "test_valid_open_story_trailer_cherry_picks_to_story_branch: exits 0" \
    "0" "$_exit1"

# The session commit SHA must appear in the story branch git log
_story_log1=$(git -C "$_repo1" log story/e1/s1 --format="%H" 2>/dev/null || true)
assert_contains \
    "test_valid_open_story_trailer_cherry_picks_to_story_branch: session SHA in story/e1/s1 log" \
    "$_session_sha1" "$_story_log1"

# ══════════════════════════════════════════════════════════════════════════════
# Case 2 — Orphan DSO-Task only → cherry-picked to story/orphan-<session>
# ══════════════════════════════════════════════════════════════════════════════
# Given: non-merge commit with "DSO-Task: Some Task Title" and no DSO-Story trailer
# When:  detect-session-leakage.sh invoked
# Then:  exits 0; commit SHA in git log of story/orphan-<session-branch-name>
echo "--- test_orphan_task_trailer_routes_to_orphan_branch ---"
_repo2=$(make_git_repo)

_session_branch2="session/test-20260511"
git -C "$_repo2" checkout -q -b "$_session_branch2"
printf "task work\n" > "$_repo2/task.txt"
git -C "$_repo2" add task.txt
git -C "$_repo2" commit -q -m "$(printf 'implement task\n\nDSO-Task: Some Task Title')"
_session_sha2=$(git -C "$_repo2" log --format="%H" -1)

_tmpdir2=$(mktemp -d); _TEST_TMPDIRS+=("$_tmpdir2")
cat > "$_tmpdir2/dso" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "ticket list --type=story")
    printf '[]\n'
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$_tmpdir2/dso"

_exit2=0
_stderr2=$(
    cd "$_repo2"
    DSO_TICKET_CLI="$_tmpdir2/dso" bash "$_SCRIPT" 2>&1 >/dev/null
) || _exit2=$?

assert_eq \
    "test_orphan_task_trailer_routes_to_orphan_branch: exits 0" \
    "0" "$_exit2"

_expected_orphan_branch2="story/orphan-${_session_branch2}"
_orphan_log2=$(git -C "$_repo2" log "$_expected_orphan_branch2" --format="%H" 2>/dev/null || true)
assert_contains \
    "test_orphan_task_trailer_routes_to_orphan_branch: session SHA in orphan branch log" \
    "$_session_sha2" "$_orphan_log2"

# ══════════════════════════════════════════════════════════════════════════════
# Case 3 — No DSO trailers → exit non-zero + "manual attribution" + SHA on stderr
# ══════════════════════════════════════════════════════════════════════════════
# Given: commit with only "Co-Authored-By: test" (no DSO-* trailers)
# When:  detect-session-leakage.sh invoked
# Then:  exits non-zero; stderr contains "manual attribution" and the commit SHA
echo "--- test_no_dso_trailers_exits_nonzero_with_attribution_prompt ---"
_repo3=$(make_git_repo)

git -C "$_repo3" checkout -q -b session/test-20260511
printf "unattributed work\n" > "$_repo3/unattr.txt"
git -C "$_repo3" add unattr.txt
git -C "$_repo3" commit -q -m "$(printf 'do a thing\n\nCo-Authored-By: test')"
_session_sha3=$(git -C "$_repo3" log --format="%H" -1)

_tmpdir3=$(mktemp -d); _TEST_TMPDIRS+=("$_tmpdir3")
cat > "$_tmpdir3/dso" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "ticket list --type=story")
    printf '[]\n'
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$_tmpdir3/dso"

_exit3=0
_stderr3=$(
    cd "$_repo3"
    DSO_TICKET_CLI="$_tmpdir3/dso" bash "$_SCRIPT" 2>&1 >/dev/null
) || _exit3=$?

assert_ne \
    "test_no_dso_trailers_exits_nonzero_with_attribution_prompt: exits non-zero" \
    "0" "$_exit3"

assert_contains \
    "test_no_dso_trailers_exits_nonzero_with_attribution_prompt: stderr contains 'manual attribution'" \
    "manual attribution" "$_stderr3"

assert_contains \
    "test_no_dso_trailers_exits_nonzero_with_attribution_prompt: stderr contains commit SHA" \
    "$_session_sha3" "$_stderr3"

# ══════════════════════════════════════════════════════════════════════════════
# Case 4 — Closed-story DSO-Story trailer → exit non-zero + --force-route-to + candidates
# ══════════════════════════════════════════════════════════════════════════════
# Given: commit with "DSO-Story: Closed Story Title"; stub returns closed story for that
#        title; stub also returns open candidate story open1
# When:  detect-session-leakage.sh invoked
# Then:  exits non-zero; stderr contains "--force-route-to" and "open1"
echo "--- test_closed_story_trailer_exits_nonzero_with_force_route_hint ---"
_repo4=$(make_git_repo)

git -C "$_repo4" checkout -q -b session/test-20260511
printf "work for closed story\n" > "$_repo4/closed.txt"
git -C "$_repo4" add closed.txt
git -C "$_repo4" commit -q -m "$(printf 'work item\n\nDSO-Story: Closed Story Title')"

_tmpdir4=$(mktemp -d); _TEST_TMPDIRS+=("$_tmpdir4")
cat > "$_tmpdir4/dso" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "ticket list --type=story")
    printf '[{"ticket_id":"closed1","title":"Closed Story Title","status":"closed","parent_id":"e1"},{"ticket_id":"open1","title":"Open Candidate","status":"open","parent_id":"e1"}]\n'
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$_tmpdir4/dso"

_exit4=0
_stderr4=$(
    cd "$_repo4"
    DSO_TICKET_CLI="$_tmpdir4/dso" bash "$_SCRIPT" 2>&1 >/dev/null
) || _exit4=$?

assert_ne \
    "test_closed_story_trailer_exits_nonzero_with_force_route_hint: exits non-zero" \
    "0" "$_exit4"

assert_contains \
    "test_closed_story_trailer_exits_nonzero_with_force_route_hint: stderr contains '--force-route-to'" \
    "--force-route-to" "$_stderr4"

assert_contains \
    "test_closed_story_trailer_exits_nonzero_with_force_route_hint: stderr contains candidate story id 'open1'" \
    "open1" "$_stderr4"

# ══════════════════════════════════════════════════════════════════════════════
# Case 4b — --force-route-to=<id> when target branch does not exist
# ══════════════════════════════════════════════════════════════════════════════
# Given: same closed-story scenario; branch story/e1/open1 does NOT exist
# When:  detect-session-leakage.sh --force-route-to=open1 invoked
# Then:  exits non-zero; stderr contains branch-not-found message AND the offending SHA
echo "--- test_force_route_to_nonexistent_branch_exits_nonzero ---"
_repo4b=$(make_git_repo)

git -C "$_repo4b" checkout -q -b session/test-20260511
printf "work for closed story\n" > "$_repo4b/closed.txt"
git -C "$_repo4b" add closed.txt
git -C "$_repo4b" commit -q -m "$(printf 'work item\n\nDSO-Story: Closed Story Title')"
_session_sha4b=$(git -C "$_repo4b" log --format="%H" -1)

# story/e1/open1 branch intentionally does NOT exist

_tmpdir4b=$(mktemp -d); _TEST_TMPDIRS+=("$_tmpdir4b")
cat > "$_tmpdir4b/dso" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "ticket list --type=story")
    printf '[{"ticket_id":"closed1","title":"Closed Story Title","status":"closed","parent_id":"e1"},{"ticket_id":"open1","title":"Open Candidate","status":"open","parent_id":"e1"}]\n'
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$_tmpdir4b/dso"

_exit4b=0
_stderr4b=$(
    cd "$_repo4b"
    DSO_TICKET_CLI="$_tmpdir4b/dso" bash "$_SCRIPT" --force-route-to=open1 2>&1 >/dev/null
) || _exit4b=$?

assert_ne \
    "test_force_route_to_nonexistent_branch_exits_nonzero: exits non-zero" \
    "0" "$_exit4b"

assert_contains \
    "test_force_route_to_nonexistent_branch_exits_nonzero: stderr contains branch-not-found message" \
    "story/e1/open1" "$_stderr4b"

assert_contains \
    "test_force_route_to_nonexistent_branch_exits_nonzero: stderr contains offending SHA" \
    "$_session_sha4b" "$_stderr4b"

# ══════════════════════════════════════════════════════════════════════════════
# Case 5 — Cherry-pick conflict → abort + exit non-zero + SHA + conflicting paths
# ══════════════════════════════════════════════════════════════════════════════
# Given: target story branch and session branch both modify the same file differently;
#        non-merge commit on session branch has a valid DSO-Story trailer pointing to it
# When:  detect-session-leakage.sh invoked
# Then:  exits non-zero; repo is in clean state (cherry-pick aborted);
#        stderr contains the commit SHA and at least one conflicting path
echo "--- test_cherry_pick_conflict_aborts_and_reports_paths ---"
_repo5=$(make_git_repo)

# Create story branch with conflicting content on shared.txt
git -C "$_repo5" checkout -q -b story/e1/s1
printf "story branch version\n" > "$_repo5/shared.txt"
git -C "$_repo5" add shared.txt
git -C "$_repo5" commit -q -m "story branch: edit shared.txt"
git -C "$_repo5" checkout -q main

# Session branch: modify same file with conflicting content
git -C "$_repo5" checkout -q -b session/test-20260511
printf "session branch version\n" > "$_repo5/shared.txt"
git -C "$_repo5" add shared.txt
git -C "$_repo5" commit -q -m "$(printf 'session: edit shared.txt\n\nDSO-Story: Open Story Title')"
_session_sha5=$(git -C "$_repo5" log --format="%H" -1)

_tmpdir5=$(mktemp -d); _TEST_TMPDIRS+=("$_tmpdir5")
cat > "$_tmpdir5/dso" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  "ticket list --type=story")
    printf '[{"ticket_id":"s1","title":"Open Story Title","status":"open","parent_id":"e1"}]\n'
    ;;
  *)
    exit 0
    ;;
esac
STUB
chmod +x "$_tmpdir5/dso"

_exit5=0
_stderr5=$(
    cd "$_repo5"
    DSO_TICKET_CLI="$_tmpdir5/dso" bash "$_SCRIPT" 2>&1 >/dev/null
) || _exit5=$?

assert_ne \
    "test_cherry_pick_conflict_aborts_and_reports_paths: exits non-zero on conflict" \
    "0" "$_exit5"

# Verify repo is clean (cherry-pick was aborted, no CHERRY_PICK_HEAD)
_cp_head5=$(git -C "$_repo5" rev-parse --verify CHERRY_PICK_HEAD 2>/dev/null || echo "none")
assert_eq \
    "test_cherry_pick_conflict_aborts_and_reports_paths: cherry-pick aborted (repo is clean)" \
    "none" "$_cp_head5"

assert_contains \
    "test_cherry_pick_conflict_aborts_and_reports_paths: stderr contains commit SHA" \
    "$_session_sha5" "$_stderr5"

assert_contains \
    "test_cherry_pick_conflict_aborts_and_reports_paths: stderr contains conflicting file path" \
    "shared.txt" "$_stderr5"

print_summary
