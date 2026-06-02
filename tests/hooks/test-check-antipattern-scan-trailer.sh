#!/usr/bin/env bash
# tests/hooks/test-check-antipattern-scan-trailer.sh
# Behavioral RED tests for plugins/dso/hooks/check-antipattern-scan-trailer.sh
#
# This hook enforces that commits made during a fix-bug session (detected via
# .fix-bug-active marker) include an Antipattern-Scan trailer, and that any
# non-zero matches count is followed up by a ticket id, a cached-diff match
# file, or an inline antipattern-ok annotation.
#
# Observable surfaces tested:
#   - exit code (0 = pass, non-zero = reject)
#   - stderr content (must mention the relevant constraint on rejection)
#
# Trailer grammar (from anti-pattern-scan.md SCAN_RESULT trailer_line field):
#   Antipattern-Scan: <query> root=<scan-root> matches=<n>
#
# AC amendment: at least one test case writes the trailer to
# $GIT_DIR/COMMIT_EDITMSG with NO $1 arg — matching the production
# invocation path used by pre-commit-wrapper.sh.
#
# RED MARKER:
# tests/hooks/test-check-antipattern-scan-trailer.sh [test_trailer_absent_under_fix_bug_active_exits_nonzero]

set -uo pipefail

REPO_ROOT="$(git rev-parse --show-toplevel)"
source "$REPO_ROOT/tests/lib/assert.sh"

TARGET_HOOK="$REPO_ROOT/plugins/dso/hooks/check-antipattern-scan-trailer.sh"

# ---------------------------------------------------------------------------
# RED gate: fail immediately if hook is absent (this is the RED condition)
# ---------------------------------------------------------------------------
if [[ ! -f "$TARGET_HOOK" ]]; then
    printf "FAIL: check-antipattern-scan-trailer.sh does not exist at: %s\n" "$TARGET_HOOK" >&2
    (( ++FAIL ))
    print_summary
fi

# ---------------------------------------------------------------------------
# Isolation helpers
# ---------------------------------------------------------------------------
_TEST_TMPDIRS=()
_cleanup_test_tmpdirs() {
    local d
    for d in "${_TEST_TMPDIRS[@]+"${_TEST_TMPDIRS[@]}"}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap _cleanup_test_tmpdirs EXIT

# make_git_repo — creates a minimal isolated git repo, prints its path.
make_git_repo() {
    local dir
    dir=$(mktemp -d "${TMPDIR:-/tmp}/test-antipattern.XXXXXX")
    _TEST_TMPDIRS+=("$dir")
    git -C "$dir" init -q
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" config commit.gpgsign false
    printf "content\n" > "$dir/file.txt"
    git -C "$dir" add file.txt
    git -C "$dir" commit -q -m "init"
    printf "%s" "$dir"
}

# write_commit_msg_file <repo> <message> — writes the message to a temp file
# AND also writes it to <repo>/.git/COMMIT_EDITMSG (both paths used by tests).
# Returns the path to the temp file.
write_commit_msg_file() {
    local repo="$1" msg="$2"
    local tmpfile
    tmpfile=$(mktemp "${TMPDIR:-/tmp}/test-commit-msg.XXXXXX")
    _TEST_TMPDIRS+=("$tmpfile")
    printf "%s" "$msg" > "$tmpfile"
    printf "%s" "$msg" > "$repo/.git/COMMIT_EDITMSG"
    printf "%s" "$tmpfile"
}

# ---------------------------------------------------------------------------
# Test 1 (trailer-absent): .fix-bug-active marker present, NO trailer → exit nonzero
# ---------------------------------------------------------------------------
echo "--- test_trailer_absent_under_fix_bug_active_exits_nonzero ---"
_repo1=$(make_git_repo)
touch "$_repo1/.fix-bug-active"
_msg_file1=$(write_commit_msg_file "$_repo1" "fix: my change

This commit has no Antipattern-Scan trailer.")
_exit1=0
_out1=$(
    cd "$_repo1" && \
    GIT_DIR="$_repo1/.git" \
    bash "$TARGET_HOOK" "$_msg_file1" 2>&1
) || _exit1=$?
assert_ne "trailer-absent: exit non-zero when .fix-bug-active and no trailer" "0" "$_exit1"
assert_contains "trailer-absent: stderr mentions Antipattern-Scan" "Antipattern-Scan" "$_out1"

# ---------------------------------------------------------------------------
# Test 1b (production path): Same, but trailer read from $GIT_DIR/COMMIT_EDITMSG,
# no $1 arg — mirrors how pre-commit-wrapper.sh invokes the hook in production.
# ---------------------------------------------------------------------------
echo "--- test_trailer_absent_via_git_dir_commit_editmsg_no_arg ---"
_repo1b=$(make_git_repo)
touch "$_repo1b/.fix-bug-active"
printf "fix: my change\n\nNo trailer here.\n" > "$_repo1b/.git/COMMIT_EDITMSG"
_exit1b=0
_out1b=$(
    cd "$_repo1b" && \
    GIT_DIR="$_repo1b/.git" \
    bash "$TARGET_HOOK" 2>&1
) || _exit1b=$?
assert_ne "trailer-absent (no-arg path): exit non-zero when .fix-bug-active and no trailer" "0" "$_exit1b"

# ---------------------------------------------------------------------------
# Test 2 (matches=0): trailer present with matches=0 → exit 0 (no follow-up needed)
# ---------------------------------------------------------------------------
echo "--- test_matches_zero_with_trailer_exits_zero ---"
_repo2=$(make_git_repo)
touch "$_repo2/.fix-bug-active"
_msg2="fix: eliminate duplicate cache reads

Antipattern-Scan: grep -r 'cache.get' root=/path/to/repo matches=0"
_msg_file2=$(write_commit_msg_file "$_repo2" "$_msg2")
_exit2=0
(
    cd "$_repo2" && \
    GIT_DIR="$_repo2/.git" \
    bash "$TARGET_HOOK" "$_msg_file2"
) 2>/dev/null || _exit2=$?
assert_eq "matches=0: exit 0 when trailer present with matches=0" "0" "$_exit2"

# ---------------------------------------------------------------------------
# Test 3 (matches>0, no follow-up): matches=2 but no ticket, no diff file,
# no antipattern-ok annotation → exit non-zero
# ---------------------------------------------------------------------------
echo "--- test_matches_nonzero_no_followup_exits_nonzero ---"
_repo3=$(make_git_repo)
touch "$_repo3/.fix-bug-active"
_msg3="fix: fix broken retry loop

Antipattern-Scan: grep -r 'retry_count' root=/path/to/repo matches=2"
_msg_file3=$(write_commit_msg_file "$_repo3" "$_msg3")
_exit3=0
_out3=$(
    cd "$_repo3" && \
    GIT_DIR="$_repo3/.git" \
    bash "$TARGET_HOOK" "$_msg_file3" 2>&1
) || _exit3=$?
assert_ne "matches>0,no-follow-up: exit non-zero without follow-up artifact" "0" "$_exit3"
assert_contains "matches>0,no-follow-up: stderr mentions follow-up requirement" "follow-up" "$_out3"

# ---------------------------------------------------------------------------
# Test 4a (follow-up via ticket id in trailer): matches=2, ticket id in trailer → exit 0
# ---------------------------------------------------------------------------
echo "--- test_matches_nonzero_satisfied_by_ticket_id_in_trailer ---"
_repo4a=$(make_git_repo)
touch "$_repo4a/.fix-bug-active"
_msg4a="fix: fix broken retry loop

Antipattern-Scan: grep -r 'retry_count' root=/path/to/repo matches=2
Antipattern-Ticket: abcd-1234-efgh-5678"
_msg_file4a=$(write_commit_msg_file "$_repo4a" "$_msg4a")
_exit4a=0
(
    cd "$_repo4a" && \
    GIT_DIR="$_repo4a/.git" \
    bash "$TARGET_HOOK" "$_msg_file4a"
) 2>/dev/null || _exit4a=$?
assert_eq "matches>0,ticket-in-trailer: exit 0 when ticket id satisfies follow-up" "0" "$_exit4a"

# ---------------------------------------------------------------------------
# Test 4b (follow-up via match file in cached diff): matches=2, scan result
# file staged in the cached git diff, AND the file genuinely contains the
# trailer query's pattern (retry_count) → exit 0.
#
# The staged file must contain the pattern from the query so Check 2b's
# strict pattern-match validation is satisfied.
# ---------------------------------------------------------------------------
echo "--- test_matches_nonzero_satisfied_by_match_file_in_cached_diff ---"
_repo4b=$(make_git_repo)
touch "$_repo4b/.fix-bug-active"
# Create a scan-results file whose content includes the pattern 'retry_count'
# (the same pattern used in the Antipattern-Scan trailer query).
mkdir -p "$_repo4b/docs/findings"
printf "Antipattern matches for retry_count:\n  - src/lib/retry.sh:42 uses retry_count variable\n  - src/lib/retry.sh:87 increments retry_count\n" \
    > "$_repo4b/docs/findings/antipattern-matches.txt"
git -C "$_repo4b" add docs/findings/antipattern-matches.txt
_msg4b="fix: fix broken retry loop

Antipattern-Scan: grep -r 'retry_count' root=/path/to/repo matches=2"
_msg_file4b=$(write_commit_msg_file "$_repo4b" "$_msg4b")
_exit4b=0
(
    cd "$_repo4b" && \
    GIT_DIR="$_repo4b/.git" \
    bash "$TARGET_HOOK" "$_msg_file4b"
) 2>/dev/null || _exit4b=$?
assert_eq "matches>0,match-file-in-diff: exit 0 when staged file contains the pattern" "0" "$_exit4b"

# ---------------------------------------------------------------------------
# Test 4b-bypass-closed (bypass-closed case): .fix-bug-active set, trailer
# with matches=2 and a parseable query pattern ('retry_count'), staged ONLY
# an UNRELATED file that does NOT contain the pattern, NO ticket/annotation
# artifact → hook must exit non-zero (bypass is now closed).
#
# This test FAILS on the original hook (which passed any staged file) and
# PASSES after the Check 2b strengthening.
# ---------------------------------------------------------------------------
echo "--- test_bypass_closed_unrelated_staged_file_without_pattern_exits_nonzero ---"
_repo4b2=$(make_git_repo)
touch "$_repo4b2/.fix-bug-active"
# Stage a file that does NOT contain 'retry_count' — completely unrelated content.
mkdir -p "$_repo4b2/docs"
printf "This file is about something else entirely.\nNo match here.\n" \
    > "$_repo4b2/docs/unrelated-notes.txt"
git -C "$_repo4b2" add docs/unrelated-notes.txt
_msg4b2="fix: fix broken retry loop

Antipattern-Scan: grep -r 'retry_count' root=/path/to/repo matches=2"
_msg_file4b2=$(write_commit_msg_file "$_repo4b2" "$_msg4b2")
_exit4b2=0
_out4b2=$(
    cd "$_repo4b2" && \
    GIT_DIR="$_repo4b2/.git" \
    bash "$TARGET_HOOK" "$_msg_file4b2" 2>&1
) || _exit4b2=$?
assert_ne "bypass-closed: unrelated staged file without pattern must not satisfy Check 2b" "0" "$_exit4b2"
assert_contains "bypass-closed: stderr mentions follow-up requirement" "follow-up" "$_out4b2"

# ---------------------------------------------------------------------------
# Test 4c (follow-up via antipattern-ok annotation, different-context): exit 0
# ---------------------------------------------------------------------------
echo "--- test_matches_nonzero_satisfied_by_antipattern_ok_different_context ---"
_repo4c=$(make_git_repo)
touch "$_repo4c/.fix-bug-active"
_msg4c="fix: fix broken retry loop

Antipattern-Scan: grep -r 'retry_count' root=/path/to/repo matches=2
# antipattern-ok: different-context
# antipattern-ok: different-context"
_msg_file4c=$(write_commit_msg_file "$_repo4c" "$_msg4c")
_exit4c=0
(
    cd "$_repo4c" && \
    GIT_DIR="$_repo4c/.git" \
    bash "$TARGET_HOOK" "$_msg_file4c"
) 2>/dev/null || _exit4c=$?
assert_eq "matches>0,antipattern-ok different-context: exit 0" "0" "$_exit4c"

# ---------------------------------------------------------------------------
# Test 4d (follow-up via antipattern-ok annotation, dead-code): exit 0
# ---------------------------------------------------------------------------
echo "--- test_matches_nonzero_satisfied_by_antipattern_ok_dead_code ---"
_repo4d=$(make_git_repo)
touch "$_repo4d/.fix-bug-active"
_msg4d="fix: fix broken retry loop

Antipattern-Scan: grep -r 'retry_count' root=/path/to/repo matches=1
# antipattern-ok: dead-code"
_msg_file4d=$(write_commit_msg_file "$_repo4d" "$_msg4d")
_exit4d=0
(
    cd "$_repo4d" && \
    GIT_DIR="$_repo4d/.git" \
    bash "$TARGET_HOOK" "$_msg_file4d"
) 2>/dev/null || _exit4d=$?
assert_eq "matches>0,antipattern-ok dead-code: exit 0" "0" "$_exit4d"

# ---------------------------------------------------------------------------
# Test 4e (follow-up via antipattern-ok annotation, already-tracked:<id>): exit 0
# ---------------------------------------------------------------------------
echo "--- test_matches_nonzero_satisfied_by_antipattern_ok_already_tracked ---"
_repo4e=$(make_git_repo)
touch "$_repo4e/.fix-bug-active"
_msg4e="fix: fix broken retry loop

Antipattern-Scan: grep -r 'retry_count' root=/path/to/repo matches=1
# antipattern-ok: already-tracked:abcd-1234-efgh-5678"
_msg_file4e=$(write_commit_msg_file "$_repo4e" "$_msg4e")
_exit4e=0
(
    cd "$_repo4e" && \
    GIT_DIR="$_repo4e/.git" \
    bash "$TARGET_HOOK" "$_msg_file4e"
) 2>/dev/null || _exit4e=$?
assert_eq "matches>0,antipattern-ok already-tracked: exit 0" "0" "$_exit4e"

# ---------------------------------------------------------------------------
# Test 4f (antipattern-ok with invalid reason): exit non-zero (invalid reason)
# ---------------------------------------------------------------------------
echo "--- test_antipattern_ok_invalid_reason_exits_nonzero ---"
_repo4f=$(make_git_repo)
touch "$_repo4f/.fix-bug-active"
_msg4f="fix: fix broken retry loop

Antipattern-Scan: grep -r 'retry_count' root=/path/to/repo matches=1
# antipattern-ok: not-a-valid-reason"
_msg_file4f=$(write_commit_msg_file "$_repo4f" "$_msg4f")
_exit4f=0
(
    cd "$_repo4f" && \
    GIT_DIR="$_repo4f/.git" \
    bash "$TARGET_HOOK" "$_msg_file4f"
) 2>/dev/null || _exit4f=$?
assert_ne "antipattern-ok with invalid reason: exit non-zero" "0" "$_exit4f"

# ---------------------------------------------------------------------------
# Test 5 (cap at 3/session): 3 valid antipattern-ok annotations → exit 0;
# 4th antipattern-ok annotation → exit non-zero (cap exceeded).
#
# The cap is enforced per-session. We test it by providing 4 separate
# annotations in a single commit message; the hook must reject when more
# than 3 annotations appear across a session.
# ---------------------------------------------------------------------------
echo "--- test_antipattern_ok_cap_at_3_fourth_exits_nonzero ---"
_repo5=$(make_git_repo)
touch "$_repo5/.fix-bug-active"
# Provide exactly 3 annotations (at cap) — expect exit 0
_msg5_ok="fix: fix broken retry loop

Antipattern-Scan: grep -r 'retry_count' root=/path/to/repo matches=3
# antipattern-ok: different-context
# antipattern-ok: dead-code
# antipattern-ok: already-tracked:abcd-1234-efgh-5678"
_msg_file5_ok=$(write_commit_msg_file "$_repo5" "$_msg5_ok")
_exit5_ok=0
(
    cd "$_repo5" && \
    GIT_DIR="$_repo5/.git" \
    bash "$TARGET_HOOK" "$_msg_file5_ok"
) 2>/dev/null || _exit5_ok=$?
assert_eq "cap: exactly 3 annotations at cap threshold → exit 0" "0" "$_exit5_ok"

# Now provide 4 annotations (over cap) — expect exit non-zero
echo "--- test_antipattern_ok_cap_exceeded_4th_annotation_exits_nonzero ---"
_repo5b=$(make_git_repo)
touch "$_repo5b/.fix-bug-active"
_msg5_over="fix: fix broken retry loop

Antipattern-Scan: grep -r 'retry_count' root=/path/to/repo matches=4
# antipattern-ok: different-context
# antipattern-ok: dead-code
# antipattern-ok: already-tracked:abcd-1234
# antipattern-ok: different-context"
_msg_file5_over=$(write_commit_msg_file "$_repo5b" "$_msg5_over")
_exit5_over=0
_out5_over=$(
    cd "$_repo5b" && \
    GIT_DIR="$_repo5b/.git" \
    bash "$TARGET_HOOK" "$_msg_file5_over" 2>&1
) || _exit5_over=$?
assert_ne "cap: 4 annotations exceeds 3/session cap → exit non-zero" "0" "$_exit5_over"
assert_contains "cap: stderr mentions annotation cap" "cap" "$_out5_over"

# ---------------------------------------------------------------------------
# Test 6 (no .fix-bug-active marker): hook exits 0 regardless of trailer state.
# The hook must never gate commits made outside a fix-bug session.
# ---------------------------------------------------------------------------
echo "--- test_no_fix_bug_active_marker_always_exits_zero ---"
_repo6=$(make_git_repo)
# Intentionally do NOT create .fix-bug-active
_msg6="fix: a random commit with no trailer at all"
_msg_file6=$(write_commit_msg_file "$_repo6" "$_msg6")
_exit6=0
(
    cd "$_repo6" && \
    GIT_DIR="$_repo6/.git" \
    bash "$TARGET_HOOK" "$_msg_file6"
) 2>/dev/null || _exit6=$?
assert_eq "no fix-bug-active marker: exit 0 (hook is a no-op outside fix-bug)" "0" "$_exit6"

# Also verify via $GIT_DIR/COMMIT_EDITMSG no-arg path
echo "--- test_no_fix_bug_active_via_commit_editmsg_no_arg_exits_zero ---"
_repo6b=$(make_git_repo)
printf "fix: another commit no trailer\n" > "$_repo6b/.git/COMMIT_EDITMSG"
_exit6b=0
(
    cd "$_repo6b" && \
    GIT_DIR="$_repo6b/.git" \
    bash "$TARGET_HOOK"
) 2>/dev/null || _exit6b=$?
assert_eq "no fix-bug-active (no-arg path): exit 0 outside fix-bug" "0" "$_exit6b"

print_summary
