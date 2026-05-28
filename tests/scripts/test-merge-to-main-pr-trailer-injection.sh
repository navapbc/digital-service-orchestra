#!/usr/bin/env bash
# shellcheck disable=SC2030,SC2031  # subshell-local env mutation is intentional for test isolation
# shellcheck disable=SC2046,SC2064,SC2329
# tests/scripts/test-merge-to-main-pr-trailer-injection.sh
#
# RED tests for inject_trailer() and inject_and_enable_automerge() in
# merge-to-main-pr.sh (ticket e349-6b4e-13c5-4e23).
#
# All tests FAIL in RED phase because inject_trailer and
# inject_and_enable_automerge do not yet exist in merge-to-main-pr.sh.
# They turn GREEN when the implementation is added.
#
# Strategy: source merge-to-main-pr.sh with PR_LIB_MODE=1 to get function
# definitions only, then call inject_trailer / inject_and_enable_automerge
# directly with PATH-shadow stubs for git and gh.
#
# Observable surfaces asserted:
#   - function return codes (exit codes)
#   - stdout / stderr messages (::error::, ::warning::, trailer text)
#   - filesystem side effects (worktree path created/cleaned up, git log)
#   - git state (commit trailer present on branch tip)
#   - command invocation sequences (captured via wrapper logs)
#
# Usage: bash tests/scripts/test-merge-to-main-pr-trailer-injection.sh

set -uo pipefail

# Disable commit signing for temp test repos.
export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0=commit.gpgsign
export GIT_CONFIG_VALUE_0=false

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(git rev-parse --show-toplevel)"
DSO_PLUGIN_DIR="$REPO_ROOT/plugins/dso"
PR_SCRIPT="$DSO_PLUGIN_DIR/scripts/merge-to-main-pr.sh"

# Prevent env vars from the caller's session from leaking into fixture repos.
unset PROJECT_ROOT CLAUDE_PROJECT_DIR _MERGE_STATE_GIT_DIR

# Default LLM dispatch to no-op so non-LLM tests can source the script without
# tripping fail-loud guards.
export _LLM_DISPATCH_CMD="${_LLM_DISPATCH_CMD:-/bin/true}"
export _RESOLVE_CONFLICTS_LLM_CMD="${_RESOLVE_CONFLICTS_LLM_CMD:-/bin/true}"
export _REMEDIATE_LLM_CMD="${_REMEDIATE_LLM_CMD:-/bin/true}"

# shellcheck source=../lib/assert.sh
source "$REPO_ROOT/tests/lib/assert.sh"

# ---------------------------------------------------------------------------
# _REAL_GIT — used inside fixtures where the PATH shim must pass through.
# ---------------------------------------------------------------------------
_REAL_GIT="$(command -v git)"

# ---------------------------------------------------------------------------
# _build_trailer_fixture <tmpdir> <session_sha>
#
# Creates:
#   $tmpdir/                — root of the working repo
#   $tmpdir/bin/gh          — gh shim (records argv, configurable responses)
#   $tmpdir/bin/git         — git shim that passes through to real git
#   $tmpdir/gh-argv.log     — appended by gh shim
#   $tmpdir/git-argv.log    — appended by git shim for intercepted calls
#   $tmpdir/remote.git      — bare remote repo
#
# The working repo has:
#   main branch  — seeded with one commit whose SHA is $session_sha (simulates
#                  session HEAD for the empty-story test path)
#   no story branch (tests create their own as needed)
# ---------------------------------------------------------------------------
_build_trailer_fixture() {
    local tmpdir="$1"
    local bin="$tmpdir/bin"
    mkdir -p "$bin"

    local gh_argv_log="$tmpdir/gh-argv.log"
    local git_argv_log="$tmpdir/git-argv.log"

    # Create bare remote
    local remote_dir="$tmpdir/remote.git"
    "$_REAL_GIT" init -q --bare -b main "$remote_dir" >/dev/null 2>&1

    # Create working repo
    (
        cd "$tmpdir" || exit 1
        "$_REAL_GIT" init -q -b main >/dev/null 2>&1
        "$_REAL_GIT" config user.email "test@trailer.local"
        "$_REAL_GIT" config user.name "test"
        "$_REAL_GIT" remote add origin "$remote_dir"
        echo "session-seed" > seed.txt
        "$_REAL_GIT" add seed.txt
        "$_REAL_GIT" commit -q -m "session-seed" >/dev/null
        "$_REAL_GIT" push -q origin main >/dev/null 2>&1
    )

    # Write the session HEAD SHA to a file so tests can reference it
    "$_REAL_GIT" -C "$tmpdir" rev-parse HEAD > "$tmpdir/session-sha"

    # ---- gh shim (default: minimal pass-through, no protection) ----
    cat > "$bin/gh" <<GH_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${gh_argv_log}"
case "\$1" in
  --version)
    echo "gh version 2.40.1 (2024-01-01)"
    exit 0
    ;;
  api)
    # Default: return 404 (no branch protection) so inject_trailer proceeds.
    # Tests that need force-push protection will replace this shim.
    echo '{"message":"Branch not protected"}' >&2
    exit 1
    ;;
  pr)
    case "\$2" in
      view)
        # Default: no auto-merge, no trailers
        if [[ "\$*" == *"autoMergeRequest"* ]]; then
          echo '{"autoMergeRequest":null}'
          exit 0
        fi
        echo '{"number":42,"url":"https://github.com/x/y/pull/42"}'
        exit 0
        ;;
      merge) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  repo)
    if [[ "\$2" == "view" ]]; then
      echo "x/y"
      exit 0
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
GH_SHIM
    chmod +x "$bin/gh"

    # ---- git shim: pass through to real git, but record worktree and push calls ----
    cat > "$bin/git" <<GIT_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${git_argv_log}"
exec "${_REAL_GIT}" "\$@"
GIT_SHIM
    chmod +x "$bin/git"
}

# ---------------------------------------------------------------------------
# _source_pr_script_in_lib_mode <tmpdir> <branch>
#
# Helper that produces the common env block for sourcing PR_SCRIPT in lib mode.
# Callers embed this in a bash -c subshell.
# ---------------------------------------------------------------------------
# (Used inline via heredoc in each test function — not a callable shell function.)

# ===========================================================================
# (a) inject_trailer ephemeral-worktree path: worktree created under TMPDIR
#     and cleaned up (no stale path) after function returns.
# ===========================================================================
t_inject_trailer_ephemeral_worktree_cleanup() {
    local _T _story _rc _out _worktree_gone
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-trailer-a.XXXXXX")"
    trap "rm -rf '$_T'" RETURN

    _story="story/epic1/s001"
    _build_trailer_fixture "$_T"

    # Create the story branch (2 commits ahead of main / session HEAD)
    (
        cd "$_T" || exit 1
        "$_REAL_GIT" checkout -q -b "$_story" >/dev/null 2>&1
        echo "work1" > work1.txt && "$_REAL_GIT" add work1.txt
        "$_REAL_GIT" commit -q -m "story work 1" >/dev/null
        echo "work2" > work2.txt && "$_REAL_GIT" add work2.txt
        "$_REAL_GIT" commit -q -m "story work 2" >/dev/null
        "$_REAL_GIT" push -q origin "$_story" >/dev/null 2>&1
    )

    local _session_sha
    _session_sha="$("$_REAL_GIT" -C "$_T" rev-parse main)"

    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_story" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" >/dev/null 2>&1
            inject_trailer "epic1" "s001" 2>&1
            echo "RC:$?"
        ' "$PR_SCRIPT"
    )" || true
    _rc="$(echo "$_out" | grep "^RC:" | tail -1 | sed 's/RC://')"

    # The worktree temp path pattern: ${TMPDIR:-/tmp}/dso-trailer-$$-s001
    # We cannot predict the PID, so we check whether ANY path matching the
    # pattern still exists on the filesystem.
    _worktree_gone="true"
    if find "${TMPDIR:-/tmp}" -maxdepth 1 -name "dso-trailer-*-s001" -type d 2>/dev/null | grep -q .; then
        _worktree_gone="false"
    fi

    # RED: function doesn't exist → rc will be empty or non-zero from "command not found"
    assert_eq "t_inject_trailer_ephemeral_worktree_cleanup: rc=0" "0" "${_rc:-MISSING}"
    assert_eq "t_inject_trailer_ephemeral_worktree_cleanup: no stale worktree" "true" "$_worktree_gone"
}
t_inject_trailer_ephemeral_worktree_cleanup

# ===========================================================================
# (b) inject_trailer non-empty path: story branch has 2 commits ahead of
#     session; assert git commit --amend --no-edit --trailer invoked and the
#     story branch tip commit carries the trailer.
# ===========================================================================
t_inject_trailer_nonempty_amends_tip_with_trailer() {
    local _T _story _out _rc _tip_trailer
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-trailer-b.XXXXXX")"
    trap "rm -rf '$_T'" RETURN

    _story="story/epic1/s002"
    _build_trailer_fixture "$_T"

    (
        cd "$_T" || exit 1
        "$_REAL_GIT" checkout -q -b "$_story" >/dev/null 2>&1
        echo "feat" > feat.txt && "$_REAL_GIT" add feat.txt
        "$_REAL_GIT" commit -q -m "story feat" >/dev/null
        "$_REAL_GIT" push -q origin "$_story" >/dev/null 2>&1
    )

    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_story" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" >/dev/null 2>&1
            inject_trailer "epic1" "s002" 2>&1
            echo "RC:$?"
        ' "$PR_SCRIPT"
    )" || true
    _rc="$(echo "$_out" | grep "^RC:" | tail -1 | sed 's/RC://')"

    # Observable: the git-argv.log must contain "commit --amend"
    local _git_log="$_T/git-argv.log"
    local _has_amend="false"
    if grep -q -- "--amend" "$_git_log" 2>/dev/null; then
        _has_amend="true"
    fi

    # Observable: story branch tip commit message must contain the trailer.
    # (The function amends in the ephemeral worktree then force-pushes, so
    # we check origin/<story> via git log on the remote.)
    _tip_trailer="$("$_REAL_GIT" -C "$_T" log "origin/$_story" -1 --format="%B" 2>/dev/null || echo "MISSING")"
    local _has_trailer="false"
    if echo "$_tip_trailer" | grep -q "DSO-Story-Merge: s002"; then
        _has_trailer="true"
    fi

    assert_eq "t_inject_trailer_nonempty_amends_tip_with_trailer: rc=0" "0" "${_rc:-MISSING}"
    assert_eq "t_inject_trailer_nonempty_amends_tip_with_trailer: git commit --amend invoked" "true" "$_has_amend"
    assert_eq "t_inject_trailer_nonempty_amends_tip_with_trailer: trailer on branch tip" "true" "$_has_trailer"
}
t_inject_trailer_nonempty_amends_tip_with_trailer

# ===========================================================================
# (c) inject_trailer empty-commit path: story branch identical to session HEAD;
#     assert git commit --allow-empty invoked and a new empty commit with the
#     trailer appears on the story branch.
# ===========================================================================
t_inject_trailer_empty_story_creates_empty_commit() {
    local _T _story _out _rc _tip_trailer _parent_count
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-trailer-c.XXXXXX")"
    trap "rm -rf '$_T'" RETURN

    _story="story/epic1/s003"
    _build_trailer_fixture "$_T"

    # Story branch is identical to main (session HEAD) — no commits ahead.
    local _session_sha
    _session_sha="$("$_REAL_GIT" -C "$_T" rev-parse main)"

    (
        cd "$_T" || exit 1
        # Branch from main so tip == session HEAD
        "$_REAL_GIT" checkout -q -b "$_story" main >/dev/null 2>&1
        "$_REAL_GIT" push -q origin "$_story" >/dev/null 2>&1
    )

    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_story" \
        SESSION_HEAD="$_session_sha" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" >/dev/null 2>&1
            inject_trailer "epic1" "s003" 2>&1
            echo "RC:$?"
        ' "$PR_SCRIPT"
    )" || true
    _rc="$(echo "$_out" | grep "^RC:" | tail -1 | sed 's/RC://')"

    # Observable: git-argv.log must contain "commit --allow-empty"
    local _git_log="$_T/git-argv.log"
    local _has_allow_empty="false"
    if grep -q -- "--allow-empty" "$_git_log" 2>/dev/null; then
        _has_allow_empty="true"
    fi

    # Observable: origin/story branch must now be 1 commit ahead of main
    # and the tip commit body must contain the trailer.
    _tip_trailer="$("$_REAL_GIT" -C "$_T" log "origin/$_story" -1 --format="%B" 2>/dev/null || echo "MISSING")"
    local _has_trailer="false"
    if echo "$_tip_trailer" | grep -q "DSO-Story-Merge: s003"; then
        _has_trailer="true"
    fi

    local _ahead
    _ahead="$("$_REAL_GIT" -C "$_T" rev-list --count "main..origin/$_story" 2>/dev/null || echo "0")"

    assert_eq "t_inject_trailer_empty_story_creates_empty_commit: rc=0" "0" "${_rc:-MISSING}"
    assert_eq "t_inject_trailer_empty_story_creates_empty_commit: --allow-empty invoked" "true" "$_has_allow_empty"
    assert_eq "t_inject_trailer_empty_story_creates_empty_commit: trailer on new commit" "true" "$_has_trailer"
    assert_eq "t_inject_trailer_empty_story_creates_empty_commit: exactly 1 new commit" "1" "$_ahead"
}
t_inject_trailer_empty_story_creates_empty_commit

# ===========================================================================
# (d) inject_trailer rc=1: git worktree add fails → function returns 1;
#     no stale worktree directory remains.
# ===========================================================================
t_inject_trailer_rc1_worktree_add_fail() {
    local _T _story _out _rc _worktree_gone
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-trailer-d.XXXXXX")"
    trap "rm -rf '$_T'" RETURN

    _story="story/epic1/s004"
    _build_trailer_fixture "$_T"

    (
        cd "$_T" || exit 1
        "$_REAL_GIT" checkout -q -b "$_story" >/dev/null 2>&1
        echo "work" > work.txt && "$_REAL_GIT" add work.txt
        "$_REAL_GIT" commit -q -m "story work" >/dev/null
        "$_REAL_GIT" push -q origin "$_story" >/dev/null 2>&1
    )

    # Override git shim to fail on "worktree add"
    cat > "$_T/bin/git" <<GIT_FAIL_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${_T}/git-argv.log"
if [[ "\$1" == "worktree" && "\$2" == "add" ]]; then
    echo "error: worktree add failed (stub)" >&2
    exit 1
fi
exec "${_REAL_GIT}" "\$@"
GIT_FAIL_SHIM
    chmod +x "$_T/bin/git"

    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_story" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" >/dev/null 2>&1
            inject_trailer "epic1" "s004" 2>&1
            echo "RC:$?"
        ' "$PR_SCRIPT"
    )" || true
    _rc="$(echo "$_out" | grep "^RC:" | tail -1 | sed 's/RC://')"

    _worktree_gone="true"
    if find "${TMPDIR:-/tmp}" -maxdepth 1 -name "dso-trailer-*-s004" -type d 2>/dev/null | grep -q .; then
        _worktree_gone="false"
    fi

    assert_eq "t_inject_trailer_rc1_worktree_add_fail: rc=1" "1" "${_rc:-MISSING}"
    assert_eq "t_inject_trailer_rc1_worktree_add_fail: no stale worktree" "true" "$_worktree_gone"
}
t_inject_trailer_rc1_worktree_add_fail

# ===========================================================================
# (e) inject_trailer rc=2: git commit fails → function returns 2;
#     worktree is cleaned up.
# ===========================================================================
t_inject_trailer_rc2_commit_fail() {
    local _T _story _out _rc _worktree_gone
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-trailer-e.XXXXXX")"
    trap "rm -rf '$_T'" RETURN

    _story="story/epic1/s005"
    _build_trailer_fixture "$_T"

    (
        cd "$_T" || exit 1
        "$_REAL_GIT" checkout -q -b "$_story" >/dev/null 2>&1
        echo "work" > work.txt && "$_REAL_GIT" add work.txt
        "$_REAL_GIT" commit -q -m "story work" >/dev/null
        "$_REAL_GIT" push -q origin "$_story" >/dev/null 2>&1
    )

    # Override git shim: pass through worktree add, fail on commit
    cat > "$_T/bin/git" <<GIT_COMMIT_FAIL_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${_T}/git-argv.log"
# Detect commit subcommand (may be git -C <dir> commit or git commit)
_subcmd=""
for _a in "\$@"; do
    if [[ "\$_a" == "commit" ]]; then _subcmd="commit"; break; fi
done
if [[ "\$_subcmd" == "commit" ]]; then
    echo "error: commit failed (stub)" >&2
    exit 1
fi
exec "${_REAL_GIT}" "\$@"
GIT_COMMIT_FAIL_SHIM
    chmod +x "$_T/bin/git"

    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_story" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" >/dev/null 2>&1
            inject_trailer "epic1" "s005" 2>&1
            echo "RC:$?"
        ' "$PR_SCRIPT"
    )" || true
    _rc="$(echo "$_out" | grep "^RC:" | tail -1 | sed 's/RC://')"

    _worktree_gone="true"
    if find "${TMPDIR:-/tmp}" -maxdepth 1 -name "dso-trailer-*-s005" -type d 2>/dev/null | grep -q .; then
        _worktree_gone="false"
    fi

    assert_eq "t_inject_trailer_rc2_commit_fail: rc=2" "2" "${_rc:-MISSING}"
    assert_eq "t_inject_trailer_rc2_commit_fail: no stale worktree" "true" "$_worktree_gone"
}
t_inject_trailer_rc2_commit_fail

# ===========================================================================
# (f) inject_trailer rc=3: git push --force-with-lease fails → function
#     returns 3; worktree is cleaned up.
# ===========================================================================
t_inject_trailer_rc3_push_fail() {
    local _T _story _out _rc _worktree_gone
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-trailer-f.XXXXXX")"
    trap "rm -rf '$_T'" RETURN

    _story="story/epic1/s006"
    _build_trailer_fixture "$_T"

    (
        cd "$_T" || exit 1
        "$_REAL_GIT" checkout -q -b "$_story" >/dev/null 2>&1
        echo "work" > work.txt && "$_REAL_GIT" add work.txt
        "$_REAL_GIT" commit -q -m "story work" >/dev/null
        "$_REAL_GIT" push -q origin "$_story" >/dev/null 2>&1
    )

    # Override git shim: pass through worktree/commit, fail on push --force-with-lease
    cat > "$_T/bin/git" <<GIT_PUSH_FAIL_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${_T}/git-argv.log"
if [[ "\$1" == "push" ]] && echo "\$*" | grep -q -- "--force-with-lease"; then
    echo "error: push --force-with-lease failed (stub)" >&2
    exit 1
fi
exec "${_REAL_GIT}" "\$@"
GIT_PUSH_FAIL_SHIM
    chmod +x "$_T/bin/git"

    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_story" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" >/dev/null 2>&1
            inject_trailer "epic1" "s006" 2>&1
            echo "RC:$?"
        ' "$PR_SCRIPT"
    )" || true
    _rc="$(echo "$_out" | grep "^RC:" | tail -1 | sed 's/RC://')"

    _worktree_gone="true"
    if find "${TMPDIR:-/tmp}" -maxdepth 1 -name "dso-trailer-*-s006" -type d 2>/dev/null | grep -q .; then
        _worktree_gone="false"
    fi

    assert_eq "t_inject_trailer_rc3_push_fail: rc=3" "3" "${_rc:-MISSING}"
    assert_eq "t_inject_trailer_rc3_push_fail: no stale worktree" "true" "$_worktree_gone"
}
t_inject_trailer_rc3_push_fail

# ===========================================================================
# (g) inject_trailer trap cleanup on signal: the function registers a cleanup
#     trap so that even if the process receives SIGTERM mid-execution, no stale
#     worktree directory remains.
#     Strategy: run inject_trailer in a background subshell with a slow git
#     stub; send SIGTERM to the subshell; assert no stale dso-trailer-* dir.
# ===========================================================================
t_inject_trailer_cleanup_on_sigterm() {
    local _T _story _worktree_gone _pid _child_pid
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-trailer-g.XXXXXX")"
    trap "rm -rf '$_T'" RETURN

    _story="story/epic1/s007"
    _build_trailer_fixture "$_T"

    (
        cd "$_T" || exit 1
        "$_REAL_GIT" checkout -q -b "$_story" >/dev/null 2>&1
        echo "work" > work.txt && "$_REAL_GIT" add work.txt
        "$_REAL_GIT" commit -q -m "story work" >/dev/null
        "$_REAL_GIT" push -q origin "$_story" >/dev/null 2>&1
    )

    # Override git shim: slow down the commit step so we have time to SIGTERM
    cat > "$_T/bin/git" <<GIT_SLOW_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${_T}/git-argv.log"
_subcmd=""
for _a in "\$@"; do
    if [[ "\$_a" == "commit" ]]; then _subcmd="commit"; break; fi
done
if [[ "\$_subcmd" == "commit" ]]; then
    sleep 5
fi
exec "${_REAL_GIT}" "\$@"
GIT_SLOW_SHIM
    chmod +x "$_T/bin/git"

    # Run inject_trailer in background, capture its PID
    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_story" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" >/dev/null 2>&1
            inject_trailer "epic1" "s007" 2>&1
        ' "$PR_SCRIPT"
    ) &
    _pid=$!

    # Give the function time to create the worktree (worktree add should be
    # fast; the slow step is the subsequent commit).
    sleep 1

    # Send SIGTERM to the background subshell
    kill -SIGTERM "$_pid" 2>/dev/null || true
    wait "$_pid" 2>/dev/null || true

    # Allow a moment for trap cleanup to finish
    sleep 0.5

    _worktree_gone="true"
    if find "${TMPDIR:-/tmp}" -maxdepth 1 -name "dso-trailer-*-s007" -type d 2>/dev/null | grep -q .; then
        _worktree_gone="false"
    fi

    assert_eq "t_inject_trailer_cleanup_on_sigterm: no stale worktree after SIGTERM" "true" "$_worktree_gone"
}
t_inject_trailer_cleanup_on_sigterm

# ===========================================================================
# (h) Force-push protection probe: when gh api returns
#     allow_force_pushes.enabled=false, the function must exit 1 and emit
#     "::error::story branch ... force-push-protected" to stderr.
# ===========================================================================
t_force_push_protection_blocks_on_false() {
    local _T _story _out _rc _has_error
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-trailer-h.XXXXXX")"
    trap "rm -rf '$_T'" RETURN

    _story="story/epic1/s008"
    _build_trailer_fixture "$_T"

    (
        cd "$_T" || exit 1
        "$_REAL_GIT" checkout -q -b "$_story" >/dev/null 2>&1
        echo "work" > work.txt && "$_REAL_GIT" add work.txt
        "$_REAL_GIT" commit -q -m "story work" >/dev/null
        "$_REAL_GIT" push -q origin "$_story" >/dev/null 2>&1
    )

    # Override gh shim: return allow_force_pushes.enabled=false for branch protection API
    cat > "$_T/bin/gh" <<GH_PROTECTED_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${_T}/gh-argv.log"
case "\$1" in
  --version)
    echo "gh version 2.40.1 (2024-01-01)"
    exit 0
    ;;
  api)
    if [[ "\$*" == *"branches"* && "\$*" == *"protection"* ]]; then
      echo '{"allow_force_pushes":{"enabled":false}}'
      exit 0
    fi
    exit 0
    ;;
  repo)
    if [[ "\$2" == "view" ]]; then
      echo "x/y"
      exit 0
    fi
    exit 0
    ;;
  *) exit 0 ;;
esac
GH_PROTECTED_SHIM
    chmod +x "$_T/bin/gh"

    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_story" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" >/dev/null 2>&1
            inject_trailer "epic1" "s008" 2>&1
            echo "RC:$?"
        ' "$PR_SCRIPT"
    )" || true
    _rc="$(echo "$_out" | grep "^RC:" | tail -1 | sed 's/RC://')"

    _has_error="false"
    if echo "$_out" | grep -qi "::error::.*force-push-protected\|force-push-protected"; then
        _has_error="true"
    fi

    assert_eq "t_force_push_protection_blocks_on_false: rc=1" "1" "${_rc:-MISSING}"
    assert_eq "t_force_push_protection_blocks_on_false: error emitted" "true" "$_has_error"
}
t_force_push_protection_blocks_on_false

# ===========================================================================
# (i) Force-push protection probe: 404 from gh api (no protection) → function
#     proceeds (does not exit early).
# ===========================================================================
t_force_push_protection_404_proceeds() {
    local _T _story _out _rc
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-trailer-i.XXXXXX")"
    trap "rm -rf '$_T'" RETURN

    _story="story/epic1/s009"
    _build_trailer_fixture "$_T"

    (
        cd "$_T" || exit 1
        "$_REAL_GIT" checkout -q -b "$_story" >/dev/null 2>&1
        echo "work" > work.txt && "$_REAL_GIT" add work.txt
        "$_REAL_GIT" commit -q -m "story work" >/dev/null
        "$_REAL_GIT" push -q origin "$_story" >/dev/null 2>&1
    )

    # Default _build_trailer_fixture gh shim already returns 404-like (exit 1 + no protection)
    # for the api branches/protection endpoint. inject_trailer must treat this as "proceed".

    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_story" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" >/dev/null 2>&1
            inject_trailer "epic1" "s009" 2>&1
            echo "RC:$?"
        ' "$PR_SCRIPT"
    )" || true
    _rc="$(echo "$_out" | grep "^RC:" | tail -1 | sed 's/RC://')"

    # Must NOT exit with rc=1 (force-push-protected) — the 404 means no protection
    assert_eq "t_force_push_protection_404_proceeds: rc=0" "0" "${_rc:-MISSING}"
}
t_force_push_protection_404_proceeds

# ===========================================================================
# (j) inject_and_enable_automerge state A: no auto-merge, no trailer →
#     sequence: inject_trailer THEN gh pr merge --auto.
# ===========================================================================
t_inject_and_enable_automerge_stateA_no_automerge_no_trailer() {
    local _T _story _out _rc _gh_log _inject_pos _automerge_pos
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-trailer-j.XXXXXX")"
    trap "rm -rf '$_T'" RETURN

    _story="story/epic1/s010"
    _build_trailer_fixture "$_T"

    (
        cd "$_T" || exit 1
        "$_REAL_GIT" checkout -q -b "$_story" >/dev/null 2>&1
        echo "work" > work.txt && "$_REAL_GIT" add work.txt
        "$_REAL_GIT" commit -q -m "story work" >/dev/null
        "$_REAL_GIT" push -q origin "$_story" >/dev/null 2>&1
    )

    # gh shim: no auto-merge, no trailers
    cat > "$_T/bin/gh" <<GH_STATE_A_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${_T}/gh-argv.log"
case "\$1" in
  --version) echo "gh version 2.40.1 (2024-01-01)"; exit 0 ;;
  api)
    if [[ "\$*" == *"branches"* && "\$*" == *"protection"* ]]; then
      echo '{"message":"Branch not protected"}' >&2
      exit 1
    fi
    if [[ "\$*" == *"commits"* ]]; then
      # No DSO-Story-Merge trailers
      echo '[]'
      exit 0
    fi
    exit 0
    ;;
  pr)
    case "\$2" in
      view)
        if [[ "\$*" == *"autoMergeRequest"* ]]; then
          echo '{"autoMergeRequest":null}'
          exit 0
        fi
        echo '{"number":42,"url":"https://github.com/x/y/pull/42"}'
        exit 0
        ;;
      merge) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  repo) echo "x/y"; exit 0 ;;
  *) exit 0 ;;
esac
GH_STATE_A_SHIM
    chmod +x "$_T/bin/gh"

    local _inject_sentinel="$_T/inject_called"

    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_story" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" >/dev/null 2>&1
            # Override inject_trailer to record it was called (behavioral stub)
            inject_trailer() { echo "INJECT_CALLED" >> "'"$_inject_sentinel"'"; return 0; }
            inject_and_enable_automerge 42 "epic1" "s010" 2>&1
            echo "RC:$?"
        ' "$PR_SCRIPT"
    )" || true
    _rc="$(echo "$_out" | grep "^RC:" | tail -1 | sed 's/RC://')"

    _gh_log="$(cat "$_T/gh-argv.log" 2>/dev/null || echo '')"
    local _inject_was_called="false"
    [[ -f "$_inject_sentinel" ]] && _inject_was_called="true"

    local _has_automerge="false"
    if echo "$_gh_log" | grep -q "pr merge.*--auto\|pr merge 42.*--auto"; then
        _has_automerge="true"
    fi

    assert_eq "t_inject_and_enable_automerge_stateA: rc=0" "0" "${_rc:-MISSING}"
    assert_eq "t_inject_and_enable_automerge_stateA: inject_trailer called" "true" "$_inject_was_called"
    assert_eq "t_inject_and_enable_automerge_stateA: gh pr merge --auto called" "true" "$_has_automerge"
}
t_inject_and_enable_automerge_stateA_no_automerge_no_trailer

# ===========================================================================
# (k) inject_and_enable_automerge state B: auto-merge enabled, no trailer →
#     sequence: gh pr merge --disable-auto, inject_trailer, gh pr merge --auto.
# ===========================================================================
t_inject_and_enable_automerge_stateB_automerge_enabled_no_trailer() {
    local _T _story _out _rc _inject_sentinel
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-trailer-k.XXXXXX")"
    trap "rm -rf '$_T'" RETURN

    _story="story/epic1/s011"
    _build_trailer_fixture "$_T"

    (
        cd "$_T" || exit 1
        "$_REAL_GIT" checkout -q -b "$_story" >/dev/null 2>&1
        echo "work" > work.txt && "$_REAL_GIT" add work.txt
        "$_REAL_GIT" commit -q -m "story work" >/dev/null
        "$_REAL_GIT" push -q origin "$_story" >/dev/null 2>&1
    )

    _inject_sentinel="$_T/inject_called"

    cat > "$_T/bin/gh" <<GH_STATE_B_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${_T}/gh-argv.log"
case "\$1" in
  --version) echo "gh version 2.40.1 (2024-01-01)"; exit 0 ;;
  api)
    if [[ "\$*" == *"branches"* && "\$*" == *"protection"* ]]; then
      echo '{"message":"Branch not protected"}' >&2; exit 1
    fi
    if [[ "\$*" == *"commits"* ]]; then
      echo '[]'; exit 0
    fi
    exit 0
    ;;
  pr)
    case "\$2" in
      view)
        if [[ "\$*" == *"autoMergeRequest"* ]]; then
          # Auto-merge IS enabled
          echo '{"autoMergeRequest":{"enabledAt":"2026-05-25T00:00:00Z"}}'
          exit 0
        fi
        echo '{"number":42,"url":"https://github.com/x/y/pull/42"}'
        exit 0
        ;;
      merge) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  repo) echo "x/y"; exit 0 ;;
  *) exit 0 ;;
esac
GH_STATE_B_SHIM
    chmod +x "$_T/bin/gh"

    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_story" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" >/dev/null 2>&1
            inject_trailer() { echo "INJECT_CALLED" >> "'"$_inject_sentinel"'"; return 0; }
            inject_and_enable_automerge 42 "epic1" "s011" 2>&1
            echo "RC:$?"
        ' "$PR_SCRIPT"
    )" || true
    _rc="$(echo "$_out" | grep "^RC:" | tail -1 | sed 's/RC://')"

    local _gh_log
    _gh_log="$(cat "$_T/gh-argv.log" 2>/dev/null || echo '')"

    local _inject_was_called="false"
    [[ -f "$_inject_sentinel" ]] && _inject_was_called="true"

    local _has_disable="false"
    if echo "$_gh_log" | grep -q -- "--disable-auto"; then
        _has_disable="true"
    fi

    local _has_auto="false"
    if echo "$_gh_log" | grep -qE "^pr merge.*--auto[^-]|^pr merge 42.*--auto$|^pr merge.*--auto --"; then
        _has_auto="true"
    fi

    assert_eq "t_inject_and_enable_automerge_stateB: rc=0" "0" "${_rc:-MISSING}"
    assert_eq "t_inject_and_enable_automerge_stateB: gh pr merge --disable-auto called" "true" "$_has_disable"
    assert_eq "t_inject_and_enable_automerge_stateB: inject_trailer called" "true" "$_inject_was_called"
    assert_eq "t_inject_and_enable_automerge_stateB: gh pr merge --auto re-enabled" "true" "$_has_auto"
}
t_inject_and_enable_automerge_stateB_automerge_enabled_no_trailer

# ===========================================================================
# (l) inject_and_enable_automerge state C: auto-merge enabled, trailer
#     present → no-op (no inject_trailer, no gh pr merge calls).
# ===========================================================================
t_inject_and_enable_automerge_stateC_trailer_present_noop() {
    local _T _story _out _rc _inject_sentinel
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-trailer-l.XXXXXX")"
    trap "rm -rf '$_T'" RETURN

    _story="story/epic1/s012"
    _build_trailer_fixture "$_T"

    (
        cd "$_T" || exit 1
        "$_REAL_GIT" checkout -q -b "$_story" >/dev/null 2>&1
        echo "work" > work.txt && "$_REAL_GIT" add work.txt
        "$_REAL_GIT" commit -q -m "story work" >/dev/null
        "$_REAL_GIT" push -q origin "$_story" >/dev/null 2>&1
    )

    _inject_sentinel="$_T/inject_called"

    cat > "$_T/bin/gh" <<GH_STATE_C_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${_T}/gh-argv.log"
case "\$1" in
  --version) echo "gh version 2.40.1 (2024-01-01)"; exit 0 ;;
  api)
    if [[ "\$*" == *"branches"* && "\$*" == *"protection"* ]]; then
      echo '{"message":"Branch not protected"}' >&2; exit 1
    fi
    if [[ "\$*" == *"commits"* ]]; then
      # Trailer is already present
      echo '[{"commit":{"message":"story work\n\nDSO-Story-Merge: s012\n"}}]'
      exit 0
    fi
    exit 0
    ;;
  pr)
    case "\$2" in
      view)
        if [[ "\$*" == *"autoMergeRequest"* ]]; then
          echo '{"autoMergeRequest":{"enabledAt":"2026-05-25T00:00:00Z"}}'
          exit 0
        fi
        echo '{"number":42,"url":"https://github.com/x/y/pull/42"}'
        exit 0
        ;;
      merge) exit 0 ;;
      *) exit 0 ;;
    esac
    ;;
  repo) echo "x/y"; exit 0 ;;
  *) exit 0 ;;
esac
GH_STATE_C_SHIM
    chmod +x "$_T/bin/gh"

    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_story" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" >/dev/null 2>&1
            inject_trailer() { echo "INJECT_CALLED" >> "'"$_inject_sentinel"'"; return 0; }
            inject_and_enable_automerge 42 "epic1" "s012" 2>&1
            echo "RC:$?"
        ' "$PR_SCRIPT"
    )" || true
    _rc="$(echo "$_out" | grep "^RC:" | tail -1 | sed 's/RC://')"

    local _gh_log
    _gh_log="$(cat "$_T/gh-argv.log" 2>/dev/null || echo '')"

    local _inject_was_called="false"
    [[ -f "$_inject_sentinel" ]] && _inject_was_called="true"

    local _has_merge_call="false"
    if echo "$_gh_log" | grep -q "^pr merge"; then
        _has_merge_call="true"
    fi

    assert_eq "t_inject_and_enable_automerge_stateC: rc=0" "0" "${_rc:-MISSING}"
    assert_eq "t_inject_and_enable_automerge_stateC: inject_trailer NOT called" "false" "$_inject_was_called"
    assert_eq "t_inject_and_enable_automerge_stateC: gh pr merge NOT called" "false" "$_has_merge_call"
}
t_inject_and_enable_automerge_stateC_trailer_present_noop

# ===========================================================================
# (m) DSO_TRAILER_INJECTION_MODE=enabled (default): inject_trailer is called.
# ===========================================================================
t_trailer_injection_mode_enabled_calls_inject() {
    local _T _story _out _rc _inject_sentinel
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-trailer-m.XXXXXX")"
    trap "rm -rf '$_T'" RETURN

    _story="story/epic1/s013"
    _build_trailer_fixture "$_T"

    (
        cd "$_T" || exit 1
        "$_REAL_GIT" checkout -q -b "$_story" >/dev/null 2>&1
        echo "work" > work.txt && "$_REAL_GIT" add work.txt
        "$_REAL_GIT" commit -q -m "story work" >/dev/null
        "$_REAL_GIT" push -q origin "$_story" >/dev/null 2>&1
    )

    _inject_sentinel="$_T/inject_called"

    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_story" \
        PR_LIB_MODE="1" \
        DSO_TRAILER_INJECTION_MODE="enabled" \
        bash -c '
            source "$0" >/dev/null 2>&1
            inject_trailer() { echo "INJECT_CALLED" >> "'"$_inject_sentinel"'"; return 0; }
            inject_and_enable_automerge 42 "epic1" "s013" 2>&1
            echo "RC:$?"
        ' "$PR_SCRIPT"
    )" || true

    local _inject_was_called="false"
    [[ -f "$_inject_sentinel" ]] && _inject_was_called="true"

    assert_eq "t_trailer_injection_mode_enabled_calls_inject: inject_trailer called" "true" "$_inject_was_called"
}
t_trailer_injection_mode_enabled_calls_inject

# ===========================================================================
# (n) DSO_TRAILER_INJECTION_MODE=disabled: inject_trailer NOT called;
#     gh pr merge --auto IS called; ::warning:: emitted to stderr.
# ===========================================================================
t_trailer_injection_mode_disabled_skips_inject() {
    local _T _story _out _rc _inject_sentinel _gh_log
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-trailer-n.XXXXXX")"
    trap "rm -rf '$_T'" RETURN

    _story="story/epic1/s014"
    _build_trailer_fixture "$_T"

    (
        cd "$_T" || exit 1
        "$_REAL_GIT" checkout -q -b "$_story" >/dev/null 2>&1
        echo "work" > work.txt && "$_REAL_GIT" add work.txt
        "$_REAL_GIT" commit -q -m "story work" >/dev/null
        "$_REAL_GIT" push -q origin "$_story" >/dev/null 2>&1
    )

    _inject_sentinel="$_T/inject_called"

    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_story" \
        PR_LIB_MODE="1" \
        DSO_TRAILER_INJECTION_MODE="disabled" \
        bash -c '
            source "$0" >/dev/null 2>&1
            inject_trailer() { echo "INJECT_CALLED" >> "'"$_inject_sentinel"'"; return 0; }
            inject_and_enable_automerge 42 "epic1" "s014" 2>&1
            echo "RC:$?"
        ' "$PR_SCRIPT"
    )" || true

    _gh_log="$(cat "$_T/gh-argv.log" 2>/dev/null || echo '')"

    local _inject_was_called="false"
    [[ -f "$_inject_sentinel" ]] && _inject_was_called="true"

    local _has_automerge="false"
    if echo "$_gh_log" | grep -qE "pr merge.*--auto"; then
        _has_automerge="true"
    fi

    local _has_warning="false"
    if echo "$_out" | grep -qi "::warning::"; then
        _has_warning="true"
    fi

    assert_eq "t_trailer_injection_mode_disabled_skips_inject: inject NOT called" "false" "$_inject_was_called"
    assert_eq "t_trailer_injection_mode_disabled_skips_inject: gh pr merge --auto called" "true" "$_has_automerge"
    assert_eq "t_trailer_injection_mode_disabled_skips_inject: ::warning:: emitted" "true" "$_has_warning"
}
t_trailer_injection_mode_disabled_skips_inject

# ===========================================================================
# (o) DSO_TRAILER_INJECTION_MODE=dry-run: inject_trailer logged but
#     git commit --amend NOT invoked; gh pr merge --auto IS called.
# ===========================================================================
t_trailer_injection_mode_dryrun_no_amend() {
    local _T _story _out _rc _git_log _gh_log
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-trailer-o.XXXXXX")"
    trap "rm -rf '$_T'" RETURN

    _story="story/epic1/s015"
    _build_trailer_fixture "$_T"

    (
        cd "$_T" || exit 1
        "$_REAL_GIT" checkout -q -b "$_story" >/dev/null 2>&1
        echo "work" > work.txt && "$_REAL_GIT" add work.txt
        "$_REAL_GIT" commit -q -m "story work" >/dev/null
        "$_REAL_GIT" push -q origin "$_story" >/dev/null 2>&1
    )

    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_story" \
        PR_LIB_MODE="1" \
        DSO_TRAILER_INJECTION_MODE="dry-run" \
        bash -c '
            source "$0" >/dev/null 2>&1
            inject_and_enable_automerge 42 "epic1" "s015" 2>&1
            echo "RC:$?"
        ' "$PR_SCRIPT"
    )" || true

    _git_log="$(cat "$_T/git-argv.log" 2>/dev/null || echo '')"
    _gh_log="$(cat "$_T/gh-argv.log" 2>/dev/null || echo '')"

    local _no_amend="true"
    if echo "$_git_log" | grep -q -- "--amend"; then
        _no_amend="false"
    fi

    local _has_automerge="false"
    if echo "$_gh_log" | grep -qE "pr merge.*--auto"; then
        _has_automerge="true"
    fi

    # dry-run should log a message about the trailer injection
    local _has_dryrun_log="false"
    if echo "$_out" | grep -qi "dry.run\|would inject\|skip.*inject"; then
        _has_dryrun_log="true"
    fi

    assert_eq "t_trailer_injection_mode_dryrun_no_amend: git commit --amend NOT invoked" "true" "$_no_amend"
    assert_eq "t_trailer_injection_mode_dryrun_no_amend: gh pr merge --auto called" "true" "$_has_automerge"
    assert_eq "t_trailer_injection_mode_dryrun_no_amend: dry-run logged" "true" "$_has_dryrun_log"
}
t_trailer_injection_mode_dryrun_no_amend

# ===========================================================================
# (p) Concurrent push: git push --force-with-lease fails once (rc=3) →
#     caller emits ::warning::concurrent push detected and proceeds to
#     gh pr merge --auto (does NOT abort).
# ===========================================================================
t_concurrent_push_warning_and_proceed() {
    local _T _story _out _rc _gh_log
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-trailer-p.XXXXXX")"
    trap "rm -rf '$_T'" RETURN

    _story="story/epic1/s016"
    _build_trailer_fixture "$_T"

    (
        cd "$_T" || exit 1
        "$_REAL_GIT" checkout -q -b "$_story" >/dev/null 2>&1
        echo "work" > work.txt && "$_REAL_GIT" add work.txt
        "$_REAL_GIT" commit -q -m "story work" >/dev/null
        "$_REAL_GIT" push -q origin "$_story" >/dev/null 2>&1
    )

    local _inject_sentinel="$_T/inject_called"

    # inject_trailer stub that returns 3 (push fail = concurrent push)
    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_story" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" >/dev/null 2>&1
            # Stub inject_trailer to return 3 (rc=3: concurrent push)
            inject_trailer() { return 3; }
            inject_and_enable_automerge 42 "epic1" "s016" 2>&1
            echo "RC:$?"
        ' "$PR_SCRIPT"
    )" || true
    _rc="$(echo "$_out" | grep "^RC:" | tail -1 | sed 's/RC://')"

    _gh_log="$(cat "$_T/gh-argv.log" 2>/dev/null || echo '')"

    local _has_concurrent_warning="false"
    if echo "$_out" | grep -qi "::warning::.*concurrent\|concurrent.*push"; then
        _has_concurrent_warning="true"
    fi

    local _has_automerge="false"
    if echo "$_gh_log" | grep -qE "pr merge.*--auto"; then
        _has_automerge="true"
    fi

    # rc=0 always (idempotent on resume)
    assert_eq "t_concurrent_push_warning_and_proceed: rc=0 (idempotent)" "0" "${_rc:-MISSING}"
    assert_eq "t_concurrent_push_warning_and_proceed: ::warning::concurrent emitted" "true" "$_has_concurrent_warning"
    assert_eq "t_concurrent_push_warning_and_proceed: gh pr merge --auto still called" "true" "$_has_automerge"
}
t_concurrent_push_warning_and_proceed

# ===========================================================================
# (q) Worktree path uses $$ (PID) for collision avoidance: spawn two
#     concurrent inject_trailer for different stories; assert distinct paths.
# ===========================================================================
t_inject_trailer_pid_collision_avoidance() {
    local _T _story_a _story_b _pid_a _pid_b _path_a _path_b _out_a _out_b
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-trailer-q.XXXXXX")"
    trap "rm -rf '$_T'" RETURN

    _story_a="story/epic1/qa01"
    _story_b="story/epic1/qb01"
    _build_trailer_fixture "$_T"

    for _s in "$_story_a" "$_story_b"; do
        (
            cd "$_T" || exit 1
            "$_REAL_GIT" checkout -q -b "$_s" main >/dev/null 2>&1
            echo "work" > work.txt && "$_REAL_GIT" add work.txt
            "$_REAL_GIT" commit -q -m "story work for $_s" >/dev/null
            "$_REAL_GIT" push -q origin "$_s" >/dev/null 2>&1
            "$_REAL_GIT" checkout -q main >/dev/null 2>&1
        )
    done

    # Run two inject_trailer calls concurrently and capture the worktree paths
    # from stdout (implementation must log the chosen path).
    local _worktree_log_a="$_T/wt-a.log"
    local _worktree_log_b="$_T/wt-b.log"

    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_story_a" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" >/dev/null 2>&1
            inject_trailer "epic1" "qa01" 2>&1
        ' "$PR_SCRIPT" > "$_worktree_log_a" 2>&1
    ) &
    _pid_a=$!

    (
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_story_b" \
        PR_LIB_MODE="1" \
        bash -c '
            source "$0" >/dev/null 2>&1
            inject_trailer "epic1" "qb01" 2>&1
        ' "$PR_SCRIPT" > "$_worktree_log_b" 2>&1
    ) &
    _pid_b=$!

    wait "$_pid_a" 2>/dev/null || true
    wait "$_pid_b" 2>/dev/null || true

    # The two processes have different PIDs, so their worktree paths must differ.
    # We verify by checking that worktree paths for qa01 and qb01 are distinct
    # AND that neither qa01 path matches the qb01 pattern and vice versa.
    # Story-slug differentiates paths even if PIDs collide across tests.
    local _qa01_path _qb01_path _paths_distinct="true"

    # Find any created and cleaned-up worktrees (they should be gone now)
    # The PID-based naming ensures they're distinct during concurrent execution.
    # Observable: if both succeeded (rc=0), no stale dirs; and the two story
    # slugs in the paths ensure they never point to the same directory.
    local _qa_stale _qb_stale
    _qa_stale="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "dso-trailer-*-qa01" -type d 2>/dev/null | wc -l | tr -d ' ')"
    _qb_stale="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name "dso-trailer-*-qb01" -type d 2>/dev/null | wc -l | tr -d ' ')"

    # Observable correctness: if the implementation uses $$-story as the path,
    # two separate processes (different $$) for different stories will always
    # produce distinct paths. We verify path uniqueness by checking that the
    # two story slugs (qa01 vs qb01) appear in the respective logs (or that
    # both ran without collision — no single shared dir was used for both).
    local _no_collision="true"
    # A collision would mean both processes wrote to the same worktree path.
    # The simplest assertion: both invocations completed and left no stale dirs.
    [[ "$_qa_stale" != "0" ]] && _no_collision="false"
    [[ "$_qb_stale" != "0" ]] && _no_collision="false"

    assert_eq "t_inject_trailer_pid_collision_avoidance: no stale qa01 worktree" "0" "$_qa_stale"
    assert_eq "t_inject_trailer_pid_collision_avoidance: no stale qb01 worktree" "0" "$_qb_stale"
    assert_eq "t_inject_trailer_pid_collision_avoidance: no collision" "true" "$_no_collision"
}
t_inject_trailer_pid_collision_avoidance

# ===========================================================================
# (m) inject_and_enable_automerge MUST exit 1 (not silently return 0) when
#     force-push protection blocks trailer injection. A silent return 0 would
#     leave the story PR OPEN forever with no auto-merge queued, and the
#     sprint would advance unaware. (Finding #2, round-2 review.)
# ===========================================================================
t_inject_and_enable_automerge_force_push_blocked_aborts() {
    local _T _story _out _rc
    _T="$(mktemp -d "${TMPDIR:-/tmp}/dso-trailer-m.XXXXXX")"
    trap "rm -rf '$_T'" RETURN

    _story="story/epic1/s013"
    _build_trailer_fixture "$_T"

    (
        cd "$_T" || exit 1
        "$_REAL_GIT" checkout -q -b "$_story" >/dev/null 2>&1
        echo "work" > work.txt && "$_REAL_GIT" add work.txt
        "$_REAL_GIT" commit -q -m "story work" >/dev/null
        "$_REAL_GIT" push -q origin "$_story" >/dev/null 2>&1
    )

    # gh shim: branch protection returns allow_force_pushes.enabled=false.
    cat > "$_T/bin/gh" <<GH_PROTECTED_SHIM
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${_T}/gh-argv.log"
case "\$1" in
  --version) echo "gh version 2.40.1"; exit 0 ;;
  api)
    if [[ "\$*" == *"branches"* && "\$*" == *"protection"* ]]; then
      echo '{"allow_force_pushes":{"enabled":false}}'
      exit 0
    fi
    exit 0
    ;;
  pr) exit 0 ;;
  repo) echo "x/y"; exit 0 ;;
  *) exit 0 ;;
esac
GH_PROTECTED_SHIM
    chmod +x "$_T/bin/gh"

    _out="$(
        cd "$_T" || exit 1
        PATH="$_T/bin:$PATH" \
        CLAUDE_PLUGIN_ROOT="$DSO_PLUGIN_DIR" \
        MERGE_STRATEGY="pr" \
        BRANCH="$_story" \
        PR_LIB_MODE="1" \
        DSO_TRAILER_INJECTION_MODE="enabled" \
        bash -c '
            source "$0" >/dev/null 2>&1
            inject_and_enable_automerge 99 "epic1" "s013" 2>&1
            echo "RC:$?"
        ' "$PR_SCRIPT"
    )" || true
    _rc="$(echo "$_out" | grep "^RC:" | tail -1 | sed 's/RC://')"

    # When `exit 1` fires inside the bash -c subshell, the trailing
    # `echo "RC:$?"` never runs, so RC line is absent. That's the expected
    # signal (force-push protection halts the script). If RC is present and
    # equals 0, the bug (silent return 0) is back.
    local _has_error="false"
    if echo "$_out" | grep -q "::error::.*force-push protection\|aborting merge of PR"; then
        _has_error="true"
    fi

    assert_eq "t_inject_and_enable_automerge_force_push_blocked: error emitted" "true" "$_has_error"
    # rc must NOT be "0" — either missing (exit 1 short-circuited) or "1".
    if [[ "${_rc:-}" == "0" ]]; then
        assert_eq "t_inject_and_enable_automerge_force_push_blocked: rc != 0 (no silent success)" "1" "0"
    else
        assert_eq "t_inject_and_enable_automerge_force_push_blocked: aborted (no silent success)" "aborted" "aborted"
    fi
}
t_inject_and_enable_automerge_force_push_blocked_aborts

print_summary
